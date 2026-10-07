#!/usr/bin/env ruby
# Root-run paired stock/library qualification for public QBit Object parts.
# This runner does not build either executable; native children are supervised
# by the bounded W185/W180 executor and every SQL stdin is saved before launch.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'tmpdir'
require_relative 'check_array_json_parts_w185'

module CheckObjectSharedQBitPartsW200
  W185 = CheckArrayJSONPartsW185
  W180 = JsonBinaryKernelW180Probe
  BINARY = W185::BINARY
  BINARY_SHA256 = W185::BINARY_SHA256
  VERSION = W185::VERSION
  BUILD = W185::BUILD
  MEMORY = W185::MEMORY
  TIMEOUT = W185::TIMEOUT
  GRACE = W185::GRACE
  OUTER_RUN_SAFE_LIMIT = W185::OUTER_RUN_SAFE_LIMIT

  INPUT_FORMAT = 'object_shared_qbit_parts_w200_input_v1'.freeze
  HELPER_FORMAT = 'object_shared_qbit_parts_w200_helper_v1'.freeze
  COLUMN_TYPE = 'JSON(max_dynamic_types=1, max_dynamic_paths=0)'.freeze
  COLUMN = 'j'.freeze
  PATH = 'q'.freeze
  # ClickHouse loadPartAndFixMetadataImpl writes this ATTACH-derived metadata
  # for the regular system columns {_block_number, _block_offset}.
  ATTACH_INVALIDATED_SYSTEM_COLUMNS = {
    name: 'invalidated_system_columns.txt'.freeze,
    content: "_block_offset\n_block_number\n".b.freeze,
    size: 28,
    sha256: '7409424ab45090c1261e622f7423393905102e7e8cba36a6db88eb513ce1e06c'.freeze,
  }.freeze
  CARRIERS = [
    {name: 'Int8', width: 1, tag: 0x07},
    {name: 'BFloat16', width: 2, tag: 0x31},
    {name: 'Float32', width: 4, tag: 0x0d},
    {name: 'Float64', width: 8, tag: 0x0e},
  ].freeze
  SHAPES = [
    {name: 'dim3', dimension: 3, stride: 3, explicit_stride: false},
    {name: 'dim9', dimension: 9, stride: 9, explicit_stride: false},
    {name: 'stride16_8', dimension: 16, stride: 8, explicit_stride: true},
  ].freeze
  PROFILE_DEFS = CARRIERS.each_with_index.flat_map do |carrier, carrier_index|
    SHAPES.flat_map do |shape|
      [2, 3].flat_map do |shared_version|
        [0, 1].map do |string_profile|
          type_name = shape[:explicit_stride] ?
            "QBit(#{carrier[:name]}, #{shape[:dimension]}, #{shape[:stride]})" :
            "QBit(#{carrier[:name]}, #{shape[:dimension]})"
          {
            id: "#{carrier[:name].downcase}_#{shape[:name]}_v#{shared_version}_s#{string_profile}".freeze,
            carrier: carrier[:name], carrier_index: carrier_index, width: carrier[:width], tag: carrier[:tag],
            dimension: shape[:dimension], stride: shape[:stride], explicit_stride: shape[:explicit_stride],
            shared_version: shared_version, string_profile: string_profile, type_name: type_name.freeze,
          }.freeze
        end
      end
    end
  end.freeze
  PROFILE_IDS = PROFILE_DEFS.map { |profile| profile[:id] }.freeze
  WINDOWS = {'FULL' => [1, 2, 3, 4], 'MIDDLE' => [3, 4], 'ZERO' => []}.freeze

  class Probe
    def initialize(helper, evidence_root)
      @binary = validate_executable(BINARY, 'ClickHouse')
      @helper = validate_executable(helper, 'Crystal helper')
      @root = validate_root(evidence_root)
      @executor = W185::Probe.new(@binary, @helper, @root)
      @invocations = []
      @fatal_error = nil
      @profiles = PROFILE_DEFS
      @parts = {}
      @part_paths = {}
      @part_snapshots = {}
      @active_part_paths = {}
      @active_part_snapshots = {}
      @source_whole = {}
      @data_paths = {}
    end

    def run
      prepare_layout!
      @binary_sha_before = binary_sha
      fail!('pinned ClickHouse executable SHA mismatch before probe') unless @binary_sha_before == BINARY_SHA256
      @helper_sha_before = helper_sha
      fail!('Crystal helper SHA changed before probe') unless @helper_sha_before == helper_sha

      @profiles.each { |profile| write_new(input_path(profile), rowbinary(profile)) }

      groups = @profiles.group_by { |profile| [profile[:shared_version], profile[:string_profile]] }
      groups.each do |(shared_version, string_profile), profiles|
        label = "native_sources_v#{shared_version}_s#{string_profile}"
        invocation = run_clickhouse(label, initial_sql(profiles))
        assert_native_invocation!(invocation)
        native = parse_native(invocation[:stdout])
        assert_pin!(native)
        assert_source_group!(native, profiles)
      end

      helper_input = build_helper_input
      helper_input_path = File.join(@root, 'generated', 'helper-input.json')
      write_new(helper_input_path, JSON.pretty_generate(helper_input) + "\n")
      helper = run_helper(helper_input_path, File.join(@root, 'generated'))
      assert_helper_output!(helper[:data], helper_input)

      groups.each do |(shared_version, string_profile), profiles|
        attach_library_parts!(profiles)
        label = "attach_and_check_v#{shared_version}_s#{string_profile}"
        invocation = run_clickhouse(label, attached_sql(profiles))
        assert_native_invocation!(invocation)
        native = parse_native(invocation[:stdout])
        assert_pin!(native)
        assert_attached_group!(native, profiles)
      end

      @part_snapshots_after = @part_paths.to_h { |table, path| [table, snapshot_part(path)] }
      fail!('stock or generated part bytes changed during attach/read qualification') unless @part_snapshots_after == @part_snapshots
      @active_part_snapshots_after = @active_part_paths.to_h do |table, path|
        active_path = validate_attached_native_part!(path, table, 'all_1_1_0')
        [table, snapshot_part(active_path)]
      end
      fail!('attached native part bytes changed during read qualification') unless @active_part_snapshots_after == @active_part_snapshots
      @binary_sha_after = binary_sha
      @helper_sha_after = helper_sha
      fail!('ClickHouse executable SHA changed during probe') unless @binary_sha_after == BINARY_SHA256
      fail!('Crystal helper SHA changed during probe') unless @helper_sha_after == @helper_sha_before
      write_summary(
        status: 'paired_public_qbit_parts_observed', helper: helper[:data],
        helper_invocation: helper[:record], source_part_snapshots: @part_snapshots,
        part_snapshots_after: @part_snapshots_after,
        attached_native_part_paths: @active_part_paths,
        attached_native_part_snapshots: @active_part_snapshots,
        attached_native_part_snapshots_after: @active_part_snapshots_after,
      )
      puts "W200 public QBit complete-part profiles=#{PROFILE_IDS.size}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      @binary_sha_after = binary_sha rescue nil
      @helper_sha_after = helper_sha rescue nil
      write_failure_summary rescue nil
      warn "W200 runner failure (not a format rejection): #{@fatal_error}"
      false
    end

    def self.self_test!
      probe = allocate
      raise 'fixed 48-profile roster changed' unless PROFILE_DEFS.size == 48 && PROFILE_IDS.uniq.size == 48
      raise 'profile matrix order changed' unless PROFILE_IDS.first == 'int8_dim3_v2_s0' && PROFILE_IDS.last == 'float64_stride16_8_v3_s1'
      first = PROFILE_DEFS.first
      raw_a = probe.send(:literal_raw, first, 0)
      raw_b = probe.send(:literal_raw, first, 1)
      raise 'independent signed-zero/NaN literal prefix changed' unless raw_a.byteslice(0, 3).bytes == [0xff, 0x00, 0x80]
      raise 'second independent Int8 literal prefix changed' unless raw_b.byteslice(0, 3).bytes == [0x00, 0x80, 0xff]
      raise 'nullable QBit RowBinary A bytes changed' unless probe.send(:nullable_payload_hex, first, raw_a) == '0003FF0080'
      raise 'nullable absent-QBit RowBinary bytes changed' unless probe.send(:nullable_payload_hex, first, nil) == '01'
      zero = "\x00".b * first[:dimension] * first[:width]
      raise 'nullable present-zero QBit RowBinary bytes changed' unless probe.send(:nullable_payload_hex, first, zero) == '0003000000'
      row = probe.send(:rowbinary, first)
      raise 'RowBinary row count/length changed' unless row.bytesize == 3 * 18 + 9

      table = "source_#{first[:id]}"
      sample = [
        "__W200_PIN__\t#{VERSION}\t#{BUILD}",
        "__W200_CHECK_BEGIN__\t#{table}\t#{first[:id]}",
        "all_1_1_0\t1\t",
        "__W200_CHECK_END__\t#{table}\t#{first[:id]}",
        "__W200_PART__\t#{table}\tall_1_1_0\t/private/tmp/p\tWide\t4\t3",
        "__W200_ZERO_BEGIN__\t#{table}\tzero\twhole",
        "__W200_ZERO_END__\t#{table}\tzero\twhole",
      ].join("\n")
      parsed = probe.send(:parse_native, sample)
      raise 'runtime pin parsing changed' unless parsed[:pin] == ['__W200_PIN__', VERSION, BUILD]
      raise 'CHECK block capture changed' unless parsed[:checks] == {[table, first[:id]] => ["all_1_1_0\t1\t"]}
      raise 'zero-window boundaries changed' unless parsed[:zero_events] == [
        ['__W200_ZERO_BEGIN__', table, 'zero', 'whole'], ['__W200_ZERO_END__', table, 'zero', 'whole'],
      ]

      reject = lambda do |label, &operation|
        begin
          operation.call
        rescue StandardError
          next
        end
        raise "#{label} was accepted"
      end
      part_line = "__W200_PART__\t#{table}\tall_1_1_0\t/private/tmp/p\tWide\t4\t3"
      reject.call('duplicate active part') { probe.send(:parse_native, sample + "\n" + part_line) }
      reject.call('unknown native stdout marker') { probe.send(:parse_native, sample + "\n__W200_UNKNOWN__\tbad") }
      reject.call('unexpected native stdout') { probe.send(:parse_native, sample + "\nunmarked output") }
      reject.call('unclosed CHECK block') do
        probe.send(:parse_native, "__W200_PIN__\t#{VERSION}\t#{BUILD}\n__W200_CHECK_BEGIN__\tx\ty")
      end

      groups = PROFILE_DEFS.group_by { |profile| [profile[:shared_version], profile[:string_profile]] }
      group = groups.fetch([2, 0])
      names = group.to_h { |profile| [profile[:id], probe.send(:source_table, profile)] }
      expected = probe.send(:expected_direct_rows, group, names)
      raise 'global typed-row cardinality changed' unless expected.size == group.size * 6
      expected_zero = probe.send(:expected_zero_events, group, names)
      raise 'source zero-window roster/order changed' unless expected_zero == group.flat_map do |profile|
        %w[whole type direct].flat_map do |kind|
          [['__W200_ZERO_BEGIN__', names.fetch(profile[:id]), 'zero', kind],
           ['__W200_ZERO_END__', names.fetch(profile[:id]), 'zero', kind]]
        end
      end
      reject.call('zero-window map must be keyed by profile ID') do
        probe.send(:expected_zero_events, group, names.values)
      end

      attached_names = group.to_h do |profile|
        id = profile[:id]
        [id, [probe.send(:source_table, profile), probe.send(:library_table, profile)]]
      end
      attached_zero = probe.send(:expected_zero_events, group, attached_names)
      expected_attached_zero = group.flat_map do |profile|
        attached_names.fetch(profile[:id]).flat_map do |table_name|
          %w[whole type direct].flat_map do |kind|
            [['__W200_ZERO_BEGIN__', table_name, 'zero', kind],
             ['__W200_ZERO_END__', table_name, 'zero', kind]]
          end
        end
      end
      raise 'attached zero-window roster/order changed' unless attached_zero == expected_attached_zero

      schema_tables = [names.fetch(group.first[:id]), attached_names.fetch(group.first[:id]).last]
      expected_schema = probe.send(:expected_schema, schema_tables)
      raise 'schema roster is not an exact table/column-to-type map' unless expected_schema == {
        [schema_tables[0], 'pk'] => 'UInt64', [schema_tables[0], COLUMN] => COLUMN_TYPE,
        [schema_tables[1], 'pk'] => 'UInt64', [schema_tables[1], COLUMN] => COLUMN_TYPE,
      }
      probe.send(:assert_schema_roster!, expected_schema, schema_tables, 'self-test exact schema')
      reject.call('schema triple-array shape') do
        probe.send(:assert_schema_roster!, expected_schema.flat_map { |key, value| [key + [value]] }, schema_tables, 'self-test wrong shape')
      end
      reject.call('schema roster missing a column') do
        probe.send(:assert_schema_roster!, expected_schema.reject { |key, _| key == [schema_tables[0], 'pk'] }, schema_tables, 'self-test missing column')
      end

      order_profiles = group.first(2)
      source_map = order_profiles.to_h { |profile| [profile[:id], probe.send(:source_table, profile)] }
      attached_map = order_profiles.to_h do |profile|
        [profile[:id], [probe.send(:source_table, profile), probe.send(:library_table, profile)]]
      end
      [source_map, attached_map].each_with_index do |table_map, map_index|
        actual_query_order = order_profiles.flat_map do |profile|
          probe.send(:table_names, table_map.fetch(profile[:id])).flat_map do |table_name|
            probe.send(:read_queries, table_name, profile).map do |sql|
              match = sql.match(/SELECT '__W200_(WHOLE|TYPE|DIRECT)_(FULL|MIDDLE|ZERO)__'/)
              [table_name, match[2], match[1].downcase] if match
            end.compact
          end
        end
        expected_query_order = order_profiles.flat_map do |profile|
          probe.send(:table_names, table_map.fetch(profile[:id])).flat_map do |table_name|
            WINDOWS.keys.flat_map do |window|
              %w[whole type direct].map { |kind| [table_name, window, kind] }
            end
          end
        end
        raise "native SQL family/window order changed for table map #{map_index}" unless actual_query_order == expected_query_order

        native_lines = ["__W200_PIN__\t#{VERSION}\t#{BUILD}"]
        # read_queries emits each profile/table's FULL then MIDDLE family;
        # parse_window_rows canonicalizes globally to window/profile/table.
        order_profiles.each do |profile|
          probe.send(:table_names, table_map.fetch(profile[:id])).each do |table_name|
            WINDOWS.each do |window, pks|
              pks.each do |pk|
                raw = probe.send(:raw_rows, profile).fetch(pk - 1)
                type_name = raw.nil? ? 'None' : profile[:type_name]
                native_lines << "__W200_TYPE_#{window}__\t#{table_name}\t#{pk}\t#{type_name}"
                native_lines << "__W200_DIRECT_#{window}__\t#{table_name}\t#{pk}\t#{type_name}\t#{probe.send(:nullable_payload_hex, profile, raw)}"
                native_lines << "__W200_WHOLE_#{window}__\t#{table_name}\t#{pk}\t00"
              end
            end
          end
        end
        parsed_order = probe.send(:parse_native, native_lines.join("\n"))
        expected_type = probe.send(:expected_type_rows, order_profiles, table_map)
        expected_direct = probe.send(:expected_direct_rows, order_profiles, table_map)
        raise "global native family ordering changed for table map #{map_index}" unless
          parsed_order[:type_rows] == expected_type && parsed_order[:direct_rows] == expected_direct &&
          parsed_order[:whole_rows].map { |row| row.slice(:table, :pk, :window) } ==
            probe.send(:expected_whole_roster, order_profiles, table_map)
      end

      reject.call('duplicate global typed row') do
        probe.send(:require_exact_rows!, expected + [expected.first], expected, 'self-test duplicate')
      end
      reject.call('unknown table/global typed row') do
        extra = expected + [expected.first.merge(table: 'unknown_table')]
        probe.send(:require_exact_rows!, extra, expected, 'self-test unknown table')
      end

      roster = {'object_dynamic_paths' => [], 'dynamic_roster' => [], 'typed_paths' => []}
      probe.send(:assert_shared_only_roster!, roster, first, 'self-test')
      roster.each_key do |key|
        reject.call("nonempty #{key} shared-only roster") do
          probe.send(:assert_shared_only_roster!, roster.merge(key => ['q']), first, 'self-test')
        end
      end

      Dir.mktmpdir('w200-native-part-self-test-', '/private/tmp') do |temporary_root|
        native_store = File.join(temporary_root, 'stores', 'native')
        native_data = File.join(native_store, 'data', 'default', table)
        active_part = File.join(native_data, 'all_1_1_0')
        FileUtils.mkdir_p(active_part)
        FileUtils.mkdir_p(File.join(temporary_root, 'stores', 'native'))
        probe.instance_variable_set(:@root, temporary_root)
        probe.instance_variable_set(:@data_paths, {table => native_data})
        validated = probe.send(:validate_attached_native_part!, active_part, table, 'all_1_1_0')
        raise 'canonical attached native part path changed' unless validated == File.realpath(active_part)
        reject.call('attached native part outside its table path') do
          outside = File.join(native_store, 'data', 'default', 'other', 'all_1_1_0')
          FileUtils.mkdir_p(outside)
          probe.send(:validate_attached_native_part!, outside, table, 'all_1_1_0')
        end
        reject.call('attached native part with wrong name') do
          wrongly_named = File.join(native_data, 'all_2_2_0')
          FileUtils.mkdir_p(wrongly_named)
          probe.send(:validate_attached_native_part!, wrongly_named, table, 'all_1_1_0')
        end
        published_part = File.join(temporary_root, 'published')
        FileUtils.mkdir_p(published_part)
        File.binwrite(File.join(published_part, 'data.bin'), "\x00\x80\xff".b)
        File.binwrite(File.join(active_part, 'data.bin'), "\x00\x80\xff".b)
        published_snapshot = probe.send(:snapshot_part, published_part)
        invalidated_path = File.join(active_part, ATTACH_INVALIDATED_SYSTEM_COLUMNS.fetch(:name))
        File.binwrite(invalidated_path, ATTACH_INVALIDATED_SYSTEM_COLUMNS.fetch(:content))
        attached_snapshot = probe.send(:snapshot_part, active_part)
        library = "library_#{first[:id]}"
        probe.send(:assert_attached_part_snapshot_matches!, active_part, attached_snapshot, published_snapshot, library, allow_native_invalidation: true)
        reject.call('source part cannot acquire attached invalidation metadata') do
          probe.send(:assert_attached_part_snapshot_matches!, active_part, attached_snapshot, published_snapshot, table, allow_native_invalidation: false)
        end
        reject.call('attached invalidation metadata with wrong content') do
          File.binwrite(invalidated_path, "_block_offset\n_block_number\x00".b)
          wrong_content_snapshot = probe.send(:snapshot_part, active_part)
          probe.send(:assert_attached_part_snapshot_matches!, active_part, wrong_content_snapshot, published_snapshot, library, allow_native_invalidation: true)
        end
        File.binwrite(invalidated_path, ATTACH_INVALIDATED_SYSTEM_COLUMNS.fetch(:content))
        File.binwrite(File.join(active_part, 'unexpected.txt'), 'extra'.b)
        reject.call('attached part with unknown added filename') do
          unknown_file_snapshot = probe.send(:snapshot_part, active_part)
          probe.send(:assert_attached_part_snapshot_matches!, active_part, unknown_file_snapshot, published_snapshot, library, allow_native_invalidation: true)
        end
      end

      puts 'W200 Ruby self-test passed: raw RowBinary literals, shared-only reader rosters, canonical attached paths, strict native ATTACH metadata, source/attached schemas and zero windows, global read ordering, and strict marker/cardinality controls.'
      true
    end

    private

    def prepare_layout!
      %w[invocations inputs stores generated].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      Dir.mkdir(File.join(@root, 'stores', 'native'), 0o700)
    end

    def validate_root(path)
      fail!('fresh evidence root is required') unless path && !path.empty?
      full = File.expand_path(path)
      fail!('evidence root must be a direct child of /private/tmp') unless File.dirname(full) == File.realpath('/private/tmp')
      fail!('evidence root must not be symlinked') if File.symlink?(full)
      fail!('evidence root must already exist and be empty') unless File.directory?(full) && File.realpath(full) == full && Dir.children(full).empty?
      full
    rescue Errno::ENOENT
      fail!('evidence root must already exist')
    end

    def validate_executable(path, label)
      fail!("#{label} path missing") unless path && !path.empty?
      full = File.expand_path(path)
      fail!("#{label} is not a plain executable") unless File.file?(full) && File.executable?(full) && !File.symlink?(full)
      full
    end

    def binary_sha
      Digest::SHA256.file(@binary).hexdigest
    end

    def helper_sha
      Digest::SHA256.file(@helper).hexdigest
    end

    def settings(profile)
      inherited = W185::SETTINGS.split(', ').reject do |setting|
        setting.start_with?('object_shared_data_serialization_version=') ||
          setting.start_with?('object_shared_data_serialization_version_for_zero_level_parts=') ||
          setting.start_with?('object_shared_data_buckets_for_wide_part=') ||
          setting.start_with?('object_shared_data_target_chunk_rows=') ||
          setting.start_with?('string_serialization_version=') ||
          setting.start_with?('serialization_info_version=') ||
          setting.start_with?('propagate_types_serialization_versions_to_nested_types=') ||
          setting.start_with?('map_serialization_version=') ||
          setting.start_with?('map_serialization_version_for_zero_level_parts=')
      end
      shared = profile[:shared_version] == 2 ? 'advanced' : 'advanced_chunked'
      string = profile[:string_profile] == 0 ? 'single_stream' : 'with_size_stream'
      inherited.concat([
        "object_shared_data_serialization_version='#{shared}'",
        "object_shared_data_serialization_version_for_zero_level_parts='#{shared}'",
        'object_shared_data_buckets_for_wide_part=2', 'object_shared_data_target_chunk_rows=1',
        "serialization_info_version='with_types'", "string_serialization_version='#{string}'",
        'propagate_types_serialization_versions_to_nested_types=1',
      ])
      inherited.join(', ')
    end

    def input_path(profile)
      File.join(@root, 'inputs', "#{profile[:id]}.rowbinary")
    end

    def source_table(profile)
      "source_#{profile[:id]}"
    end

    def library_table(profile)
      "library_#{profile[:id]}"
    end

    def rowbinary(profile)
      raw_rows(profile).each_with_index.map do |raw, index|
        fields = raw.nil? ? ''.b : wire_string(PATH) + qbit_descriptor(profile) + varuint(profile[:dimension]) + raw
        [index + 1].pack('Q<') + varuint(raw.nil? ? 0 : 1) + fields
      end.join.b
    end

    def raw_rows(profile)
      [literal_raw(profile, 0), nil, ("\x00".b * (profile[:dimension] * profile[:width])), literal_raw(profile, 1)]
    end

    def literal_raw(profile, row)
      # Independently authored fixed bit-pattern prefixes: signed zero and
      # distinct NaN payloads for floating carriers; no decimal conversion.
      prefixes = {
        'Int8' => [[0xff, 0x00, 0x80], [0x00, 0x80, 0xff]],
        'BFloat16' => [[0x00, 0x80, 0xc1, 0x7f, 0xc2, 0x7f], [0xc1, 0x7f, 0xc2, 0x7f, 0x00, 0x80]],
        'Float32' => [[0x00, 0x00, 0x00, 0x80, 0x01, 0x00, 0xc0, 0x7f, 0x02, 0x00, 0xc0, 0x7f], [0x01, 0x00, 0xc0, 0x7f, 0x02, 0x00, 0xc0, 0x7f, 0x00, 0x00, 0x00, 0x80]],
        'Float64' => [[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf8, 0x7f, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf8, 0x7f], [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf8, 0x7f, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf8, 0x7f, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80]],
      }.fetch(profile[:carrier])
      prefix = prefixes.fetch(row).pack('C*').b
      bytes = Array.new(profile[:dimension] * profile[:width]) do |index|
        if index < prefix.bytesize
          prefix.getbyte(index)
        else
          (row * 67 + index * 31 + profile[:carrier_index] * 19 + profile[:dimension] * 11 + profile[:stride] * 7) & 0xff
        end
      end
      bytes.pack('C*').b
    end

    def qbit_descriptor(profile)
      descriptor = [profile[:explicit_stride] ? 0x37 : 0x36, profile[:tag]].pack('C*').b
      descriptor << varuint(profile[:dimension])
      descriptor << varuint(profile[:stride]) if profile[:explicit_stride]
      descriptor
    end

    def payload_hex(profile, raw)
      (varuint(profile[:dimension]) + raw).unpack1('H*').upcase
    end

    def nullable_payload_hex(profile, raw)
      raw ? ("\x00".b + [payload_hex(profile, raw)].pack('H*')).unpack1('H*').upcase : '01'
    end

    def varuint(value)
      output = +''.b
      loop do
        byte = value & 0x7f
        value >>= 7
        output << [byte | (value.zero? ? 0 : 0x80)].pack('C')
        break if value.zero?
      end
      output
    end

    def wire_string(value)
      bytes = value.b
      varuint(bytes.bytesize) + bytes
    end

    def initial_sql(profiles)
      statements = [pin_sql]
      profiles.each do |profile|
        source = source_table(profile)
        library = library_table(profile)
        table_settings = settings(profile)
        statements << "CREATE TABLE default.#{source} (pk UInt64, j #{COLUMN_TYPE}) ENGINE=MergeTree ORDER BY pk SETTINGS #{table_settings};"
        statements << "CREATE TABLE default.#{library} (pk UInt64, j #{COLUMN_TYPE}) ENGINE=MergeTree ORDER BY pk SETTINGS #{table_settings};"
        escaped = input_path(profile).gsub("'", "\\'")
        statements << "INSERT INTO default.#{source} SELECT * FROM file('#{escaped}', 'RowBinary', 'pk UInt64, j #{COLUMN_TYPE}') SETTINGS input_format_binary_read_json_as_string=0, flatten_nested=0, allow_suspicious_low_cardinality_types=1;"
        statements << check_sql(source, profile)
      end
      tables = profiles.flat_map { |profile| [source_table(profile), library_table(profile)] }
      statements << schema_sql(tables)
      statements << data_paths_sql(tables)
      statements << parts_sql(profiles.map { |profile| source_table(profile) })
      profiles.each { |profile| statements.concat(read_queries(source_table(profile), profile)) }
      statements.join("\n") + "\n"
    end

    def attached_sql(profiles)
      statements = [pin_sql]
      profiles.each do |profile|
        statements << "ALTER TABLE default.#{library_table(profile)} ATTACH PART 'all_1_1_0';"
        statements << check_sql(source_table(profile), profile)
        statements << check_sql(library_table(profile), profile)
      end
      tables = profiles.flat_map { |profile| [source_table(profile), library_table(profile)] }
      statements << schema_sql(tables)
      statements << parts_sql(tables)
      profiles.each do |profile|
        statements.concat(read_queries(source_table(profile), profile))
        statements.concat(read_queries(library_table(profile), profile))
      end
      statements.join("\n") + "\n"
    end

    def pin_sql
      "SELECT '__W200_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;"
    end

    def check_sql(table, profile)
      [
        "SELECT '__W200_CHECK_BEGIN__', '#{table}', '#{profile[:id]}' FORMAT TSVRaw;",
        "CHECK TABLE default.#{table} FORMAT TSV;",
        "SELECT '__W200_CHECK_END__', '#{table}', '#{profile[:id]}' FORMAT TSVRaw;",
      ].join("\n")
    end

    def schema_sql(tables)
      quoted = tables.map { |table| "'#{table}'" }.join(',')
      "SELECT '__W200_SCHEMA__', table, name, type FROM system.columns WHERE database='default' AND table IN (#{quoted}) ORDER BY table, position FORMAT TSVRaw;"
    end

    def data_paths_sql(tables)
      quoted = tables.map { |table| "'#{table}'" }.join(',')
      "SELECT '__W200_DATA_PATH__', name, arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name IN (#{quoted}) ORDER BY name FORMAT TSVRaw;"
    end

    def parts_sql(tables)
      quoted = tables.map { |table| "'#{table}'" }.join(',')
      "SELECT '__W200_PART__', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table IN (#{quoted}) AND active ORDER BY table,name FORMAT TSVRaw;"
    end

    def read_queries(table, profile)
      type_name = profile[:type_name].gsub("'", "''")
      query_specs = [
        ['whole', "SELECT '__W200_WHOLE_{{WINDOW}}__', '#{table}', toString(pk), hex(formatRow('RowBinary', j)) FROM default.#{table}{{PREDICATE}} ORDER BY pk SETTINGS output_format_binary_write_json_as_string=0 FORMAT TSVRaw;"],
        ['type', "SELECT '__W200_TYPE_{{WINDOW}}__', '#{table}', toString(pk), dynamicType(j.q) FROM default.#{table}{{PREDICATE}} ORDER BY pk FORMAT TSVRaw;"],
        ['direct', "SELECT '__W200_DIRECT_{{WINDOW}}__', '#{table}', toString(pk), dynamicType(j.q), hex(formatRow('RowBinary', dynamicElement(j.q, '#{type_name}'))) FROM default.#{table}{{PREDICATE}} ORDER BY pk FORMAT TSVRaw;"],
      ]
      result = []
      WINDOWS.each do |window, pks|
        predicate = window == 'FULL' ? '' : window == 'MIDDLE' ? ' WHERE pk BETWEEN 3 AND 4' : ' WHERE pk > 4'
        query_specs.each do |kind, sql_template|
          if window == 'ZERO'
            result << "SELECT '__W200_ZERO_BEGIN__', '#{table}', 'zero', '#{kind}' FORMAT TSVRaw;"
          end
          result << sql_template.gsub('{{WINDOW}}', window).gsub('{{PREDICATE}}', predicate)
          if window == 'ZERO'
            result << "SELECT '__W200_ZERO_END__', '#{table}', 'zero', '#{kind}' FORMAT TSVRaw;"
          end
        end
      end
      result
    end

    def build_helper_input
      capture_root = File.realpath(File.join(@root, 'stores', 'native'))
      parts = @profiles.map do |profile|
        {
          'id' => profile[:id], 'part' => @part_paths.fetch(source_table(profile)),
          'carrier' => profile[:carrier], 'dimension' => profile[:dimension], 'stride' => profile[:stride],
          'explicit_stride' => profile[:explicit_stride], 'shared_version' => profile[:shared_version],
          'string_profile' => profile[:string_profile], 'bucket_count' => 2,
          'type_name' => profile[:type_name],
        }
      end
      {'format' => INPUT_FORMAT, 'capture_root' => capture_root, 'profiles' => parts}
    end

    def parse_native(stdout)
      lines = stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
      fail!('native stdout is not valid UTF-8') unless lines.all?(&:valid_encoding?)
      recognized = [
        '__W200_PIN__', '__W200_CHECK_BEGIN__', '__W200_CHECK_END__', '__W200_PART__',
        '__W200_SCHEMA__', '__W200_DATA_PATH__', '__W200_ZERO_BEGIN__', '__W200_ZERO_END__',
      ] + %w[FULL MIDDLE ZERO].flat_map { |window| ["__W200_WHOLE_#{window}__", "__W200_TYPE_#{window}__", "__W200_DIRECT_#{window}__"] }
      checks = {}
      active = nil
      lines.each do |line|
        if line.start_with?('__W200_CHECK_BEGIN__')
          fields = strict_fields(line, '__W200_CHECK_BEGIN__', 3)
          fail!('CHECK block nesting is invalid') if active
          active = fields.drop(1)
          fail!('duplicate CHECK block') if checks.key?(active)
          checks[active] = []
        elsif line.start_with?('__W200_CHECK_END__')
          fields = strict_fields(line, '__W200_CHECK_END__', 3)
          fail!('CHECK end has no matching begin') unless active == fields.drop(1)
          active = nil
        elsif active
          checks[active] << line
        else
          prefix = recognized.find { |candidate| line == candidate || line.start_with?(candidate + "\t") }
          fail!("unknown or unexpected native stdout outside CHECK block: #{line.inspect}") unless prefix
          fail!("malformed native marker #{line.inspect}") if line == prefix
        end
      end
      fail!('unclosed CHECK block') if active

      pin_rows = tagged_rows(lines, '__W200_PIN__', 3)
      fail!('runtime pin marker must occur exactly once') unless pin_rows.size == 1
      parts = unique_records(tagged_rows(lines, '__W200_PART__', 7), 'active part', 1) do |fields|
        [fields[1], {name: fields[2], path: fields[3], part_type: fields[4], rows: fields[5], marks: fields[6]}]
      end
      schemas = unique_records(tagged_rows(lines, '__W200_SCHEMA__', 4), 'schema', 1) do |fields|
        [[fields[1], fields[2]], fields[3]]
      end
      data_paths = unique_records(tagged_rows(lines, '__W200_DATA_PATH__', 3), 'table data path', 1) do |fields|
        [fields[1], fields[2]]
      end
      whole_rows = parse_window_rows(lines, 'WHOLE', 4) do |fields, window|
        {table: fields[1], pk: fields[2], hex: fields[3].upcase, window: window}
      end
      type_rows = parse_window_rows(lines, 'TYPE', 4) do |fields, window|
        {table: fields[1], pk: fields[2], type: fields[3], window: window}
      end
      direct_rows = parse_window_rows(lines, 'DIRECT', 5) do |fields, window|
        {table: fields[1], pk: fields[2], type: fields[3], hex: fields[4].upcase, window: window}
      end
      zero_events = lines.each_with_object([]) do |line, events|
        next unless line.start_with?('__W200_ZERO_BEGIN__') || line.start_with?('__W200_ZERO_END__')
        events << strict_fields(line, line.start_with?('__W200_ZERO_BEGIN__') ? '__W200_ZERO_BEGIN__' : '__W200_ZERO_END__', 4)
      end
      {
        pin: pin_rows.first, checks: checks, parts: parts, schemas: schemas, data_paths: data_paths,
        whole_rows: whole_rows, type_rows: type_rows, direct_rows: direct_rows, zero_events: zero_events,
      }
    end

    def strict_fields(line, tag, width)
      fail!("malformed #{tag} marker") unless line.start_with?(tag + "\t")
      fields = line.split("\t", -1)
      fail!("#{tag} marker has wrong field width") unless fields.size == width
      fields
    end

    def tagged_rows(lines, tag, width)
      lines.select { |line| line.start_with?(tag) }.map { |line| strict_fields(line, tag, width) }
    end

    def unique_records(rows, label, key_index)
      rows.each_with_object({}) do |fields, records|
        key, value = yield fields
        fail!("duplicate #{label} record #{key.inspect}") if records.key?(key)
        records[key] = value
      end
    end

    def parse_window_rows(lines, family, width)
      records = []
      %w[FULL MIDDLE ZERO].each do |window|
        tag = "__W200_#{family}_#{window}__"
        lines.each do |line|
          next unless line.start_with?(tag)
          records << yield(strict_fields(line, tag, width), window.downcase)
        end
      end
      records
    end

    def require_exact_rows!(actual, expected, label)
      fail!("#{label} global cardinality/order differs: actual=#{actual.size}, expected=#{expected.size}") unless actual == expected
    end

    def expected_native_rows(profiles, tables, kind)
      WINDOWS.flat_map do |window, pks|
        profiles.flat_map do |profile|
          table_names(tables.fetch(profile[:id])).flat_map do |table|
            pks.map do |pk|
              raw = raw_rows(profile).fetch(pk - 1)
              case kind
              when :type
                {table: table, pk: pk.to_s, type: raw.nil? ? 'None' : profile[:type_name], window: window.downcase}
              when :direct
                {table: table, pk: pk.to_s, type: raw.nil? ? 'None' : profile[:type_name],
                 hex: nullable_payload_hex(profile, raw), window: window.downcase}
              else
                raise ArgumentError, 'unknown W200 row kind'
              end
            end
          end
        end
      end
    end

    def table_names(value)
      value.is_a?(Array) ? value : [value]
    end

    def expected_direct_rows(profiles, tables)
      expected_native_rows(profiles, profiles.to_h { |profile| [profile[:id], tables.fetch(profile[:id])] }, :direct)
    end

    def expected_type_rows(profiles, tables)
      expected_native_rows(profiles, profiles.to_h { |profile| [profile[:id], tables.fetch(profile[:id])] }, :type)
    end

    def assert_source_group!(native, profiles)
      source_names = profiles.to_h { |profile| [profile[:id], source_table(profile)] }
      library_names = profiles.to_h { |profile| [profile[:id], library_table(profile)] }
      expected_source_tables = source_names.values.sort
      all_tables = (source_names.values + library_names.values).sort
      fail!('initial native source part roster differs from exact batch') unless native[:parts].keys.sort == expected_source_tables
      assert_schema_roster!(native[:schemas], all_tables, 'initial native source/library declarations')
      fail!('native data-path roster differs from exact source/library tables') unless native[:data_paths].keys.sort == all_tables
      native[:data_paths].each_value { |path| validate_store_path!(path) }
      expected_checks = profiles.to_h do |profile|
        table = source_table(profile)
        [[table, profile[:id]], ["all_1_1_0\t1\t"]]
      end
      fail!('initial CHECK results differ from exact source roster') unless native[:checks] == expected_checks
      assert_exact_readback!(native, profiles, source_names, initial: true)
      expected_zero = expected_zero_events(profiles, source_names)
      fail!('initial zero-window boundary roster/order differs') unless native[:zero_events] == expected_zero

      profiles.each do |profile|
        table = source_table(profile)
        part = native[:parts].fetch(table)
        fail!("#{table} is not the expected fresh 4-row Wide part with final index mark") unless
          part[:name] == 'all_1_1_0' && part[:part_type] == 'Wide' && part[:rows] == '4' && part[:marks] == '3'
        path = validate_source_part!(part[:path])
        @part_paths[table] = path
        @part_snapshots[table] = snapshot_part(path)
        @parts[table] = part
        @data_paths[table] = native[:data_paths].fetch(table)
        native_library_path = native[:data_paths].fetch(library_table(profile))
        @data_paths[library_table(profile)] = validate_store_path!(native_library_path)
      end
      native[:whole_rows].each do |record|
        @source_whole[[record[:table], record[:pk], record[:window]]] = record[:hex]
      end
    end

    def assert_exact_readback!(native, profiles, name_by_id, initial:)
      expected_type = expected_type_rows(profiles, name_by_id)
      expected_direct = expected_direct_rows(profiles, name_by_id)
      require_exact_rows!(native[:type_rows], expected_type, 'native dynamicType')
      require_exact_rows!(native[:direct_rows], expected_direct, 'native direct typed QBit RowBinary')

      expected_whole_roster = expected_whole_roster(profiles, name_by_id)
      actual_whole_roster = native[:whole_rows].map { |row| row.slice(:table, :pk, :window) }
      require_exact_rows!(actual_whole_roster, expected_whole_roster, 'native whole-Object RowBinary')
      native[:whole_rows].each do |row|
        fail!('whole-Object RowBinary output is not nonempty even-length hex') unless row[:hex].match?(/\A(?:[0-9A-F]{2})+\z/)
      end
      unless initial
        profiles.each do |profile|
          [source_table(profile), library_table(profile)].each do |table|
            WINDOWS.each do |window, pks|
              pks.each do |pk|
                fail!("#{table} whole-Object bytes differ from stock/library pair") unless
                  @source_whole.fetch([source_table(profile), pk.to_s, window.downcase]) ==
                  native[:whole_rows].find { |row| row[:table] == table && row[:pk] == pk.to_s && row[:window] == window.downcase }&.fetch(:hex)
              end
            end
          end
        end
      end
    end

    def expected_zero_events(profiles, tables)
      profiles.flat_map do |profile|
        table_names(tables.fetch(profile[:id])).flat_map do |table|
          %w[whole type direct].flat_map do |kind|
            [['__W200_ZERO_BEGIN__', table, 'zero', kind], ['__W200_ZERO_END__', table, 'zero', kind]]
          end
        end
      end
    end

    def expected_whole_roster(profiles, name_by_id)
      WINDOWS.flat_map do |window, pks|
        profiles.flat_map do |profile|
          table_names(name_by_id.fetch(profile[:id])).flat_map do |table|
            pks.map { |pk| {table: table, pk: pk.to_s, window: window.downcase} }
          end
        end
      end
    end

    def expected_schema(tables)
      tables.flat_map { |table| [[[table, 'pk'], 'UInt64'], [[table, COLUMN], COLUMN_TYPE]] }.to_h
    end

    def assert_schema_roster!(actual, tables, label)
      expected = expected_schema(tables)
      fail!("#{label} schema roster differs") unless actual == expected
      true
    end

    def assert_helper_output!(helper, input)
      fail!('helper top-level fields/format differ') unless helper.keys.sort == %w[capture_root format generated_root profile_count profile_ids profiles] && helper['format'] == HELPER_FORMAT
      fail!('helper capture/generated roots differ') unless File.expand_path(helper['capture_root']) == File.expand_path(input.fetch('capture_root')) &&
        File.expand_path(helper['generated_root']) == File.join(@root, 'generated')
      fail!('helper profile roster/count differs') unless helper['profile_count'] == 48 && helper['profile_ids'] == PROFILE_IDS && helper['profiles'].size == 48
      helper['profiles'].each_with_index do |record, index|
        profile = PROFILE_DEFS.fetch(index)
        fail!("helper #{profile[:id]} output fields differ") unless record.keys.sort == %w[effective_stride id library library_part part source type_name]
        fail!("helper #{profile[:id]} identity/nominal descriptor differs") unless record['id'] == profile[:id] && record['type_name'] == profile[:type_name]
        expected_stride = profile[:explicit_stride] ? profile[:stride] : profile[:dimension]
        fail!("helper #{profile[:id]} effective stride differs") unless record['effective_stride'] == expected_stride
        fail!("helper #{profile[:id]} part path differs") unless File.expand_path(record['part']) == File.expand_path(@part_paths.fetch(source_table(profile)))
        expected_library = File.join(@root, 'generated', profile[:id], 'all_1_1_0')
        fail!("helper #{profile[:id]} library destination differs") unless File.expand_path(record['library_part']) == expected_library
        assert_helper_side!(record.fetch('source'), profile, 'source')
        assert_helper_side!(record.fetch('library'), profile, 'library')
        fail!("helper #{profile[:id]} public full/middle/zero reads differ") unless record['source'] == record['library']
      end
      true
    end

    def assert_helper_side!(side, profile, label)
      expected_keys = %w[bucket_count dynamic_roster effective_stride full_rows mark_row_counts middle_rows object_dynamic_paths ordinary_string_profile row_count schema_declaration shared_version source_declaration typed_paths type_name zero_rows middle_window zero_window]
      fail!("helper #{profile[:id]} #{label} fields differ") unless side.keys.sort == expected_keys.sort
      fail!("helper #{profile[:id]} #{label} declaration differs") unless side['source_declaration'] == COLUMN_TYPE && side['schema_declaration'] == COLUMN_TYPE
      fail!("helper #{profile[:id]} #{label} physical grid differs") unless side['row_count'] == 4 && side['mark_row_counts'] == [2, 2]
      fail!("helper #{profile[:id]} #{label} persisted metadata differs") unless side['shared_version'] == profile[:shared_version] && side['bucket_count'] == 2 &&
        side['ordinary_string_profile'] == profile[:string_profile]
      expected_stride = profile[:explicit_stride] ? profile[:stride] : profile[:dimension]
      fail!("helper #{profile[:id]} #{label} QBit nominal/effective type differs") unless side['type_name'] == profile[:type_name] && side['effective_stride'] == expected_stride
      fail!("helper #{profile[:id]} #{label} middle/zero mark selectors differ") unless side['middle_window'] == {'first_mark' => 1, 'mark_count' => 1} &&
        side['zero_window'] == {'first_mark' => 2, 'mark_count' => 0}
      assert_shared_only_roster!(side, profile, label)
      assert_helper_rows!(side['full_rows'], profile, (1..4).to_a, label, 'full')
      assert_helper_rows!(side['middle_rows'], profile, [3, 4], label, 'middle')
      fail!("helper #{profile[:id]} #{label} zero window is nonempty") unless side['zero_rows'] == []
    end

    def assert_shared_only_roster!(side, profile, label)
      %w[object_dynamic_paths dynamic_roster typed_paths].each do |key|
        fail!("helper #{profile[:id]} #{label} #{key} must be empty for the shared-only route") unless side[key] == []
      end
      true
    end

    def assert_helper_rows!(rows, profile, pks, label, window)
      fail!("helper #{profile[:id]} #{label} #{window} cardinality differs") unless rows.size == pks.size
      expected = pks.map do |pk|
        raw = raw_rows(profile).fetch(pk - 1)
        {
          'pk' => pk, 'path_present' => !raw.nil?,
          'type_name' => raw ? profile[:type_name] : nil,
          'effective_stride' => raw ? (profile[:explicit_stride] ? profile[:stride] : profile[:dimension]) : nil,
          'raw_hex' => raw&.unpack1('H*'),
        }
      end
      fail!("helper #{profile[:id]} #{label} #{window} rows differ from independent raw fixtures") unless rows == expected
    end

    def attach_library_parts!(profiles)
      profiles.each do |profile|
        source = source_table(profile)
        library = library_table(profile)
        path = File.join(@root, 'generated', profile[:id], 'all_1_1_0')
        validate_generated_part!(path, profile)
        @part_paths[library] = File.realpath(path)
        @part_snapshots[library] = snapshot_part(path)
        target_data_path = validate_store_path!(@data_paths.fetch(library))
        @executor.send(:attach_part!, path, target_data_path)
      end
    end

    def assert_attached_group!(native, profiles)
      tables = profiles.flat_map { |profile| [source_table(profile), library_table(profile)] }
      expected_checks = profiles.flat_map do |profile|
        [[source_table(profile), profile[:id]], [library_table(profile), profile[:id]]]
      end.to_h { |table, id| [[table, id], ["all_1_1_0\t1\t"]] }
      fail!('attached CHECK result roster differs') unless native[:checks] == expected_checks
      assert_schema_roster!(native[:schemas], tables.sort, 'attached')
      fail!('attached part roster differs') unless native[:parts].keys.sort == tables.sort
      profiles.each do |profile|
        [source_table(profile), library_table(profile)].each do |table|
          part = native[:parts].fetch(table)
          fail!("#{table} attached part identity/grid differs") unless part[:name] == 'all_1_1_0' && part[:part_type] == 'Wide' && part[:rows] == '4' && part[:marks] == '3'
          path = @part_paths.fetch(table)
          assert_part_snapshot_matches!(path, @part_snapshots.fetch(table), "#{table} published source/generated")
          active_path = validate_attached_native_part!(part[:path], table, part[:name])
          active_snapshot = snapshot_part(active_path)
          assert_attached_part_snapshot_matches!(
            active_path, active_snapshot, @part_snapshots.fetch(table), table,
            allow_native_invalidation: table.start_with?('library_'),
          )
          @active_part_paths[table] = active_path
          @active_part_snapshots[table] = active_snapshot
        end
      end
      both_names = profiles.to_h { |profile| [profile[:id], [source_table(profile), library_table(profile)]] }
      assert_exact_readback!(native, profiles, both_names, initial: false)
      expected_zero = expected_zero_events(profiles, both_names)
      fail!('attached zero-window boundaries differ') unless native[:zero_events] == expected_zero
    end

    def run_clickhouse(label, sql)
      before = binary_sha
      fail!('pinned ClickHouse SHA mismatch before native invocation') unless before == BINARY_SHA256
      # Keep the exact SQL bytes durable before the process is started.
      write_new(File.join(@root, 'invocations', "#{label}.stdin.sql"), sql.b)
      argv = [@binary, 'local', '--path', File.join(@root, 'stores', 'native'), '--session_timezone=UTC',
              '--max_threads=1', "--max_memory_usage=#{MEMORY}", '--multiquery']
      invocation = @executor.send(:execute_record, label, argv, sql.b, 'clickhouse local', BINARY_SHA256, @binary)
      invocation[:record][:binary_sha_before] = before
      invocation[:record][:binary_sha_after] = binary_sha
      fail!('pinned ClickHouse SHA changed during native invocation') unless invocation[:record][:binary_sha_after] == BINARY_SHA256
      @invocations << invocation[:record]
      invocation
    end

    def run_helper(input_path, output_root)
      before = helper_sha
      argv = [@helper, input_path, output_root]
      invocation = @executor.send(:execute_record, 'crystal_qbit_parts_helper', argv, ''.b,
                                  'prebuilt Crystal helper', before, @helper)
      fail!('Crystal helper process failed; this is not a ClickHouse format rejection') unless successful?(invocation)
      fail!('Crystal helper wrote stderr') unless invocation[:stderr].empty?
      fail!('Crystal helper SHA changed during invocation') unless helper_sha == before
      lines = invocation[:stdout].lines.map(&:chomp).reject(&:empty?)
      fail!('Crystal helper must emit exactly one JSON record') unless lines.size == 1
      data = JSON.parse(lines.fetch(0))
      invocation[:record][:binary_sha_before] = before
      invocation[:record][:binary_sha_after] = helper_sha
      @invocations << invocation[:record]
      {data: data, record: invocation[:record]}
    end

    def assert_native_invocation!(invocation)
      fail!('ClickHouse invocation failed or timed out') unless successful?(invocation)
      fail!('ClickHouse stderr is not empty') unless invocation[:stderr].empty?
    end

    def assert_pin!(native)
      expected = ['__W200_PIN__', VERSION, BUILD]
      fail!("native runtime pin differs: #{native[:pin].inspect}") unless native[:pin] == expected
    end

    def successful?(invocation)
      invocation[:classification] == 'success' && invocation[:status]&.success? && invocation[:status]&.termsig.nil?
    end

    def validate_source_part!(path)
      fail!('native source part path is empty') if path.nil? || path.empty?
      full = File.expand_path(path.chomp(File::SEPARATOR))
      store = File.realpath(File.join(@root, 'stores', 'native'))
      fail!('source part escaped task-local native store') unless full.start_with?(store + File::SEPARATOR)
      fail!('source part is missing or symlinked') unless File.directory?(full) && !File.symlink?(full)
      validate_plain_tree!(full)
      File.realpath(full)
    end

    def validate_attached_native_part!(path, table, part_name)
      fail!("#{table} attached native part path is empty") unless path && !path.empty?
      fail!("#{table} attached native part name is invalid") unless part_name == 'all_1_1_0'
      store = File.realpath(File.join(@root, 'stores', 'native'))
      data_path = validate_store_path!(@data_paths.fetch(table).chomp(File::SEPARATOR))
      table_path = File.realpath(data_path)
      full = File.expand_path(path.chomp(File::SEPARATOR))
      fail!("#{table} native data path is not canonical") unless table_path == File.expand_path(data_path)
      fail!("#{table} native data path escaped task-local store") unless table_path.start_with?(store + File::SEPARATOR)
      fail!("#{table} attached native part path is not the canonical table child") unless
        full == File.join(table_path, part_name) && File.basename(full) == part_name
      ensure_plain_directory_chain!(full)
      fail!("#{table} attached native part is missing, symlinked, or noncanonical") unless
        File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full
      validate_plain_tree!(full)
      full
    rescue KeyError
      fail!("#{table} native table data path is absent")
    end

    def assert_part_snapshot_matches!(path, expected, label)
      fail!("#{label} file hashes differ from the published part snapshot") unless snapshot_part(path) == expected
      true
    end

    def assert_attached_part_snapshot_matches!(path, actual, published, table, allow_native_invalidation:)
      label = "#{table} attached native"
      fail!("#{label} has an invalid native-invalidation scope") unless allow_native_invalidation == table.start_with?('library_')
      added_names = actual.keys - published.keys
      if added_names.empty?
        fail!("#{label} file hashes differ from the published part snapshot") unless actual == published
        return true
      end

      invalidation = ATTACH_INVALIDATED_SYSTEM_COLUMNS
      fail!("#{label} is not a library ATTACH part") unless allow_native_invalidation
      fail!("#{label} published snapshot already contains the ATTACH metadata file") if published.key?(invalidation.fetch(:name))
      fail!("#{label} has unexpected added part entries: #{added_names.inspect}") unless added_names == [invalidation.fetch(:name)]
      expected_entry = {type: 'file', size: invalidation.fetch(:size), sha256: invalidation.fetch(:sha256)}
      fail!("#{label} ATTACH metadata size or SHA256 differs") unless actual.fetch(invalidation.fetch(:name)) == expected_entry
      content = File.binread(File.join(path, invalidation.fetch(:name)))
      fail!("#{label} ATTACH metadata bytes differ") unless content.bytesize == invalidation.fetch(:size) &&
        Digest::SHA256.hexdigest(content) == invalidation.fetch(:sha256) && content == invalidation.fetch(:content)
      retained = actual.reject { |name, _| name == invalidation.fetch(:name) }
      fail!("#{label} published file hashes differ") unless retained == published
      true
    end

    def validate_generated_part!(path, profile)
      expected = File.join(@root, 'generated', profile[:id], 'all_1_1_0')
      fail!("generated part path differs for #{profile[:id]}") unless File.expand_path(path) == expected
      fail!("generated part missing for #{profile[:id]}") unless File.directory?(expected) && !File.symlink?(expected)
      validate_plain_tree!(expected)
      File.realpath(expected)
    end

    def validate_store_path!(path)
      fail!('native table data path is absent') unless path && !path.empty?
      full = File.expand_path(path)
      store = File.join(@root, 'stores', 'native')
      fail!("native table data path escaped task-local store: #{path}") unless full.start_with?(store + File::SEPARATOR)
      ensure_plain_directory_chain!(full)
      full
    end

    def ensure_plain_directory_chain!(path)
      current = File::SEPARATOR
      File.expand_path(path).delete_prefix(File::SEPARATOR).split(File::SEPARATOR).each do |component|
        current = File.join(current, component)
        next unless File.exist?(current) || File.symlink?(current)
        fail!("symlink in task-local path: #{current}") if File.lstat(current).symlink?
        fail!("non-directory path component: #{current}") unless File.directory?(current)
      end
    end

    def snapshot_part(path)
      entries = {}
      Find.find(path) do |entry|
        next if entry == path
        stat = File.lstat(entry)
        fail!('symlink in part tree') if stat.symlink?
        relative = entry.delete_prefix(path + File::SEPARATOR)
        if stat.directory?
          entries[relative] = {type: 'directory'}
        elsif stat.file?
          entries[relative] = {type: 'file', size: stat.size, sha256: Digest::SHA256.file(entry).hexdigest}
        else
          fail!('non-regular part entry')
        end
      end
      entries
    end

    def validate_plain_tree!(path)
      Find.find(path) do |entry|
        stat = File.lstat(entry)
        fail!("symlink in evidence tree: #{entry}") if stat.symlink?
        fail!("non-regular evidence entry: #{entry}") unless stat.directory? || stat.file?
      end
      true
    end

    def write_summary(data)
      summary = {
        probe: 'W200 public complete-part QBit Object qualification', status: data[:status], fatal_error: data[:fatal_error],
        runtime: {path: @binary, expected_sha256: BINARY_SHA256, sha256_before: @binary_sha_before,
                  sha256_after: @binary_sha_after, expected_version: VERSION, expected_build: BUILD},
        helper_executable: {path: @helper, sha256_before: @helper_sha_before, sha256_after: @helper_sha_after},
        attached_native_exception: {
          filename: ATTACH_INVALIDATED_SYSTEM_COLUMNS.fetch(:name),
          exact_size: ATTACH_INVALIDATED_SYSTEM_COLUMNS.fetch(:size),
          exact_sha256: ATTACH_INVALIDATED_SYSTEM_COLUMNS.fetch(:sha256),
          scope: 'only as one added root-level file in a library ATTACH part absent from its published snapshot',
        },
        limits: {max_threads: 1, local_max_memory_usage_bytes: MEMORY,
                 required_outer_run_safe_memory_limit_bytes: OUTER_RUN_SAFE_LIMIT,
                 timeout_seconds: TIMEOUT, termination_grace_seconds: GRACE,
                 executor: 'JsonBinaryKernelW180Probe#execute'},
        profile_ids: PROFILE_IDS,
        settings: PROFILE_DEFS.map { |profile| {id: profile[:id], shared_version: profile[:shared_version], string_profile: profile[:string_profile], type_name: profile[:type_name]} },
        evidence_root: @root, invocations: @invocations,
      }.merge(data.reject { |key, _| %i[status fatal_error].include?(key) })
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      write_new(File.join(@root, 'summary.md'), [
        '# W200 public complete-part QBit Object qualification', '',
        "Status: `#{summary[:status]}`", '',
        'This finite harness pairs 48 stock-created parts with parts written through the public complete-part API. It checks exact whole-Object RowBinary bytes differentially, direct nullable typed QBit RowBinary against independent raw literals, dynamicType, and public full/middle/zero mark reads. It permits only the exact native `invalidated_system_columns.txt` file on library ATTACH copies when that file is absent from the published snapshot. It does not claim all ClickHouse Object layouts or all QBit profiles.', '',
        "Runtime: #{VERSION} / #{BUILD} / SHA256 `#{@binary_sha_before}`", '',
        "Evidence root: `#{@root}`", '',
      ].join("\n"))
    end

    def write_failure_summary
      summary = {
        status: 'runner_failure_or_observation_mismatch', fatal_error: @fatal_error,
        runtime: {path: @binary, expected_sha256: BINARY_SHA256, sha256_before: @binary_sha_before, sha256_after: @binary_sha_after},
        helper_executable: {path: @helper, sha256_before: @helper_sha_before, sha256_after: @helper_sha_after},
        evidence_root: @root, invocations: @invocations,
        part_snapshots_before: @part_snapshots, part_snapshots_after: @part_snapshots_after,
        attached_native_part_paths: @active_part_paths,
        attached_native_part_snapshots_before: @active_part_snapshots,
        attached_native_part_snapshots_after: @active_part_snapshots_after,
      }
      write_new(File.join(@root, 'summary-failure.json'), JSON.pretty_generate(summary) + "\n")
    end

    def write_new(path, bytes)
      fail!("refusing to overwrite evidence path #{path}") if File.exist?(path) || File.symlink?(path)
      File.open(path, 'wbx', 0o600) { |file| file.write(bytes) }
    end

    def fail!(message)
      raise RuntimeError, "W200 public QBit parts runner: #{message}"
    end
  end

  def self.self_test!
    Probe.self_test!
  end
end

if ARGV == ['--self-test']
  CheckObjectSharedQBitPartsW200.self_test!
  exit 0
end

unless ARGV.size == 2
  warn 'usage: ruby scripts/check_object_shared_qbit_parts_w200.rb CRYSTAL_HELPER /private/tmp/EMPTY_EVIDENCE_ROOT'
  exit 64
end

exit(CheckObjectSharedQBitPartsW200::Probe.new(ARGV[0], ARGV[1]).run ? 0 : 1)
