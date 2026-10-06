#!/usr/bin/env ruby
# Reconcile one retained native LC Object part with the bounded Crystal
# inspector. This finite early witness is not broad-format admission.

require 'digest'
require 'fileutils'
require 'json'
require 'optparse'
require_relative 'check_array_json_parts_w185'

module CheckObjectSharedLowCardinalityW196
  extend self

  FORMAT = 'object_shared_low_cardinality_w196_reconciliation_v1'.freeze
  CAPTURE_ROOT = '/private/tmp/crystal-click-w196-native-admission.bQPELZ'.freeze
  PART_RELATIVE = 'stores/native/store/2ce/2ceaec57-b4f3-4136-8db1-6a606b6ef5b5/all_1_1_0'.freeze
  RUNTIME_VERSION = '26.10.1.1201'.freeze
  RUNTIME_BUILD = 'd9bcb5ab007f0f6299f7f973f2642245bab3d028'.freeze
  RUNTIME_SHA256 = 'bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2'.freeze

  CAPTURE_HASHES = {
    'invocations/object_lc.json' => '072a2c202383c06a93f89aed5c1a7391fb1b4b165349771a45768245a7b64c9f',
    'invocations/object_lc.argv.json' => '496683bd1f9ce163e79f9a8d3c7f2025a59da5e18c53b8007b9478ee1c8edd15',
    'invocations/object_lc.stdin.sql' => '613ec49cf3450f9666b7e2f2559ce70f9086897ff9a69d506123421c16ce492c',
    'invocations/object_lc.stdout' => '5fc6867fe8f48250dcd2f3293c9bafe644cfe8c5d6ccd66b2e830bfa8925132c',
    'invocations/object_lc.stderr' => 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    'input.rowbinary' => '4756e1162c0acbdafa39d72b407673529d1512bce7d3bf59089355b6344895a0',
  }.freeze
  PART_INVENTORY_SHA256 = 'ca5b29b6177e853e84d313d7578c29610195d99e79467f62209638c1f7c2b012'.freeze

  PAIRED_FORMAT = 'object_shared_low_cardinality_w196_parts_input_v1'.freeze
  PAIRED_HELPER_FORMAT = 'object_shared_low_cardinality_w196_parts_helper_v1'.freeze
  PAIRED_PROFILE_IDS = %w[v2_string0 v2_string1 v3_string0 v3_string1].freeze
  PAIRED_ROWS = [
    {'p' => 'red', 'a' => [7, 9]}, {},
    {'p' => '', 'a' => []}, {'p' => 'blue', 'a' => [0, 255]},
    {}, {'p' => 'red', 'a' => [9]},
    {'p' => 'blue', 'a' => []}, {'p' => '', 'a' => [7, 0]},
  ].freeze
  PAIRED_EXPECTED_PATH_HEX = {
    'p' => %w[0003726564 01 0000 0004626c7565 01 0003726564 0004626c7565 0000].freeze,
    'a' => %w[020709 00 00 0200ff 00 0109 00 020700].freeze,
  }.freeze
  PAIRED_PATH_TYPES = {
    'p' => Array.new(8) { |index| [1, 4].include?(index) ? 'None' : 'LowCardinality(String)' }.freeze,
    'a' => Array.new(8) { |index| [1, 4].include?(index) ? 'None' : 'Array(LowCardinality(UInt8))' }.freeze,
  }.freeze

  W185 = CheckArrayJSONPartsW185

  NATIVE_ROWS = [
    ['1', 'LowCardinality(String)', 'Array(LowCardinality(UInt8))', '0201611E26010207090170261503726564', "['a','p']"],
    ['2', 'None', 'None', '00', '[]'],
    ['3', 'LowCardinality(String)', 'Array(LowCardinality(UInt8))', '0201611E2601000170261500', "['a','p']"],
    ['4', 'LowCardinality(String)', 'Array(LowCardinality(UInt8))', '0201611E26010200FF0170261504626C7565', "['a','p']"],
  ].map(&:freeze).freeze

  EXPECTED_PATHS = [
    {
      'bucket_index' => 0, 'parent_index' => 0, 'chunk_index' => 0, 'row_count' => 2,
      'name' => 'p', 'dynamic_types' => ['LowCardinality(String)'],
      'events' => [
        ['.dynamic_structure', 0], ['.variant_discr_prefix', 11],
        ['.LowCardinality(String).dict_prefix', 19], ['.variant_discr', 27],
        ['.LowCardinality(String).dict', 31], ['.LowCardinality(String)', 31],
        ['.SharedVariant.size', 61], ['.SharedVariant', 61],
      ],
      'data_hex' => '040000000000000001261501000000000000000100000000000000020000ff000600000000000002000000000000000003726564010000000000000001',
      'values' => [
        {'type' => 'LowCardinality(String)', 'value' => 'red'}, nil,
      ],
    },
    {
      'bucket_index' => 0, 'parent_index' => 1, 'chunk_index' => 0, 'row_count' => 2,
      'name' => 'p', 'dynamic_types' => ['LowCardinality(String)'],
      'events' => [
        ['.dynamic_structure', 0], ['.variant_discr_prefix', 11],
        ['.LowCardinality(String).dict_prefix', 19], ['.variant_discr', 27],
        ['.LowCardinality(String).dict', 30], ['.LowCardinality(String)', 30],
        ['.SharedVariant.size', 62], ['.SharedVariant', 62],
      ],
      'data_hex' => '040000000000000001261501000000000000000100000000000000020100000600000000000002000000000000000004626c756502000000000000000001',
      'values' => [
        {'type' => 'LowCardinality(String)', 'value' => ''},
        {'type' => 'LowCardinality(String)', 'value' => 'blue'},
      ],
    },
    {
      'bucket_index' => 1, 'parent_index' => 0, 'chunk_index' => 0, 'row_count' => 2,
      'name' => 'a', 'dynamic_types' => ['Array(LowCardinality(UInt8))'],
      'events' => [
        ['.dynamic_structure', 0], ['.variant_discr_prefix', 12],
        ['.Array(LowCardinality(UInt8)).dict_prefix', 20], ['.variant_discr', 28],
        ['.Array(LowCardinality(UInt8)).size0', 32], ['.Array(LowCardinality(UInt8)).dict', 40],
        ['.Array(LowCardinality(UInt8))', 40], ['.SharedVariant.size', 69], ['.SharedVariant', 69],
      ],
      'data_hex' => '0400000000000000011e260101000000000000000100000000000000020000ff02000000000000000006000000000000030000000000000000070902000000000000000102',
      'values' => [
        {'type' => 'Array(LowCardinality(UInt8))', 'value' => [7, 9]}, nil,
      ],
    },
    {
      'bucket_index' => 1, 'parent_index' => 1, 'chunk_index' => 0, 'row_count' => 2,
      'name' => 'a', 'dynamic_types' => ['Array(LowCardinality(UInt8))'],
      'events' => [
        ['.dynamic_structure', 0], ['.variant_discr_prefix', 12],
        ['.Array(LowCardinality(UInt8)).dict_prefix', 20], ['.variant_discr', 28],
        ['.Array(LowCardinality(UInt8)).size0', 31], ['.Array(LowCardinality(UInt8)).dict', 47],
        ['.Array(LowCardinality(UInt8))', 47], ['.SharedVariant.size', 75], ['.SharedVariant', 75],
      ],
      'data_hex' => '0400000000000000011e260101000000000000000100000000000000020100000000000000000002000000000000000006000000000000020000000000000000ff02000000000000000001',
      'values' => [
        {'type' => 'Array(LowCardinality(UInt8))', 'value' => []},
        {'type' => 'Array(LowCardinality(UInt8))', 'value' => [0, 255]},
      ],
    },
  ].freeze

  class CheckError < StandardError; end

  # The paired mode is deliberately a separate runner over the same W185
  # bounded executor.  The retained four-row inspector above remains a small
  # immutable diagnostic; it is not silently promoted into the eight-row
  # paired qualification.
  class PairedPartProbe < W185::Probe
    PROFILE_IDS = PAIRED_PROFILE_IDS

    def initialize(binary, helper, evidence_root, capture_root, library_parts)
      @capture_root = File.realpath(capture_root)
      @source_parts = {}
      @library_parts = library_parts.transform_values { |path| File.expand_path(path) }
      @part_paths_configured = false
      super(binary, helper, evidence_root)
    end

    def configure_part_paths!(source_parts)
      fail!('part path allowlist was already configured') if @part_paths_configured
      fail!('source part allowlist is incomplete') unless source_parts.keys.sort == PROFILE_IDS.sort
      fail!('library part allowlist is incomplete') unless @library_parts.keys.sort == PROFILE_IDS.sort

      normalized_sources = source_parts.transform_values { |path| File.expand_path(path) }
      native_root = File.join(@root, 'stores', 'native')
      generated_root = File.join(@root, 'generated')
      fail!('source part escaped this task native store') unless
        normalized_sources.values.all? { |path| path.start_with?(native_root + File::SEPARATOR) }
      fail!('library part escaped this task generated root') unless
        @library_parts.values.all? { |path| path.start_with?(generated_root + File::SEPARATOR) }
      fail!('source part paths are not unique') unless normalized_sources.values.uniq.size == PROFILE_IDS.size
      fail!('library part paths are not unique') unless @library_parts.values.uniq.size == PROFILE_IDS.size

      @source_parts = normalized_sources
      @part_paths_configured = true
      self
    end

    private

    def validate_part_path!(path)
      full = File.expand_path(path)
      unless @part_paths_configured && @source_parts.value?(full) && File.directory?(full) &&
             !File.symlink?(full) && File.realpath(full) == full &&
             full.start_with?(File.join(@root, 'stores', 'native') + File::SEPARATOR)
        fail!("stock part is not one of the exact task-local source parts: #{path}")
      end
      validate_plain_tree!(full)
      full
    end

    def validate_library_part_path!(path)
      full = File.expand_path(path)
      unless @part_paths_configured && @library_parts.value?(full) && File.directory?(full) &&
             !File.symlink?(full) && File.realpath(full) == full
        fail!("library part is not one of the exact task-local destinations: #{path}")
      end
      validate_plain_tree!(full)
      full
    end
  end

  class PairedProbe
    include CheckObjectSharedLowCardinalityW196
    PROFILE_SETTINGS = {
      'v2_string0' => [2, 0, 'advanced'],
      'v2_string1' => [2, 1, 'advanced'],
      'v3_string0' => [3, 0, 'advanced_chunked'],
      'v3_string1' => [3, 1, 'advanced_chunked'],
    }.freeze
    TABLES = PAIRED_PROFILE_IDS.flat_map { |id| ["source_#{id}", "library_#{id}"] }.freeze
    COLUMN_TYPE = 'JSON(max_dynamic_types=1, max_dynamic_paths=0)'.freeze
    INPUT_NAME = 'input.rowbinary'.freeze
    HELPER_INPUT_NAME = 'generated/input.json'.freeze

    def initialize(binary, helper, evidence_root)
      @binary = File.expand_path(binary)
      @helper = File.expand_path(helper)
      @root = File.expand_path(evidence_root)
      @library_parts = PAIRED_PROFILE_IDS.to_h do |id|
        [id, File.join(@root, 'generated', id, 'all_1_1_0')]
      end
      @base = PairedPartProbe.new(binary, helper, evidence_root, evidence_root, @library_parts)
      @invocations = @base.instance_variable_get(:@invocations)
      @fatal_error = nil
      @source_parts = {}
      @source_part_info = {}
    end

    def run
      create_evidence_layout!
      @sha_before = Digest::SHA256.file(@binary).hexdigest
      require!(@sha_before == W185::BINARY_SHA256, 'ClickHouse executable SHA-256 differs from pinned W185/W191 binary')
      input = rowbinary_input
      @base.send(:write_new, File.join(@root, INPUT_NAME), input)

      initial = @base.send(:run_clickhouse, 'native_sources_create', initial_sql)
      assert_sql_invocation!(initial, 'native_sources_create', initial_sql)
      assert_native!(initial, 'native source creation')
      native_initial = parse_paired_native(initial[:stdout])
      assert_initial_native!(native_initial)
      source_part_records = native_initial.fetch(:parts).to_h do |table, part|
        require!(table.start_with?('source_'), "unexpected source part table #{table}")
        [table.sub(/\Asource_/, ''), part]
      end
      require!(source_part_records.keys.sort == PAIRED_PROFILE_IDS.sort,
        'source part profile identity roster differs')
      @source_parts = source_part_records.to_h do |id, part|
        [id, File.expand_path(part.fetch(:path))]
      end
      @base.configure_part_paths!(@source_parts)
      @source_parts.each do |id, path|
        @source_parts[id] = @base.send(:validate_part_path!, path)
      end
      @source_part_info = source_part_records

      source_inventories = inspect_profiles(@source_parts, 'stock')
      source_rows = source_rows_sql
      source_reads = @base.send(:run_clickhouse, 'native_source_rows', source_rows)
      assert_sql_invocation!(source_reads, 'native_source_rows', source_rows)
      assert_native!(source_reads, 'native source full/middle/zero rows')
      native_source_rows = parse_paired_native(source_reads[:stdout])
      assert_row_reads!(native_source_rows, PAIRED_PROFILE_IDS.map { |id| "source_#{id}" })
      source_paths_sql = direct_paths_sql(PAIRED_PROFILE_IDS.map { |id| "source_#{id}" })
      source_paths = @base.send(:run_clickhouse, 'native_source_direct_paths', source_paths_sql)
      assert_sql_invocation!(source_paths, 'native_source_direct_paths', source_paths_sql)
      assert_native!(source_paths, 'native source direct-path reads')
      native_source_paths = parse_paired_native(source_paths[:stdout])
      assert_direct_paths!(native_source_paths, PAIRED_PROFILE_IDS.map { |id| "source_#{id}" })

      helper_input = paired_helper_input
      helper_path = File.join(@root, HELPER_INPUT_NAME)
      @base.send(:write_new, helper_path, JSON.pretty_generate(helper_input) + "\n")
      @helper_sha_before = Digest::SHA256.file(@helper).hexdigest
      helper_invocation = @base.send(:execute_record, 'paired_crystal_helper',
        [@helper, helper_path, File.join(@root, 'generated')], ''.b,
        'prebuilt Crystal helper', @helper_sha_before, @helper)
      @helper_sha_after = Digest::SHA256.file(@helper).hexdigest
      @helper_identity = helper_identity_summary(@helper_sha_before, @helper_sha_after)
      assert_helper_identity!(helper_invocation, @helper_sha_before, @helper_sha_after, @helper_identity)
      require!(helper_invocation[:classification] == 'success' && helper_invocation[:status]&.success? && helper_invocation[:status]&.termsig.nil?,
        'paired Crystal helper failed; this is not a ClickHouse format rejection')
      require!(helper_invocation[:stderr].empty?, 'paired Crystal helper wrote stderr')
      helper_output_bytes = helper_invocation[:stdout]
      helper_output = JSON.parse(helper_output_bytes)
      validate_helper_envelope!(helper_output)
      reconciled = reconcile_helper!(helper_input, helper_output)

      library_inventories = inspect_profiles(@library_parts, 'library', generated_library: true)
      assert_library_profile!(library_inventories)

      data_paths = native_initial.fetch(:data_paths)
      PAIRED_PROFILE_IDS.each do |id|
        source = "source_#{id}"
        library = "library_#{id}"
        [source, library].each do |table|
          path = data_paths.fetch(table) { raise CheckError, "native table path missing for #{table}" }
          @base.send(:validate_store_path!, path)
        end
        @base.send(:attach_part!, @library_parts.fetch(id), data_paths.fetch(library))
      end

      attached_whole_sql = attached_sql
      attached = @base.send(:run_clickhouse, 'native_attach_check_whole_rows', attached_whole_sql)
      assert_sql_invocation!(attached, 'native_attach_check_whole_rows', attached_whole_sql)
      assert_native!(attached, 'native ATTACH/CHECK and whole-object reads')
      native_attached = parse_paired_native(attached[:stdout])
      assert_attached_native!(native_attached)
      direct_attached_sql = direct_paths_sql(PAIRED_PROFILE_IDS.flat_map { |id| ["source_#{id}", "library_#{id}"] })
      direct_attached = @base.send(:run_clickhouse, 'native_attach_direct_paths', direct_attached_sql)
      assert_sql_invocation!(direct_attached, 'native_attach_direct_paths', direct_attached_sql)
      assert_native!(direct_attached, 'native attached direct-path reads')
      native_direct_attached = parse_paired_native(direct_attached[:stdout])
      assert_direct_paths!(native_direct_attached,
        PAIRED_PROFILE_IDS.flat_map { |id| ["source_#{id}", "library_#{id}"] })

      @sha_after = Digest::SHA256.file(@binary).hexdigest
      require!(@sha_after == W185::BINARY_SHA256, 'ClickHouse executable SHA-256 changed during W196 paired run')
      write_paired_summary(
        status: 'paired_native_helper_observed',
        native_initial: native_initial,
        source_inventories: source_inventories,
        source_reads: native_source_rows,
        source_paths: native_source_paths,
        helper_input_sha256: sha256(JSON.pretty_generate(helper_input) + "\n"),
        helper_output_sha256: sha256(helper_output_bytes),
        helper_output: helper_output,
        helper_reconciliation: reconciled,
        library_inventories: library_inventories,
        attached: native_attached,
        attached_direct_paths: native_direct_attached,
      )
      puts "W196 paired status=paired_native_helper_observed profiles=4 evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      @sha_after = Digest::SHA256.file(@binary).hexdigest rescue nil
      write_paired_summary(status: 'runner_failure_or_observations_differ', fatal_error: @fatal_error) rescue nil
      warn "W196 paired LowCardinality probe failed: #{@fatal_error}"
      false
    end

    private

    def rowbinary_input
      encode_string = ->(value) { [value.bytesize].pack('C') + value.b }
      encode_lc_string = ->(value) { [0x26, 0x15].pack('C*') + encode_string.call(value) }
      encode_array_lc_uint8 = ->(values) { [0x1e, 0x26, 0x01, values.size, *values].pack('C*') }
      PAIRED_ROWS.each_with_index.map do |row, index|
        values = []
        values << [encode_string.call('p'), encode_lc_string.call(row.fetch('p'))] if row.key?('p')
        values << [encode_string.call('a'), encode_array_lc_uint8.call(row.fetch('a'))] if row.key?('a')
        [index + 1].pack('Q<') + [values.size].pack('C') + values.map(&:join).join.b
      end.join.b
    end

    def helper_input
      {
        'format' => PAIRED_FORMAT,
        'capture_root' => @root,
        'profiles' => PAIRED_PROFILE_IDS.map do |id|
          shared_version, string_version, = PROFILE_SETTINGS.fetch(id)
          {
            'id' => id,
            'source_part' => @source_parts.fetch(id),
            'library_part' => @library_parts.fetch(id),
            'shared_version' => shared_version,
            'string_version' => string_version,
          }
        end,
      }
    end

    def paired_helper_input
      helper_input
    end

    def settings_for(id)
      shared_version, string_version, mode = PROFILE_SETTINGS.fetch(id)
      base = W185::SETTINGS.split(', ').reject do |setting|
        setting.start_with?('object_shared_data_serialization_version=') ||
          setting.start_with?('object_shared_data_serialization_version_for_zero_level_parts=') ||
          setting.start_with?('object_shared_data_buckets_for_wide_part=') ||
          setting.start_with?('object_shared_data_target_chunk_rows=') ||
          setting.start_with?('string_serialization_version=') ||
          setting.start_with?('serialization_info_version=') ||
          setting.start_with?('propagate_types_serialization_versions_to_nested_types=')
      end
      base.concat([
        "object_shared_data_serialization_version='#{mode}'",
        "object_shared_data_serialization_version_for_zero_level_parts='#{mode}'",
        'object_shared_data_buckets_for_wide_part=2',
        "serialization_info_version='with_types'",
        "string_serialization_version='#{string_version.zero? ? 'single_stream' : 'with_size_stream'}'",
        'propagate_types_serialization_versions_to_nested_types=1',
      ])
      base << 'object_shared_data_target_chunk_rows=1' if shared_version == 3
      base.join(', ')
    end

    def initial_sql
      statements = [pin_sql]
      PAIRED_PROFILE_IDS.each do |id|
        source = "source_#{id}"
        library = "library_#{id}"
        settings = settings_for(id)
        statements << "CREATE TABLE default.#{source} (pk UInt64, j #{COLUMN_TYPE}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings};"
        statements << "CREATE TABLE default.#{library} (pk UInt64, j #{COLUMN_TYPE}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings};"
        statements << insert_file_sql(source)
        statements << "SELECT '__W196_CHECK_BEGIN__', '#{source}' FORMAT TSVRaw;"
        statements << "CHECK TABLE default.#{source} FORMAT TSV;"
        statements << "SELECT '__W196_CHECK_END__', '#{source}' FORMAT TSVRaw;"
      end
      quoted = TABLES.map { |table| sql_string(table) }.join(',')
      statements << "SELECT '__W196_SCHEMA__', table, name, type FROM system.columns WHERE database='default' AND table IN (#{quoted}) ORDER BY table, position FORMAT TSVRaw;"
      statements << "SELECT '__W196_DATA_PATH__', name, arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name IN (#{quoted}) ORDER BY name FORMAT TSVRaw;"
      sources = PAIRED_PROFILE_IDS.map { |id| sql_string("source_#{id}") }.join(',')
      statements << "SELECT '__W196_PART__', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table IN (#{sources}) AND active ORDER BY table,name FORMAT TSVRaw;"
      statements.join("\n") + "\n"
    end

    def insert_file_sql(table)
      path = sql_string(File.join(@root, INPUT_NAME))
      "INSERT INTO default.#{table} SELECT * FROM file(#{path}, 'RowBinary', 'pk UInt64, j #{COLUMN_TYPE}') SETTINGS input_format_binary_read_json_as_string=0, allow_suspicious_low_cardinality_types=1;"
    end

    def source_rows_sql
      rows_sql(PAIRED_PROFILE_IDS.map { |id| "source_#{id}" })
    end

    def rows_sql(tables)
      statements = [pin_sql]
      tables.each { |table| append_read_queries(statements, table) }
      sql = statements.join("\n") + "\n"
      validate_whole_zero_sql!(sql, tables)
      sql
    end

    def append_read_queries(statements, table)
      statements << "SELECT '__W196_ROW__', '#{table}', toString(pk), hex(toJSONString(j)) FROM default.#{table} ORDER BY pk FORMAT TSVRaw;"
      statements << "SELECT '__W196_MIDDLE_ROW__', '#{table}', toString(pk), hex(toJSONString(j)) FROM default.#{table} WHERE pk BETWEEN 3 AND 6 ORDER BY pk FORMAT TSVRaw;"
      statements << "SELECT '__W196_ZERO_BEGIN__', '#{table}', 'zero' FORMAT TSVRaw;"
      statements << "SELECT '__W196_ZERO_ROW__', '#{table}', toString(pk), hex(toJSONString(j)) FROM default.#{table} WHERE pk >= 9 ORDER BY pk FORMAT TSVRaw;"
      statements << "SELECT '__W196_ZERO_COUNT__', '#{table}', toString(count()) FROM default.#{table} WHERE pk >= 9 FORMAT TSVRaw;"
      statements << "SELECT '__W196_ZERO_END__', '#{table}', 'zero' FORMAT TSVRaw;"
    end

    def direct_paths_sql(tables)
      statements = [pin_sql]
      tables.each do |table|
        statements << "SELECT '__W196_PATH_BEGIN__', '#{table}', 'full' FORMAT TSVRaw;"
        statements << direct_path_rows_sql(table, 'full', nil)
        statements << "SELECT '__W196_PATH_END__', '#{table}', 'full' FORMAT TSVRaw;"
        statements << "SELECT '__W196_PATH_BEGIN__', '#{table}', 'middle' FORMAT TSVRaw;"
        statements << direct_path_rows_sql(table, 'middle', ' WHERE pk BETWEEN 3 AND 6')
        statements << "SELECT '__W196_PATH_END__', '#{table}', 'middle' FORMAT TSVRaw;"
        statements << "SELECT '__W196_PATH_BEGIN__', '#{table}', 'zero' FORMAT TSVRaw;"
        statements << direct_path_rows_sql(table, 'zero', ' WHERE pk >= 9')
        statements << "SELECT '__W196_PATH_ZERO_COUNT__', '#{table}', toString(count()) FROM default.#{table} WHERE pk >= 9 FORMAT TSVRaw;"
        statements << "SELECT '__W196_PATH_END__', '#{table}', 'zero' FORMAT TSVRaw;"
      end
      sql = statements.join("\n") + "\n"
      validate_direct_path_sql!(sql, tables)
      sql
    end

    def direct_path_rows_sql(table, window, filter)
      suffix = filter || ''
      ordering = window == 'zero' ? '' : ' ORDER BY pk'
      "SELECT '__W196_PATH_ROW__', '#{table}', '#{window}', toString(pk), dynamicType(j.p), hex(formatRow('RowBinary', dynamicElement(j.p, 'LowCardinality(String)'))), dynamicType(j.a), hex(formatRow('RowBinary', dynamicElement(j.a, 'Array(LowCardinality(UInt8))'))) FROM default.#{table}#{suffix}#{ordering} FORMAT TSVRaw;"
    end

    def validate_direct_path_sql!(sql, tables)
      queries = sql.lines.map(&:chomp).select { |line| line.start_with?("SELECT '__W196_PATH_ROW__'") }
      expected = tables.flat_map { |table| %w[full middle zero].map { |window| [table, window] } }
      actual = queries.map do |query|
        match = query.match(/\ASELECT '__W196_PATH_ROW__', '([^']+)', '(full|middle|zero)',/)
        require!(match, 'direct path query is missing a recognized window identity')
        require!(query.include?("dynamicElement(j.p, 'LowCardinality(String)')") &&
                 query.include?("dynamicElement(j.a, 'Array(LowCardinality(UInt8))')"),
          'direct path query is missing a typed subcolumn expression')
        require!(!query.match?(/formatRow\([^;]*\bj\s*\)/), 'direct path query references the whole JSON column')
        [match[1], match[2]]
      end
      require!(actual == expected, 'direct path SQL query/table/window roster differs')

      marker_events = sql.lines.map(&:chomp).each_with_object([]) do |line, events|
        if (match = line.match(/\ASELECT '__W196_PATH_BEGIN__', '([^']+)', '(full|middle|zero)'/))
          events << ['begin', match[1], match[2]]
        elsif (match = line.match(/\ASELECT '__W196_PATH_ROW__', '([^']+)', '(full|middle|zero)'/))
          events << ['row_query', match[1], match[2]]
        elsif (match = line.match(/\ASELECT '__W196_PATH_END__', '([^']+)', '(full|middle|zero)'/))
          events << ['end', match[1], match[2]]
        elsif (match = line.match(/\ASELECT '__W196_PATH_ZERO_COUNT__', '([^']+)', toString\(count\(\)\).*WHERE pk >= 9/))
          events << ['count', match[1], '0']
        end
      end
      expected_events = tables.flat_map do |table|
        [
          ['begin', table, 'full'], ['row_query', table, 'full'], ['end', table, 'full'],
          ['begin', table, 'middle'], ['row_query', table, 'middle'], ['end', table, 'middle'],
          ['begin', table, 'zero'], ['row_query', table, 'zero'], ['count', table, '0'], ['end', table, 'zero'],
        ]
      end
      require!(marker_events == expected_events, 'direct path SQL marker/count/table roster differs')
      true
    end

    def validate_whole_zero_sql!(sql, tables)
      events = sql.lines.map(&:chomp).each_with_object([]) do |line, result|
        if (match = line.match(/\ASELECT '__W196_ZERO_BEGIN__', '([^']+)'/))
          result << ['begin', match[1]]
        elsif (match = line.match(/\ASELECT '__W196_ZERO_ROW__', '([^']+)'.*WHERE pk >= 9/))
          result << ['row_query', match[1]]
        elsif (match = line.match(/\ASELECT '__W196_ZERO_COUNT__', '([^']+)', toString\(count\(\)\).*WHERE pk >= 9/))
          result << ['count', match[1]]
        elsif (match = line.match(/\ASELECT '__W196_ZERO_END__', '([^']+)'/))
          result << ['end', match[1]]
        end
      end
      expected = tables.flat_map do |table|
        [['begin', table], ['row_query', table], ['count', table], ['end', table]]
      end
      require!(events == expected, 'whole-object zero SQL boundary/query/count/table roster differs')
      true
    end

    def attached_sql
      statements = [pin_sql]
      PAIRED_PROFILE_IDS.each do |id|
        %W[source_#{id} library_#{id}].each do |table|
          if table.start_with?('library_')
            statements << "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0';"
          end
          statements << "SELECT '__W196_CHECK_BEGIN__', '#{table}' FORMAT TSVRaw;"
          statements << "CHECK TABLE default.#{table} FORMAT TSV;"
          statements << "SELECT '__W196_CHECK_END__', '#{table}' FORMAT TSVRaw;"
        end
      end
      quoted = TABLES.map { |table| sql_string(table) }.join(',')
      statements << "SELECT '__W196_SCHEMA__', table, name, type FROM system.columns WHERE database='default' AND table IN (#{quoted}) ORDER BY table, position FORMAT TSVRaw;"
      TABLES.each { |table| append_read_queries(statements, table) }
      sources = TABLES.map { |table| sql_string(table) }.join(',')
      statements << "SELECT '__W196_PART__', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table IN (#{sources}) AND active ORDER BY table,name FORMAT TSVRaw;"
      sql = statements.join("\n") + "\n"
      validate_whole_zero_sql!(sql, TABLES)
      sql
    end

    def pin_sql
      "SELECT '__W196_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;"
    end

    def parse_paired_native(stdout)
      lines = stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
      fields = lambda do |tag|
        lines.each_with_object([]) do |line, records|
          records << line.split("\t", -1) if line.start_with?("#{tag}\t")
        end
      end
      part_records = fields.call('__W196_PART__')
      require!(part_records.all? { |record| record.size == 7 }, 'native part record has wrong field count')
      parts = part_records.to_h do |record|
        [record[1], {name: record[2], path: record[3], part_type: record[4], rows: record[5], marks: record[6]}]
      end
      require!(parts.size == part_records.size, 'native part report has duplicate table records')
      {
        lines: lines,
        pin: fields.call('__W196_PIN__'),
        schemas: fields.call('__W196_SCHEMA__').map { |record| record.drop(1) },
        data_paths: fields.call('__W196_DATA_PATH__').to_h { |record| [record[1], record[2]] },
        parts: parts,
        checks: parse_check_sections(lines),
        rows: parse_read_rows(fields.call('__W196_ROW__')),
        middle_rows: parse_read_rows(fields.call('__W196_MIDDLE_ROW__')),
        zero_rows: parse_read_rows(fields.call('__W196_ZERO_ROW__')),
        zero_events: parse_window_events(lines, '__W196_ZERO_BEGIN__', '__W196_ZERO_COUNT__', '__W196_ZERO_END__'),
        paths: parse_direct_rows(fields.call('__W196_PATH_ROW__')),
        path_events: parse_window_events(lines, '__W196_PATH_BEGIN__', '__W196_PATH_ZERO_COUNT__', '__W196_PATH_END__'),
      }
    end

    # The query text is independently bound to the captured process input.
    # Empty SELECTs produce no row marker, so stdout carries only these bounds.
    def parse_window_events(lines, begin_tag, count_tag, end_tag)
      events = []
      lines.each do |line|
        if line.start_with?("#{begin_tag}\t")
          record = line.split("\t", -1)
          require!(record.size == 3, "#{begin_tag} record has wrong field count")
          events << ['begin', record[1], record[2]]
        elsif line.start_with?("#{count_tag}\t")
          record = line.split("\t", -1)
          require!(record.size == 3, "#{count_tag} record has wrong field count")
          events << ['count', record[1], record[2]]
        elsif line.start_with?("#{end_tag}\t")
          record = line.split("\t", -1)
          require!(record.size == 3, "#{end_tag} record has wrong field count")
          events << ['end', record[1], record[2]]
        end
      end
      events
    end

    def parse_check_sections(lines)
      sections = {}
      active = nil
      lines.each do |line|
        if line.start_with?("__W196_CHECK_BEGIN__\t")
          active = line.split("\t", -1)[1]
          require!(!sections.key?(active), "duplicate CHECK section for #{active}")
          sections[active] = []
        elsif line.start_with?("__W196_CHECK_END__\t")
          table = line.split("\t", -1)[1]
          require!(active == table, "misnested CHECK end for #{table}")
          active = nil
        elsif active
          sections[active] << line
        end
      end
      require!(active.nil?, "unterminated CHECK section #{active}")
      sections
    end

    def parse_read_rows(records)
      records.map do |record|
        require!(record.size == 4, 'whole-object row record has wrong field count')
        [record[1], record[2].to_i, JSON.parse([record[3]].pack('H*'))]
      rescue JSON::ParserError, ArgumentError
        raise CheckError, "invalid whole-object JSON row: #{record.inspect}"
      end
    end

    def parse_direct_rows(records)
      records.map do |record|
        require!(record.size == 8, 'direct path record has wrong field count')
        [record[1], record[2], record[3].to_i, record[4], record[5].downcase,
         record[6], record[7].downcase]
      end
    end

    def assert_sql_invocation!(invocation, label, sql)
      record = invocation.fetch(:record)
      input = sql.b
      expected_file = "#{label}.stdin.sql"
      require!(record.fetch(:process_kind) == 'clickhouse local' &&
               record.fetch(:stdin_file) == expected_file &&
               record.fetch(:stdin_bytes) == input.bytesize &&
               record.fetch(:stdin_sha256) == sha256(input),
        "#{label} invocation is not bound to the authored SQL")
      path = File.join(@root, 'invocations', expected_file)
      captured = read_plain(path, 4 * 1024 * 1024, "#{label} captured SQL")
      require!(captured == input, "#{label} captured SQL bytes differ from the validated query")
      true
    end

    def assert_native!(invocation, label)
      @base.send(:assert_native_invocation!, invocation)
      pin_lines = invocation.fetch(:stdout).force_encoding(Encoding::UTF_8).lines.map(&:chomp)
        .select { |line| line.start_with?("__W196_PIN__\t") }
      require!(pin_lines == ["__W196_PIN__\t#{W185::VERSION}\t#{W185::BUILD}"], "#{label}: runtime pin mismatch or duplicate pin")
    end

    def assert_initial_native!(native)
      require!(native.fetch(:pin).size == 1 && native.fetch(:data_paths).keys.sort == TABLES.sort,
        'initial native pin or table data-path roster differs')
      expected_schemas = TABLES.flat_map { |table| [[table, 'pk', 'UInt64'], [table, 'j', COLUMN_TYPE]] }.sort
      require!(native.fetch(:schemas).sort == expected_schemas, 'initial native exact schema differs')
      expected_sources = PAIRED_PROFILE_IDS.map { |id| "source_#{id}" }
      require!(native.fetch(:checks).keys.sort == expected_sources.sort, 'source CHECK roster differs')
      expected_sources.each do |table|
        require!(native.fetch(:checks).fetch(table) == ["all_1_1_0\t1\t"], "#{table} stock CHECK did not pass")
      end
      require!(native.fetch(:parts).keys.sort == expected_sources.sort, 'initial source part roster differs')
      native.fetch(:parts).each do |table, part|
        require!(part.values_at(:name, :part_type, :rows, :marks) == ['all_1_1_0', 'Wide', '8', '5'], "#{table} is not one expected eight-row Wide part")
      end
    end

    def assert_row_reads!(native, tables)
      expected_full = PAIRED_ROWS.each_with_index.map { |row, index| [nil, index + 1, row] }
      expected_middle = expected_full[2, 4]
      expected_zero_events = tables.flat_map do |table|
        [['begin', table, 'zero'], ['count', table, '0'], ['end', table, 'zero']]
      end
      require!(native.fetch(:zero_events) == expected_zero_events,
        'whole-object zero-window boundary/count/table roster differs')
      tables.each do |table|
        actual_full = native.fetch(:rows).select { |record| record[0] == table }
        actual_middle = native.fetch(:middle_rows).select { |record| record[0] == table }
        actual_zero = native.fetch(:zero_rows).select { |record| record[0] == table }
        require!(actual_full.map { |record| record.drop(1) } == expected_full.map { |record| record.drop(1) }, "#{table} full literal rows differ")
        require!(actual_middle.map { |record| record.drop(1) } == expected_middle.map { |record| record.drop(1) }, "#{table} middle literal rows differ")
        require!(actual_zero.empty?, "#{table} zero-window query returned rows")
      end
      full_groups = native.fetch(:rows).group_by(&:first)
      middle_groups = native.fetch(:middle_rows).group_by(&:first)
      require!(full_groups.keys.sort == tables.sort && full_groups.values.all? { |rows| rows.size == 8 },
        'whole-object read row/table roster differs')
      require!(middle_groups.keys.sort == tables.sort && middle_groups.values.all? { |rows| rows.size == 4 },
        'whole-object middle-window row/table roster differs')
    end

    def assert_direct_paths!(native, tables)
      expected_path_events = tables.flat_map do |table|
        [
          ['begin', table, 'full'], ['end', table, 'full'],
          ['begin', table, 'middle'], ['end', table, 'middle'],
          ['begin', table, 'zero'], ['count', table, '0'], ['end', table, 'zero'],
        ]
      end
      require!(native.fetch(:path_events) == expected_path_events,
        'direct path window marker/count/table roster differs')

      expected_by_window = PAIRED_ROWS.each_with_index.map do |row, index|
        p_type = row.key?('p') ? 'LowCardinality(String)' : 'None'
        a_type = row.key?('a') ? 'Array(LowCardinality(UInt8))' : 'None'
        [index + 1, p_type, PAIRED_EXPECTED_PATH_HEX.fetch('p')[index],
         a_type, PAIRED_EXPECTED_PATH_HEX.fetch('a')[index]]
      end
      tables.each do |table|
        full = native.fetch(:paths).select { |record| record[0] == table && record[1] == 'full' }
        middle = native.fetch(:paths).select { |record| record[0] == table && record[1] == 'middle' }
        zero = native.fetch(:paths).select { |record| record[0] == table && record[1] == 'zero' }
        require!(full.map { |record| record.drop(2) } == expected_by_window,
          "#{table} direct full path values differ")
        require!(middle.map { |record| record.drop(2) } == expected_by_window[2, 4],
          "#{table} direct middle path values differ")
        require!(zero.empty?, "#{table} direct zero-window query returned rows")
      end
      path_groups = native.fetch(:paths).group_by(&:first)
      require!(path_groups.keys.sort == tables.sort &&
               path_groups.all? do |_table, rows|
                 rows.count { |record| record[1] == 'full' } == 8 &&
                   rows.count { |record| record[1] == 'middle' } == 4 &&
                   rows.none? { |record| record[1] == 'zero' }
               end,
        'direct path full/middle row/table roster differs')
    end

    def helper_identity_summary(sha_before, sha_after)
      {'path' => @helper, 'sha256_before' => sha_before, 'sha256_after' => sha_after}
    end

    def assert_helper_identity!(invocation, sha_before, sha_after, summary_identity = nil)
      record = invocation.fetch(:record)
      require!(sha_before.match?(/\A[0-9a-f]{64}\z/) && sha_after.match?(/\A[0-9a-f]{64}\z/),
        'helper SHA evidence is malformed')
      require!(sha_before == sha_after, 'prebuilt helper SHA-256 changed during invocation')
      require!(record.fetch(:process_kind) == 'prebuilt Crystal helper' &&
               record.fetch(:argv) == [@helper, File.join(@root, HELPER_INPUT_NAME), File.join(@root, 'generated')] &&
               record.fetch(:expected_binary_sha256) == sha_before &&
               record.fetch(:binary_sha_after) == sha_after,
        'helper invocation record is not bound to the stable executable SHA-256')
      argv_bytes = JSON.pretty_generate(record.fetch(:argv)) + "\n"
      require!(record.fetch(:argv_sha256) == sha256(argv_bytes) &&
               record.fetch(:stdin_bytes) == 0 && record.fetch(:stdin_sha256) == sha256(''.b),
        'helper invocation argv or stdin digest differs')
      require!(record.fetch(:stdout_bytes) == invocation.fetch(:stdout).bytesize &&
               record.fetch(:stdout_sha256) == sha256(invocation.fetch(:stdout)) &&
               record.fetch(:stderr_bytes) == invocation.fetch(:stderr).bytesize &&
               record.fetch(:stderr_sha256) == sha256(invocation.fetch(:stderr)),
        'helper invocation output digests differ from captured bytes')
      if summary_identity
        require!(summary_identity == helper_identity_summary(sha_before, sha_after),
          'helper summary SHA evidence differs from the invocation identity')
      end
      true
    end

    def inspect_profiles(paths, role, generated_library: false)
      PAIRED_PROFILE_IDS.to_h do |id|
        info = if role == 'stock'
          @source_part_info.fetch(id)
        else
          {name: 'all_1_1_0', path: paths.fetch(id), part_type: 'Wide', rows: '8', marks: '5'}
        end
        part = @base.send(:inspect_part, "#{role}_#{id}", paths.fetch(id), info,
                          generated_library: generated_library)
        shared, string, = PROFILE_SETTINGS.fetch(id)
        require!(part[:part_type] == 'Wide' && part[:rows] == '8' && part[:marks] == '5', "#{role} #{id} part dimensions differ")
        require!(part[:ordinary_string_serialization_version] == string, "#{role} #{id} ordinary String metadata differs")
        [id, part]
      end
    end

    def assert_library_profile!(inventories)
      require!(inventories.keys.sort == PAIRED_PROFILE_IDS.sort, 'library inventory profile roster differs')
      inventories.each do |id, inventory|
        require!(inventory[:mark_triples].values.all? { |triples| triples.size == 5 }, "#{id} library physical mark count differs")
      end
    end

    def validate_helper_envelope!(output)
      require!(output.is_a?(Hash) && output.keys.sort == %w[format profiles].sort, 'paired helper output top-level schema differs')
      require!(output['format'] == PAIRED_HELPER_FORMAT, 'paired helper output format differs')
      records = output['profiles']
      require!(records.is_a?(Array) && records.map { |record| record['id'] } == PAIRED_PROFILE_IDS, 'paired helper profile order differs')
      records.each_with_index do |record, index|
        id = PAIRED_PROFILE_IDS[index]
        shared, string, = PROFILE_SETTINGS.fetch(id)
        require!(record['shared_version'] == shared && record['string_version'] == string &&
                 record['bucket_count'] == 2 && record['row_count'] == 8 && record['mark_row_counts'] == [2, 2, 2, 2],
          "#{id} helper physical selector/grid differs")
        require!(File.expand_path(record['source_part']) == @source_parts.fetch(id) &&
                 File.expand_path(record['library_part']) == @library_parts.fetch(id), "#{id} helper part path differs")
      end
    end

    def reconcile_helper!(input, output)
      reconciler_path = File.join(__dir__, 'object_shared_low_cardinality_paired_reconciler_w196.rb')
      require!(File.file?(reconciler_path) && !File.symlink?(reconciler_path), 'strict paired helper reconciler is not available')
      require_relative 'object_shared_low_cardinality_paired_reconciler_w196'
      ObjectSharedLowCardinalityPairedReconcilerW196.reconcile!(input, output)
    end

    def assert_attached_native!(native)
      expected_tables = TABLES.sort
      require!(native.fetch(:checks).keys.sort == expected_tables, 'attached CHECK table roster differs')
      expected_tables.each do |table|
        require!(native.fetch(:checks).fetch(table) == ["all_1_1_0\t1\t"], "#{table} stock CHECK did not pass")
      end
      expected_schemas = TABLES.flat_map { |table| [[table, 'pk', 'UInt64'], [table, 'j', COLUMN_TYPE]] }.sort
      require!(native.fetch(:schemas).sort == expected_schemas, 'attached exact schema differs')
      assert_row_reads!(native, TABLES)
      expected_parts = TABLES.to_h { |table| [table, 'all_1_1_0'] }
      require!(native.fetch(:parts).keys.sort == expected_tables, 'attached active part roster differs')
      expected_parts.each do |table, name|
        part = native.fetch(:parts).fetch(table)
        require!(part.values_at(:name, :part_type, :rows, :marks) == [name, 'Wide', '8', '5'], "#{table} attached part dimensions differ")
      end
    end

    def sql_string(value)
      @base.send(:sql_string, value)
    end

    def create_evidence_layout!
      require!(File.directory?(@root) && !File.symlink?(@root) && File.realpath(@root) == @root &&
               File.dirname(@root) == File.realpath('/private/tmp') && Dir.children(@root).empty?,
        'evidence root must be an empty canonical direct child of /private/tmp')
      %w[invocations stores generated parts].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      Dir.mkdir(File.join(@root, 'stores', 'native'), 0o700)
      Dir.mkdir(File.join(@root, 'generated', 'input'), 0o700)
      PAIRED_PROFILE_IDS.each do |id|
        Dir.mkdir(File.join(@root, 'generated', id), 0o700)
        Dir.mkdir(File.join(@root, 'parts', id), 0o700)
      end
    end

    def write_paired_summary(data)
      summary = {
        'probe' => 'W196 paired persisted Object shared LowCardinality native/helper qualification',
        'status' => data[:status],
        'fatal_error' => data[:fatal_error],
      'runtime' => {
          'path' => @binary, 'expected_sha256' => W185::BINARY_SHA256,
          'sha256_before' => @sha_before, 'sha256_after' => @sha_after,
          'expected_version' => W185::VERSION, 'expected_build' => W185::BUILD,
      },
      'helper_path' => @helper,
        'helper_identity' => @helper_identity || helper_identity_summary(@helper_sha_before, @helper_sha_after),
        'limits' => {max_threads: 1, local_max_memory_usage_bytes: W185::MEMORY,
                     required_outer_run_safe_memory_limit_bytes: W185::OUTER_RUN_SAFE_LIMIT,
                     timeout_seconds: W185::TIMEOUT, termination_grace_seconds: W185::GRACE},
        'profiles' => PAIRED_PROFILE_IDS,
        'rows' => PAIRED_ROWS,
        'expected_direct_path_types' => PAIRED_PATH_TYPES,
        'expected_direct_path_hex' => PAIRED_EXPECTED_PATH_HEX,
        'evidence_root' => @root,
        'invocations' => @invocations,
      }.merge(data.reject { |key, _| %i[status fatal_error].include?(key) })
      @base.send(:write_new, File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
    end
  end

  def require!(condition, message)
    raise CheckError, message unless condition
  end

  def sha256(bytes)
    Digest::SHA256.hexdigest(bytes)
  end

  def read_plain(path, max_bytes, label)
    require!(File.file?(path) && !File.symlink?(path), "#{label} is not a plain file")
    size = File.size(path)
    require!(size <= max_bytes, "#{label} exceeds its read bound")
    bytes = File.binread(path)
    require!(bytes.bytesize == size, "#{label} changed while being read")
    bytes
  end

  def verify_capture!(capture_root)
    root = File.realpath(capture_root)
    part = File.join(root, PART_RELATIVE)
    require!(File.directory?(part) && !File.symlink?(part), 'retained native part is absent or symlinked')

    CAPTURE_HASHES.each do |relative, expected_sha|
      path = File.join(root, relative)
      bytes = read_plain(path, 4 * 1024 * 1024, relative)
      require!(sha256(bytes) == expected_sha, "#{relative} differs from its immutable capture hash")
    end

    record_bytes = File.binread(File.join(root, 'invocations/object_lc.json'))
    record = JSON.parse(record_bytes)
    argv_bytes = File.binread(File.join(root, 'invocations/object_lc.argv.json'))
    argv = JSON.parse(argv_bytes)
    require!(record['argv'] == argv, 'captured argv file and invocation record differ')
    require!(record['argv_sha256'] == sha256(argv_bytes), 'captured argv digest differs')
    require!(record['stdin_file'] == 'object_lc.stdin.sql', 'invocation does not name the captured SQL input')
    require!(record['stdin_bytes'] == File.size(File.join(root, 'invocations/object_lc.stdin.sql')), 'captured SQL byte count differs')
    require!(record['stdin_sha256'] == CAPTURE_HASHES.fetch('invocations/object_lc.stdin.sql'), 'captured SQL digest differs')
    require!(record['stdout_file'] == 'object_lc.stdout' && record['stderr_file'] == 'object_lc.stderr', 'invocation output artifact names differ')
    require!(record['stdout_bytes'] == File.size(File.join(root, 'invocations/object_lc.stdout')), 'captured stdout byte count differs')
    require!(record['stdout_sha256'] == CAPTURE_HASHES.fetch('invocations/object_lc.stdout'), 'captured stdout digest differs')
    require!(record['stderr_bytes'] == 0 && record['stderr_sha256'] == CAPTURE_HASHES.fetch('invocations/object_lc.stderr'), 'captured stderr is not empty')
    require!(record['exit'] == 0 && record['signal'].nil? && record['timed_out'] == false && record['process_classification'] == 'success', 'captured ClickHouse invocation was not a clean success')
    require!(record['expected_binary_sha256'] == RUNTIME_SHA256 && record['binary_sha_after'] == RUNTIME_SHA256, 'captured runtime binary hash differs from the pin')
    require!(record['process_kind'] == 'clickhouse local' && record['max_threads'] == 1 && record['max_memory_usage_bytes'] == 536_870_912, 'captured invocation is outside the bounded local profile')
    require!(argv.size == 8 && argv[1] == 'local' && argv[2] == '--path' && File.expand_path(argv[3]) == File.join(root, 'stores/native'), 'captured argv is not the expected local store invocation')
    require!(argv[0].end_with?('/clickhouse-stripped'), 'captured executable name differs')

    stdout = File.binread(File.join(root, 'invocations/object_lc.stdout'))
    verify_native_stdout!(stdout, part)
    input = File.binread(File.join(root, 'input.rowbinary'))
    require!(input.bytesize == 80, 'RowBinary control input byte count differs')

    part_names = Dir.children(part).sort
    require!(part_names.size == 43 && part_names.all? { |name| File.file?(File.join(part, name)) && !File.symlink?(File.join(part, name)) }, 'retained part direct-file inventory is unexpected')
    inventory = part_names.map do |name|
      bytes = read_plain(File.join(part, name), 16 * 1024 * 1024, "part file #{name}")
      "#{name}\0#{bytes.bytesize}\0#{sha256(bytes)}\n"
    end.join
    require!(sha256(inventory) == PART_INVENTORY_SHA256, 'retained part inventory differs from the authenticated native capture')
    {
      'capture_root' => root,
      'part_relative' => PART_RELATIVE,
      'part_file_count' => part_names.size,
      'runtime_version' => RUNTIME_VERSION,
      'runtime_build' => RUNTIME_BUILD,
      'runtime_sha256' => RUNTIME_SHA256,
      'invocation_sha256' => CAPTURE_HASHES.fetch('invocations/object_lc.json'),
      'stdout_sha256' => CAPTURE_HASHES.fetch('invocations/object_lc.stdout'),
      'rowbinary_sha256' => CAPTURE_HASHES.fetch('input.rowbinary'),
      'part_inventory_sha256' => PART_INVENTORY_SHA256,
    }
  rescue JSON::ParserError => error
    raise CheckError, "captured invocation JSON is invalid: #{error.message}"
  end

  def verify_native_stdout!(stdout, part)
    lines = stdout.lines(chomp: true)
    expected = [["__W185_PIN__", RUNTIME_VERSION, RUNTIME_BUILD].join("\t")]
    NATIVE_ROWS.each do |pk, dynamic_p, dynamic_a, rowbinary_hex, paths|
      expected << ["__W196_VALUE__", pk, dynamic_p, dynamic_a, rowbinary_hex, paths].join("\t")
    end
    expected << ["__W196_PART__", 'all_1_1_0', "#{File.expand_path(part)}/"].join("\t")
    require!(lines == expected, 'retained native SQL rows differ from the authored four-row literals')
  end

  def verify_inspection!(document)
    require!(document.is_a?(Hash), 'inspector output is not a JSON object')
    expected_top = %w[
      format status row_count mark_row_counts shared_data_version bucket_count
      ordinary_string_profile paths codec_work transport_work
    ].sort
    require!(document.keys.sort == expected_top, 'inspector output fields differ from the sealed schema')
    require!(document['format'] == 'object_shared_low_cardinality_w196_inspection_v1' && document['status'] == 'observed', 'inspector identity differs')
    require!(document['row_count'] == 4 && document['mark_row_counts'] == [2, 2] && document['shared_data_version'] == 2 && document['bucket_count'] == 2, 'inspector physical profile differs from the retained fixture')
    require!(document['ordinary_string_profile'] == 'with_size', 'inspector did not inherit the captured String v1 profile')

    paths = document['paths']
    require!(paths.is_a?(Array) && paths.size == EXPECTED_PATHS.size, 'inspector path count differs from the literal physical observations')
    paths.each_with_index do |actual, index|
      require!(actual.is_a?(Hash), "path observation #{index} is not an object")
      expected = EXPECTED_PATHS[index]
      require!(actual.keys.sort == %w[bucket_index parent_index chunk_index row_count name dynamic_types events data_hex values].sort, "path observation #{index} fields differ")
      expected.each do |key, value|
        if key == 'events'
          actual_events = actual.fetch(key)
          expected_events = value.map { |name, offset| {'name' => name, 'offset' => offset} }
          require!(actual_events == expected_events, "path observation #{index} ordered event tape differs")
        else
          require!(actual[key] == value, "path observation #{index} #{key} differs from its authored literal")
        end
      end
    end

    require!(
      paths.map { |path| path.fetch('dynamic_types').fetch(0) }.uniq.sort ==
        ['Array(LowCardinality(UInt8))', 'LowCardinality(String)'].sort,
      'actual roster is not the two ordinary LowCardinality witnesses'
    )
    require!(paths.none? { |path| path.fetch('dynamic_types').include?('SharedVariant') }, 'shared arm was confused with an actual LowCardinality type')
    verify_work_counters!(document)
    {
      'path_observations' => paths.size,
      'actual_types' => ['LowCardinality(String)', 'Array(LowCardinality(UInt8))'],
      'lc_dictionary_prefix_events' => paths.sum { |path| path.fetch('events').count { |event| event.fetch('name').end_with?('.dict_prefix') } },
      'empty_dictionary_body_offsets_equal_indexes' => true,
      'raw_path_data_hex' => paths.map { |path| path.fetch('data_hex') },
    }
  end

  def verify_work_counters!(document)
    codec = document.fetch('codec_work')
    transport = document.fetch('transport_work')
    require!(codec.is_a?(Hash) && codec.keys.sort == %w[nodes elements wire_bytes].sort, 'codec work counters are malformed')
    require!(transport.is_a?(Hash) && transport.keys.sort == %w[file_bytes records decoded_bytes result_bytes].sort, 'transport work counters are malformed')
    require!(codec == {'nodes' => 346, 'elements' => 5591, 'wire_bytes' => 12320}, 'shared codec budget work differs from the retained witness')
    require!(transport == {'file_bytes' => 2752, 'records' => 60, 'decoded_bytes' => 2043, 'result_bytes' => 2043}, 'shared transport budget work differs from the retained witness')
  end

  def sample_inspection
    {
      'format' => 'object_shared_low_cardinality_w196_inspection_v1',
      'status' => 'observed',
      'row_count' => 4,
      'mark_row_counts' => [2, 2],
      'shared_data_version' => 2,
      'bucket_count' => 2,
      'ordinary_string_profile' => 'with_size',
      'paths' => EXPECTED_PATHS.map do |path|
        path.transform_values do |value|
          if value.is_a?(Array) && value.first.is_a?(Array)
            value.map { |name, offset| {'name' => name, 'offset' => offset} }
          else
            value
          end
        end
      end,
      'codec_work' => {'nodes' => 346, 'elements' => 5591, 'wire_bytes' => 12320},
      'transport_work' => {'file_bytes' => 2752, 'records' => 60, 'decoded_bytes' => 2043, 'result_bytes' => 2043},
    }
  end

  def self_test!
    positive = verify_inspection!(sample_inspection)
    require!(positive['path_observations'] == 4, 'positive self-test did not retain all four path observations')
    mutations = [
      ['actual roster', ->(doc) { doc['paths'][0]['dynamic_types'] = ['String']; }],
      ['SharedVariant substitution', ->(doc) { doc['paths'][2]['dynamic_types'] = ['SharedVariant']; }],
      ['dictionary prefix event', ->(doc) { doc['paths'][0]['events'].delete_at(2); }],
      ['event order', ->(doc) { doc['paths'][2]['events'].reverse!; }],
      ['data bytes', ->(doc) { doc['paths'][0]['data_hex'] = doc['paths'][0]['data_hex'].sub('726564', '626c7565'); }],
      ['decoded value', ->(doc) { doc['paths'][2]['values'][0]['value'] = [7, 8]; }],
      ['empty dictionary body offset', ->(doc) { doc['paths'][0]['events'][4]['offset'] += 1; }],
    ]
    mutations.each do |label, mutation|
      candidate = JSON.parse(JSON.generate(sample_inspection))
      mutation.call(candidate)
      begin
        verify_inspection!(candidate)
      rescue CheckError
        next
      end
      raise CheckError, "self-test did not reject #{label} mutation"
    end
    puts JSON.generate({'format' => FORMAT, 'status' => 'self_test_passed', 'mutations_rejected' => mutations.map(&:first)})
  end

  def paired_self_test!
    probe = PairedProbe.allocate
    helper = '/private/tmp/w196-self-test/helper'
    root = '/private/tmp/w196-self-test/root'
    probe.instance_variable_set(:@helper, helper)
    probe.instance_variable_set(:@root, root)

    tables = %w[source_v2_string0 library_v2_string0]
    direct_sql = probe.send(:direct_paths_sql, tables)
    whole_sql = probe.send(:rows_sql, tables)
    direct_query = probe.send(:direct_path_rows_sql, tables.first, 'zero', ' WHERE pk >= 9')
    missing_direct_query = direct_sql.sub("#{direct_query}\n", '')
    missing_direct_boundary = direct_sql.sub("SELECT '__W196_PATH_BEGIN__', '#{tables.first}', 'zero' FORMAT TSVRaw;\n", '')
    reordered_direct_boundary = direct_sql.sub(
      "SELECT '__W196_PATH_BEGIN__', '#{tables.first}', 'zero' FORMAT TSVRaw;\n#{direct_query}\n",
      "#{direct_query}\nSELECT '__W196_PATH_BEGIN__', '#{tables.first}', 'zero' FORMAT TSVRaw;\n")
    missing_whole_query = whole_sql.sub(
      "SELECT '__W196_ZERO_ROW__', '#{tables.first}', toString(pk), hex(toJSONString(j)) FROM default.#{tables.first} WHERE pk >= 9 ORDER BY pk FORMAT TSVRaw;\n", '')
    expect_rejection!('omitted direct zero query') { probe.send(:validate_direct_path_sql!, missing_direct_query, tables) }
    expect_rejection!('omitted direct zero boundary') { probe.send(:validate_direct_path_sql!, missing_direct_boundary, tables) }
    expect_rejection!('reordered direct zero boundary') { probe.send(:validate_direct_path_sql!, reordered_direct_boundary, tables) }
    expect_rejection!('omitted whole zero query') { probe.send(:validate_whole_zero_sql!, missing_whole_query, tables) }

    native = paired_self_test_native(tables)
    probe.send(:assert_row_reads!, native, tables)
    probe.send(:assert_direct_paths!, native, tables)

    parsed_native = probe.send(:parse_paired_native, paired_self_test_tsv(tables.first))
    probe.send(:assert_row_reads!, parsed_native, [tables.first])
    probe.send(:assert_direct_paths!, parsed_native, [tables.first])
    malformed_boundary = paired_self_test_tsv(tables.first).sub(
      "__W196_ZERO_END__\t#{tables.first}\tzero\n",
      "__W196_ZERO_END__\t#{tables.first}\n")
    expect_rejection!('malformed parsed whole zero boundary') do
      probe.send(:parse_paired_native, malformed_boundary)
    end

    poisoned_path = Marshal.load(Marshal.dump(native))
    poisoned_path[:paths][0][4] = '0000'
    expect_rejection!('altered direct-path literal') { probe.send(:assert_direct_paths!, poisoned_path, tables) }
    missing_zero_marker = Marshal.load(Marshal.dump(native))
    missing_zero_marker[:path_events].delete(['count', tables.first, '0'])
    expect_rejection!('omitted direct zero count marker') { probe.send(:assert_direct_paths!, missing_zero_marker, tables) }
    missing_whole_boundary = Marshal.load(Marshal.dump(native))
    missing_whole_boundary[:zero_events].delete(['end', tables.first, 'zero'])
    expect_rejection!('omitted whole zero end marker') { probe.send(:assert_row_reads!, missing_whole_boundary, tables) }

    sha = 'a' * 64
    argv = [helper, File.join(root, PairedProbe::HELPER_INPUT_NAME), File.join(root, 'generated')]
    stdout = '{"status":"ok"}'.b
    stderr = ''.b
    invocation_record = {
      process_kind: 'prebuilt Crystal helper', argv: argv,
      argv_sha256: sha256(JSON.pretty_generate(argv) + "\n"),
      expected_binary_sha256: sha, binary_sha_after: sha,
      stdin_bytes: 0, stdin_sha256: sha256(''.b),
      stdout_bytes: stdout.bytesize, stdout_sha256: sha256(stdout),
      stderr_bytes: stderr.bytesize, stderr_sha256: sha256(stderr),
    }
    helper_invocation = {record: invocation_record, stdout: stdout, stderr: stderr}
    summary_identity = probe.send(:helper_identity_summary, sha, sha)
    probe.send(:assert_helper_identity!, helper_invocation, sha, sha, summary_identity)
    wrong_summary = summary_identity.merge('sha256_after' => 'b' * 64)
    expect_rejection!('helper summary SHA mutation') do
      probe.send(:assert_helper_identity!, helper_invocation, sha, sha, wrong_summary)
    end
    wrong_record = {record: invocation_record.merge(binary_sha_after: 'b' * 64), stdout: stdout, stderr: stderr}
    expect_rejection!('helper invocation SHA mutation') do
      probe.send(:assert_helper_identity!, wrong_record, sha, sha, summary_identity)
    end

    puts JSON.generate({
      'format' => PAIRED_HELPER_FORMAT,
      'status' => 'paired_self_test_passed',
      'rejected' => [
        'omitted direct zero query', 'omitted direct zero boundary', 'reordered direct zero boundary',
        'omitted whole zero query', 'altered direct-path literal', 'omitted direct zero count marker',
        'omitted whole zero end marker', 'malformed parsed whole zero boundary',
        'helper summary SHA mutation', 'helper invocation SHA mutation',
      ],
      'parsed_tsv_positive' => true,
    })
  end

  def paired_self_test_tsv(table)
    lines = []
    PAIRED_ROWS.each_with_index do |row, index|
      lines << ['__W196_ROW__', table, (index + 1).to_s, JSON.generate(row).unpack1('H*')].join("\t")
    end
    PAIRED_ROWS.each_with_index do |row, index|
      next unless (3..6).cover?(index + 1)
      lines << ['__W196_MIDDLE_ROW__', table, (index + 1).to_s, JSON.generate(row).unpack1('H*')].join("\t")
    end
    lines << ['__W196_ZERO_BEGIN__', table, 'zero'].join("\t")
    lines << ['__W196_ZERO_COUNT__', table, '0'].join("\t")
    lines << ['__W196_ZERO_END__', table, 'zero'].join("\t")

    %w[full middle zero].each do |window|
      lines << ['__W196_PATH_BEGIN__', table, window].join("\t")
      indices = window == 'full' ? (0...8).to_a : (window == 'middle' ? (2...6).to_a : [])
      indices.each do |index|
        lines << [
          '__W196_PATH_ROW__', table, window, (index + 1).to_s,
          PAIRED_PATH_TYPES.fetch('p')[index], PAIRED_EXPECTED_PATH_HEX.fetch('p')[index],
          PAIRED_PATH_TYPES.fetch('a')[index], PAIRED_EXPECTED_PATH_HEX.fetch('a')[index],
        ].join("\t")
      end
      lines << ['__W196_PATH_ZERO_COUNT__', table, '0'].join("\t") if window == 'zero'
      lines << ['__W196_PATH_END__', table, window].join("\t")
    end
    lines.join("\n") + "\n"
  end

  def paired_self_test_native(tables)
    rows = tables.flat_map do |table|
      PAIRED_ROWS.each_with_index.map { |row, index| [table, index + 1, row] }
    end
    middle_rows = rows.select { |_table, pk, _row| (3..6).cover?(pk) }
    paths = tables.flat_map do |table|
      PAIRED_ROWS.each_with_index.map do |_row, index|
        [table, 'full', index + 1,
         PAIRED_PATH_TYPES.fetch('p')[index], PAIRED_EXPECTED_PATH_HEX.fetch('p')[index],
         PAIRED_PATH_TYPES.fetch('a')[index], PAIRED_EXPECTED_PATH_HEX.fetch('a')[index]]
      end + PAIRED_ROWS.each_with_index.map do |_row, index|
        next unless (3..6).cover?(index + 1)
        [table, 'middle', index + 1,
         PAIRED_PATH_TYPES.fetch('p')[index], PAIRED_EXPECTED_PATH_HEX.fetch('p')[index],
         PAIRED_PATH_TYPES.fetch('a')[index], PAIRED_EXPECTED_PATH_HEX.fetch('a')[index]]
      end.compact
    end
    path_events = tables.flat_map do |table|
      [
        ['begin', table, 'full'], ['end', table, 'full'],
        ['begin', table, 'middle'], ['end', table, 'middle'],
        ['begin', table, 'zero'], ['count', table, '0'], ['end', table, 'zero'],
      ]
    end
    zero_events = tables.flat_map do |table|
      [['begin', table, 'zero'], ['count', table, '0'], ['end', table, 'zero']]
    end
    {rows: rows, middle_rows: middle_rows, zero_rows: [], zero_events: zero_events,
     paths: paths, path_events: path_events}
  end

  def expect_rejection!(label)
    rejected = false
    begin
      yield
    rescue CheckError
      rejected = true
    end
    raise CheckError, "paired self-test did not reject #{label}" unless rejected
  end

  def run(argv)
    if argv == ['--paired-self-test']
      paired_self_test!
      return
    end
    return run_paired(argv.drop(1)) if argv.first == '--paired'

    options = {}
    parser = OptionParser.new do |opts|
      opts.banner = 'usage: ruby scripts/check_object_shared_low_cardinality_w196.rb --capture-root ROOT --inspector-json PATH'
      opts.on('--capture-root PATH', 'Retained native W196 capture root') { |value| options[:capture_root] = value }
      opts.on('--inspector-json PATH', 'Output from the Crystal inspector') { |value| options[:inspector_json] = value }
      opts.on('--self-test', 'Run literal positive and seeded-negative validator controls') { options[:self_test] = true }
    end
    parser.parse!(argv)
    if options.keys == [:self_test] && argv.empty?
      self_test!
      return
    end
    require!(argv.empty? && options.keys.sort == %i[capture_root inspector_json].sort, parser.banner)
    capture = verify_capture!(options.fetch(:capture_root))
    inspection_bytes = read_plain(options.fetch(:inspector_json), 4 * 1024 * 1024, 'Crystal inspector output')
    inspection = JSON.parse(inspection_bytes)
    path_observation = verify_inspection!(inspection)
    puts JSON.generate({
      'format' => FORMAT,
      'status' => 'reconciled_observation_only',
      'capture' => capture,
      'inspector_sha256' => sha256(inspection_bytes),
      'path_observation' => path_observation,
      'runtime_compatibility_claim' => 'not_established_by_this_four_row_inspection',
    })
  rescue OptionParser::ParseError, CheckError, JSON::ParserError, Errno::ENOENT, Errno::EACCES => error
    warn "W196 LowCardinality reconciliation failed: #{error.class}: #{error.message}"
    exit 1
  end

  def run_paired(argv)
    options = {binary: W185::BINARY}
    parser = OptionParser.new do |opts|
      opts.banner = 'usage: ruby scripts/check_object_shared_low_cardinality_w196.rb --paired --helper PREBUILT_HELPER --evidence-root EMPTY_CHILD_OF_PRIVATE_TMP [--binary CLICKHOUSE]'
      opts.on('--binary PATH', 'Pinned ClickHouse executable') { |value| options[:binary] = value }
      opts.on('--helper PATH', 'Prebuilt W196 Crystal paired helper') { |value| options[:helper] = value }
      opts.on('--evidence-root PATH', 'Fresh empty direct child of /private/tmp') { |value| options[:evidence_root] = value }
    end
    parser.parse!(argv)
    require!(argv.empty? && options[:helper] && options[:evidence_root], parser.banner)
    probe = PairedProbe.new(options[:binary], options[:helper], options[:evidence_root])
    exit(probe.run ? 0 : 1)
  rescue OptionParser::ParseError, CheckError, JSON::ParserError, Errno::ENOENT, Errno::EACCES, ArgumentError => error
    warn "W196 paired LowCardinality runner failed: #{error.class}: #{error.message}"
    exit 1
  end
end

CheckObjectSharedLowCardinalityW196.run(ARGV)
