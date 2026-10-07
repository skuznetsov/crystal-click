#!/usr/bin/env ruby
# Root-run bounded stock-source qualification for QBit values in Object shared
# path Data. The driver never builds ClickHouse or Crystal; native processes
# are supervised by the existing W180/W185 executor.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require_relative 'check_array_json_parts_w185'

module CheckObjectSharedQBitW199
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

  INPUT_FORMAT = 'object_shared_qbit_w199_input_v1'.freeze
  HELPER_FORMAT = 'object_shared_qbit_w199_helper_v1'.freeze
  COLUMN_TYPE = 'JSON(max_dynamic_types=1, max_dynamic_paths=0)'.freeze
  COLUMN = 'j'.freeze
  PATH = 'q'.freeze
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
          qbit_type = shape[:explicit_stride] ?
            "QBit(#{carrier[:name]}, #{shape[:dimension]}, #{shape[:stride]})" :
            "QBit(#{carrier[:name]}, #{shape[:dimension]})"
          {
            id: "#{carrier[:name].downcase}_#{shape[:name]}_v#{shared_version}_s#{string_profile}".freeze,
            carrier: carrier[:name], carrier_index: carrier_index, width: carrier[:width],
            tag: carrier[:tag], dimension: shape[:dimension], stride: shape[:stride],
            explicit_stride: shape[:explicit_stride], shared_version: shared_version,
            string_profile: string_profile, type_name: qbit_type.freeze,
          }.freeze
        end
      end
    end
  end.freeze
  PROFILE_IDS = PROFILE_DEFS.map { |profile| profile[:id] }.freeze

  class Probe
    def initialize(helper, evidence_root)
      @binary = validate_executable(BINARY, 'ClickHouse')
      @helper = validate_executable(helper, 'Crystal helper')
      @root = validate_root(evidence_root)
      # W185 validates that the evidence root is still empty and gives us its
      # bounded subprocess/artifact writer. Do not recreate this after setup.
      @executor = W185::Probe.new(@binary, @helper, @root)
      @invocations = []
      @profiles = PROFILE_DEFS
      @parts = {}
      @part_snapshots = {}
      @source_rows = {}
      @fatal_error = nil
    end

    def run
      prepare_layout!
      @binary_sha_before = binary_sha
      fail!('pinned ClickHouse executable SHA mismatch before probe') unless @binary_sha_before == BINARY_SHA256
      @helper_sha_before = helper_sha
      fail!('helper SHA changed before probe') unless @helper_sha_before == helper_sha

      @profiles.each do |profile|
        write_new(input_path(profile), rowbinary(profile))
      end

      groups = @profiles.group_by { |profile| [profile[:shared_version], profile[:string_profile]] }
      groups.each_with_index do |((shared_version, string_profile), profiles), group_index|
        invocation = run_clickhouse("native_sources_v#{shared_version}_s#{string_profile}",
                                    initial_sql(profiles))
        assert_native_invocation!(invocation)
        native = parse_native(invocation[:stdout])
        assert_pin!(native)
        assert_source_group!(native, profiles)
        @source_rows.merge!(native[:direct_rows].to_h { |row| [[row[:table], row[:window], row[:pk]], row] })
      end

      helper_input = build_helper_input
      input_path = File.join(@root, 'inputs', 'helper-input.json')
      write_new(input_path, JSON.pretty_generate(helper_input) + "\n")
      helper = run_helper(input_path)
      assert_helper_output!(helper, helper_input)

      @part_snapshots_after = @parts.to_h { |table, path| [table, snapshot_part(path)] }
      fail!('native source part bytes changed during helper inspection') unless @part_snapshots_after == @part_snapshots

      @binary_sha_after = binary_sha
      @helper_sha_after = helper_sha
      fail!('ClickHouse executable SHA changed during probe') unless @binary_sha_after == BINARY_SHA256
      fail!('Crystal helper SHA changed during probe') unless @helper_sha_after == @helper_sha_before
      summary = {
        status: 'stock_qbit_shared_path_observed',
        scope: 'finite stock-source Object shared-path Data decode/reencode witness; not public full-part writer qualification',
        runtime: {path: @binary, expected_sha256: BINARY_SHA256, sha256_before: @binary_sha_before,
                  sha256_after: @binary_sha_after, expected_version: VERSION, expected_build: BUILD},
        helper_executable: {path: @helper, sha256_before: @helper_sha_before, sha256_after: @helper_sha_after},
        evidence_root: @root, profile_count: @profiles.size, profile_ids: PROFILE_IDS,
        settings: @profiles.map { |p| {id: p[:id], shared_version: p[:shared_version], string_profile: p[:string_profile], type_name: p[:type_name]} },
        limits: {max_threads: 1, local_max_memory_usage_bytes: MEMORY,
                 required_outer_run_safe_memory_limit_bytes: OUTER_RUN_SAFE_LIMIT,
                 timeout_seconds: TIMEOUT, termination_grace_seconds: GRACE,
                 executor: 'JsonBinaryKernelW180Probe#execute'},
        parts_before_helper: @part_snapshots, parts_after_helper: @part_snapshots_after,
        helper_report: helper[:data],
        helper_input_sha256: Digest::SHA256.file(input_path).hexdigest,
        invocations: @invocations,
      }
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      write_new(File.join(@root, 'summary.md'), [
        '# W199 stock QBit shared-path Data qualification', '',
        'Status: `stock_qbit_shared_path_observed`', '',
        'The pinned stock runtime created the source parts. The Crystal helper independently opened their advanced shared-path lanes, checked the persisted QBit roster and literal raw rows, and verified byte/event round trips. This is not a public full-part QBit writer claim.', '',
        "Profiles: #{PROFILE_IDS.size}; runtime #{VERSION}/#{BUILD}; SHA256 `#{@binary_sha_before}`", '',
        "Evidence root: `#{@root}`", '',
      ].join("\n"))
      puts "W199 stock QBit shared-path profiles=#{PROFILE_IDS.size}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      @binary_sha_after = binary_sha rescue nil
      @helper_sha_after = helper_sha rescue nil
      write_failure_summary rescue nil
      warn "W199 runner failure (not a format rejection): #{@fatal_error}"
      false
    end

    def self.self_test!
      probe = allocate
      raise 'fixed 48-profile roster changed' unless PROFILE_DEFS.size == 48 && PROFILE_IDS.uniq.size == 48
      raise 'profile matrix order changed' unless PROFILE_DEFS.first[:id] == 'int8_dim3_v2_s0' && PROFILE_DEFS.last[:id] == 'float64_stride16_8_v3_s1'
      first = PROFILE_DEFS.first
      raw = probe.send(:literal_raw, first, 0)
      raise 'Int8 independent literal prefix changed' unless raw.byteslice(0, 3).bytes == [0xff, 0x00, 0x80]
      raise 'QBit body envelope changed' unless probe.send(:payload_hex, first, raw) == '03FF0080'
      row = probe.send(:rowbinary, first)
      # Three present rows each carry UInt64 PK + one-field count + path
      # string + QBit descriptor + dimension/raw payload; row 2 is pathless.
      raise 'RowBinary row count/length changed' unless row.bytesize == 3 * 18 + 9
      sample = [
        "__W199_PIN__\t#{VERSION}\t#{BUILD}",
        "__W199_CHECK_BEGIN__\tsource_#{first[:id]}\t#{first[:id]}",
        "all_1_1_0\t1\t",
        "__W199_CHECK_END__\tsource_#{first[:id]}\t#{first[:id]}",
        "__W199_PART__\tsource_#{first[:id]}\tall_1_1_0\t/tmp/p\tWide\t4\t3",
        "__W199_ZERO_BEGIN__\tsource_#{first[:id]}\tzero\tdirect",
        "__W199_DIRECT_ZERO__\tsource_#{first[:id]}\t\t\t",
        "__W199_ZERO_END__\tsource_#{first[:id]}\tzero\tdirect",
      ].join("\n")
      parsed = probe.send(:parse_native, sample)
      raise 'real TSV pin marker parsing changed' unless parsed[:pin] == ['__W199_PIN__', VERSION, BUILD]
      raise 'zero-window boundaries changed' unless parsed[:zero_events].size == 2
      raise 'empty direct-window row parsing changed' unless parsed[:direct_rows] == [
        {table: "source_#{first[:id]}", pk: '', type: '', hex: '', window: 'zero'},
      ]
      part_line = "__W199_PART__\tsource_#{first[:id]}\tall_1_1_0\t/tmp/p\tWide\t4\t3"
      reject = lambda do |label, input|
        begin
          probe.send(:parse_native, input)
        rescue StandardError
          next
        end
        raise "#{label} was accepted"
      end
      reject.call('duplicate part record', sample + "\n" + part_line)
      reject.call('unclosed CHECK block', "__W199_PIN__\t#{VERSION}\t#{BUILD}\n__W199_CHECK_BEGIN__\tx\ty")
      reject.call('unexpected stdout outside CHECK', sample + "\nunexpected output")
      table = "source_#{first[:id]}"
      raws = probe.send(:raw_rows, first)
      expected_direct = %w[FULL MIDDLE ZERO].flat_map do |window|
        pks = {'FULL' => [1, 2, 3, 4], 'MIDDLE' => [2, 3], 'ZERO' => []}.fetch(window)
        pks.map do |pk|
          value = raws.fetch(pk - 1)
          {table: table, pk: pk.to_s, type: value ? first[:type_name] : 'None',
           hex: value ? probe.send(:payload_hex, first, value) : 'NULL', window: window.downcase}
        end
      end
      valid_group = {
        parts: {table => {name: 'all_1_1_0', path: '/tmp/not-read-before-roster-check', part_type: 'Wide', rows: '4', marks: '3'}},
        schemas: {[table, 'pk'] => 'UInt64', [table, 'j'] => COLUMN_TYPE},
        checks: {[table, first[:id]] => ["all_1_1_0\t1\t"]},
        direct_rows: expected_direct + [{table: 'unknown', pk: '1', type: 'None', hex: 'NULL', window: 'full'}],
        zero_events: [['__W199_ZERO_BEGIN__', table, 'zero', 'direct'], ['__W199_ZERO_END__', table, 'zero', 'direct']],
      }
      begin
        probe.send(:assert_source_group!, valid_group, [first])
      rescue StandardError
        # Expected: exact global table/window/pk roster rejects the extra row.
      else
        raise 'extra direct row for unknown table was accepted'
      end
      puts 'W199 Ruby self-test passed: 48-profile matrix, literal RowBinary, TSV boundaries and fail-closed parsing.'
      true
    end

    private

    def prepare_layout!
      %w[invocations inputs stores].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      Dir.mkdir(File.join(@root, 'stores', 'native'), 0o700)
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

    def check_sql(table, profile)
      [
        "SELECT '__W199_CHECK_BEGIN__', '#{table}', '#{profile[:id]}' FORMAT TSVRaw;",
        "CHECK TABLE default.#{table} FORMAT TSV;",
        "SELECT '__W199_CHECK_END__', '#{table}', '#{profile[:id]}' FORMAT TSVRaw;",
      ].join("\n")
    end

    def pin_sql
      "SELECT '__W199_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;"
    end

    def source_table(profile)
      "source_#{profile[:id]}"
    end

    def input_path(profile)
      File.join(@root, 'inputs', "#{profile[:id]}.rowbinary")
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
      # Independent fixed bit-pattern prefixes: signed zero and distinct NaN
      # payloads for floating carriers; no decimal conversion is involved.
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
      output = [profile[:explicit_stride] ? 0x37 : 0x36, profile[:tag]].pack('C*').b
      output << varuint(profile[:dimension])
      output << varuint(profile[:stride]) if profile[:explicit_stride]
      output
    end

    def payload_hex(profile, raw)
      (varuint(profile[:dimension]) + raw).unpack1('H*').upcase
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

    def build_helper_input
      capture_root = File.realpath(File.join(@root, 'stores', 'native'))
      parts = @profiles.map do |profile|
        part_path = @parts.fetch(source_table(profile))
        {
          'id' => profile[:id], 'part' => part_path, 'carrier' => profile[:carrier],
          'dimension' => profile[:dimension], 'stride' => profile[:stride],
          'explicit_stride' => profile[:explicit_stride], 'shared_version' => profile[:shared_version],
          'string_profile' => profile[:string_profile], 'bucket_count' => 2,
          'type_name' => profile[:type_name],
          'expected_rows' => raw_rows(profile).map { |raw| raw&.unpack1('H*') },
        }
      end
      {'format' => INPUT_FORMAT, 'capture_root' => capture_root, 'profiles' => parts}
    end

    def assert_helper_output!(helper, input)
      output = helper.fetch(:data)
      fail!('helper output top-level fields/format differ') unless output.keys.sort == %w[capture_root format profile_count profiles] && output['format'] == HELPER_FORMAT
      fail!('helper profile count differs') unless output['profile_count'] == 48 && output['profiles'].size == 48
      fail!('helper capture root differs') unless File.expand_path(output['capture_root']) == File.expand_path(input.fetch('capture_root'))
      output['profiles'].each_with_index do |record, index|
        profile = PROFILE_DEFS.fetch(index)
        expected_raw = raw_rows(profile)
        fail!("helper profile #{profile[:id]} identity differs") unless record['id'] == profile[:id]
        fail!("helper profile #{profile[:id]} persisted type differs") unless record['type_name'] == profile[:type_name]
        fail!("helper profile #{profile[:id]} declaration differs") unless record['source_declaration'] == COLUMN_TYPE
        fail!("helper profile #{profile[:id]} physical dimensions differ") unless record['row_count'] == 4 && record['mark_row_counts'] == [2, 2]
        fail!("helper profile #{profile[:id]} object metadata differs") unless record['shared_version'] == profile[:shared_version] && record['string_profile'] == profile[:string_profile] && record['bucket_count'] == 2
        values = record.fetch('row_values')
        fail!("helper profile #{profile[:id]} row witness count differs") unless values.size == 4
        values.each_with_index do |row, row_index|
          fail!("helper profile #{profile[:id]} row number differs") unless row['row'] == row_index + 1
          if raw = expected_raw[row_index]
            fail!("helper profile #{profile[:id]} raw literal differs at row #{row_index + 1}") unless row['status'] == 'qbit' && row['type_name'] == profile[:type_name] && row['raw_hex'] == raw.unpack1('H*')
          else
            fail!("helper profile #{profile[:id]} absent row has unexpected payload") unless %w[null pathless].include?(row['status']) && row['type_name'].nil? && row['raw_hex'].nil?
          end
        end
        schedules = record.fetch('chunk_schedule')
        fail!("helper profile #{profile[:id]} chunk schedule is empty") if schedules.empty?
        expected_rows = profile[:shared_version] == 2 ? [2, 2] : [1, 1, 1, 1]
        schedules.each do |chunk|
          fail!("helper profile #{profile[:id]} schedule fields differ") unless chunk.keys.sort == %w[bucket_index chunk_index parent_index parent_row_count path_names row_count row_start]
          fail!("helper profile #{profile[:id]} schedule parent rows differ") unless chunk['parent_row_count'] == 2
          fail!("helper profile #{profile[:id]} schedule chunk rows differ") unless expected_rows.include?(chunk['row_count'])
          fail!("helper profile #{profile[:id]} unexpected path name") unless chunk['path_names'].all? { |name| name == PATH }
        end
        paths = record.fetch('path_records')
        fail!("helper profile #{profile[:id]} has no decoded shared QBit path") if paths.empty?
        paths.each do |path|
          fail!("helper profile #{profile[:id]} path record is not qbit") unless path['path'] == PATH && path['dynamic_types'] == [profile[:type_name]]
          fail!("helper profile #{profile[:id]} path events/data are malformed") unless path['events'].is_a?(Array) && !path['events'].empty? && path['data_hex'].match?(/\A(?:[0-9a-f]{2})+\z/)
        end
      end
      true
    end

    def initial_sql(profiles)
      statements = [pin_sql]
      profiles.each do |profile|
        table = source_table(profile)
        statements << "CREATE TABLE default.#{table} (pk UInt64, j #{COLUMN_TYPE}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings(profile)};"
        input = input_path(profile).gsub("'", "\\'")
        statements << "INSERT INTO default.#{table} SELECT * FROM file('#{input}', 'RowBinary', 'pk UInt64, j #{COLUMN_TYPE}') SETTINGS input_format_binary_read_json_as_string=0, flatten_nested=0, allow_suspicious_low_cardinality_types=1;"
        statements << check_sql(table, profile)
      end
      tables = profiles.map { |profile| source_table(profile) }
      quoted = tables.map { |table| "'#{table}'" }.join(',')
      statements << "SELECT '__W199_SCHEMA__', table, name, type FROM system.columns WHERE database='default' AND table IN (#{quoted}) ORDER BY table, position FORMAT TSVRaw;"
      statements << "SELECT '__W199_PART__', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table IN (#{quoted}) AND active ORDER BY table,name FORMAT TSVRaw;"
      profiles.each do |profile|
        table = source_table(profile)
        type = profile[:type_name].gsub("'", "''")
        expr = "dynamicElement(j.q, '#{type}')"
        {
          'FULL' => '', 'MIDDLE' => ' WHERE pk BETWEEN 2 AND 3', 'ZERO' => ' WHERE pk > 4',
        }.each do |window, predicate|
          if window == 'ZERO'
            statements << "SELECT '__W199_ZERO_BEGIN__', '#{table}', 'zero', 'direct' FORMAT TSVRaw;"
          end
          rowbinary = "if(isNull(#{expr}), 'NULL', hex(formatRow('RowBinary', assumeNotNull(#{expr}))))"
          statements << "SELECT '__W199_DIRECT_#{window}__', '#{table}', toString(pk), dynamicType(j.q), #{rowbinary} FROM default.#{table}#{predicate} ORDER BY pk FORMAT TSVRaw;"
          if window == 'ZERO'
            statements << "SELECT '__W199_ZERO_END__', '#{table}', 'zero', 'direct' FORMAT TSVRaw;"
          end
        end
      end
      statements.join("\n") + "\n"
    end

    def parse_native(stdout)
      lines = stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
      fail!('native stdout is not valid UTF-8') unless lines.all?(&:valid_encoding?)
      rows = ->(tag) do
        lines.each_with_object([]) do |line, records|
          next unless line.start_with?("#{tag}\t")
          records << line.split("\t", -1)
        end
      end
      checks = {}
      active = nil
      lines.each do |line|
        if line.start_with?('__W199_CHECK_BEGIN__')
          fail!('CHECK begin marker is malformed') unless line.start_with?("__W199_CHECK_BEGIN__\t")
          fields = line.split("\t", -1)
          fail!('CHECK begin marker width or nesting is invalid') unless fields.size == 3 && !active
          active = [fields[1], fields[2]]
          fail!('duplicate CHECK marker') if checks.key?(active)
          checks[active] = []
        elsif line.start_with?('__W199_CHECK_END__')
          fail!('CHECK end marker is malformed') unless line.start_with?("__W199_CHECK_END__\t")
          fields = line.split("\t", -1)
          fail!('CHECK end marker is malformed or unmatched') unless fields.size == 3 && active == fields.drop(1)
          active = nil
        elsif active
          checks[active] << line
        else
          known = [
            "__W199_PIN__\t", "__W199_PART__\t", "__W199_SCHEMA__\t",
            "__W199_DIRECT_FULL__\t", "__W199_DIRECT_MIDDLE__\t", "__W199_DIRECT_ZERO__\t",
            "__W199_ZERO_BEGIN__\t", "__W199_ZERO_END__\t",
          ].any? { |prefix| line.start_with?(prefix) }
          fail!("unexpected native stdout outside CHECK block: #{line.inspect}") unless known
        end
      end
      fail!('unclosed CHECK block') if active
      pin_rows = rows.call('__W199_PIN__')
      fail!('runtime pin marker must occur exactly once with three fields') unless pin_rows.size == 1 && pin_rows.first.size == 3
      part_records = {}
      rows.call('__W199_PART__').each do |fields|
        fail!('part record has wrong field width') unless fields.size == 7
        fail!('duplicate active part record') if part_records.key?(fields[1])
        part_records[fields[1]] = {name: fields[2], path: fields[3], part_type: fields[4], rows: fields[5], marks: fields[6]}
      end
      schemas = {}
      rows.call('__W199_SCHEMA__').each do |fields|
        fail!('schema record has wrong field width') unless fields.size == 4
        key = [fields[1], fields[2]]
        fail!('duplicate schema record') if schemas.key?(key)
        schemas[key] = fields[3]
      end
      direct_rows = []
      %w[FULL MIDDLE ZERO].each do |window|
        rows.call("__W199_DIRECT_#{window}__").each do |fields|
          fail!('direct row has wrong field width') unless fields.size == 5
          direct_rows << {table: fields[1], pk: fields[2], type: fields[3], hex: fields[4].upcase, window: window.downcase}
        end
      end
      zero_events = lines.each_with_object([]) do |line, events|
        next unless line.start_with?("__W199_ZERO_BEGIN__\t") || line.start_with?("__W199_ZERO_END__\t")
        fields = line.split("\t", -1)
        fail!('zero boundary marker has wrong field width') unless fields.size == 4
        events << fields
      end
      {pin: pin_rows.first, checks: checks, parts: part_records, schemas: schemas,
       direct_rows: direct_rows, zero_events: zero_events}
    end

    def assert_source_group!(native, profiles)
      expected_tables = profiles.map { |profile| source_table(profile) }.sort
      fail!('source part roster differs from exact group') unless native[:parts].keys.sort == expected_tables
      expected_schema = expected_tables.flat_map { |table| [[[table, 'pk'], 'UInt64'], [[table, 'j'], COLUMN_TYPE]] }.to_h
      fail!('source table schema differs from exact typed JSON declaration') unless native[:schemas] == expected_schema
      expected_checks = expected_tables.to_h do |table|
        profile = profiles.find { |candidate| source_table(candidate) == table }
        [[table, profile[:id]], ["all_1_1_0\t1\t"]]
      end
      fail!('CHECK TABLE records differ') unless native[:checks] == expected_checks
      expected_direct = %w[FULL MIDDLE ZERO].flat_map do |window|
        profiles.flat_map do |profile|
          table = source_table(profile)
          raws = raw_rows(profile)
          pks = {'FULL' => [1, 2, 3, 4], 'MIDDLE' => [2, 3], 'ZERO' => []}.fetch(window)
          pks.map do |pk|
            raw = raws.fetch(pk - 1)
            {table: table, pk: pk.to_s,
             type: raw ? profile[:type_name] : 'None',
             hex: raw ? payload_hex(profile, raw) : 'NULL', window: window.downcase}
          end
        end
      end
      fail!('global direct-path row roster/order differs') unless native[:direct_rows] == expected_direct
      expected_zero_events = profiles.flat_map do |profile|
        table = source_table(profile)
        [['__W199_ZERO_BEGIN__', table, 'zero', 'direct'],
         ['__W199_ZERO_END__', table, 'zero', 'direct']]
      end
      fail!('global zero-window marker roster/order differs') unless native[:zero_events] == expected_zero_events
      profiles.each do |profile|
        table = source_table(profile)
        part = native[:parts].fetch(table)
        fail!("#{table} is not a fresh 4-row Wide part") unless part[:name] == 'all_1_1_0' && part[:part_type] == 'Wide' && part[:rows] == '4' && part[:marks] == '3'
        part_path = validate_source_part!(part[:path])
        @parts[table] = part_path
        @part_snapshots[table] = snapshot_part(part_path)
        assert_direct_rows!(native, profile)
      end
    end

    def assert_direct_rows!(native, profile)
      table = source_table(profile)
      raws = raw_rows(profile)
      type_rows = raws.map { |raw| raw.nil? ? 'None' : profile[:type_name] }
      windows = {'full' => [1, 2, 3, 4], 'middle' => [2, 3], 'zero' => []}
      windows.each do |window, pks|
        expected = pks.map do |pk|
          raw = raws.fetch(pk - 1)
          [table, pk.to_s, type_rows.fetch(pk - 1), raw ? payload_hex(profile, raw) : 'NULL', window]
        end
        actual = native[:direct_rows].select { |row| row[:table] == table && row[:window] == window }.map do |row|
          [row[:table], row[:pk], row[:type], row[:hex], row[:window]]
        end
        fail!("#{table} #{window} direct QBit path rows differ from independent literals") unless actual == expected
      end
      expected_zero = [['__W199_ZERO_BEGIN__', table, 'zero', 'direct'], ['__W199_ZERO_END__', table, 'zero', 'direct']]
      actual_zero = native[:zero_events].select { |row| row[1] == table }
      fail!("#{table} zero-window marker roster differs") unless actual_zero == expected_zero
    end

    def run_clickhouse(label, sql)
      before = binary_sha
      fail!('pinned ClickHouse SHA mismatch before native invocation') unless before == BINARY_SHA256
      # execute_record authenticates input bytes but does not persist the SQL;
      # keep the referenced stdin artifact before starting the child process.
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

    def run_helper(input_path)
      before = helper_sha
      argv = [@helper, input_path]
      result = @executor.send(:execute_record, 'crystal_qbit_inspector', argv, ''.b,
                              'prebuilt Crystal helper', before, @helper)
      fail!('Crystal helper process failed; this is not a ClickHouse rejection') unless successful?(result)
      fail!('Crystal helper wrote stderr') unless result[:stderr].empty?
      fail!('Crystal helper SHA changed during invocation') unless helper_sha == before
      lines = result[:stdout].lines.map(&:chomp).reject(&:empty?)
      fail!('Crystal helper must emit exactly one JSON record') unless lines.size == 1
      data = JSON.parse(lines.fetch(0))
      record = result[:record]
      record[:binary_sha_before] = before
      record[:binary_sha_after] = helper_sha
      @invocations << record
      {data: data, record: record}
    end

    def assert_native_invocation!(invocation)
      fail!('ClickHouse invocation failed or timed out') unless successful?(invocation)
      fail!('ClickHouse stderr is not empty') unless invocation[:stderr].empty?
    end

    def assert_pin!(native)
      expected = ["__W199_PIN__", VERSION, BUILD]
      fail!("native runtime pin differs: #{native[:pin].inspect}") unless native[:pin] == expected
    end

    def successful?(invocation)
      invocation[:classification] == 'success' && invocation[:status]&.success? && invocation[:status]&.termsig.nil?
    end

    def validate_source_part!(path)
      fail!('native source part path is empty') if path.nil? || path.empty?
      full = File.expand_path(path.chomp(File::SEPARATOR))
      store = File.realpath(File.join(@root, 'stores', 'native'))
      fail!('source part escaped the task-local store') unless full.start_with?(store + File::SEPARATOR)
      fail!('source part is missing or symlinked') unless File.directory?(full) && !File.symlink?(full)
      File.realpath(full)
    end

    def snapshot_part(path)
      entries = {}
      Find.find(path) do |entry|
        next if entry == path
        stat = File.lstat(entry)
        fail!('symlink in source part') if stat.symlink?
        relative = entry.delete_prefix(path + File::SEPARATOR)
        if stat.directory?
          entries[relative] = {type: 'directory'}
        elsif stat.file?
          entries[relative] = {type: 'file', size: stat.size, sha256: Digest::SHA256.file(entry).hexdigest}
        else
          fail!('non-regular source part entry')
        end
      end
      entries
    end

    def validate_executable(path, label)
      fail!("#{label} path missing") unless path && !path.empty?
      full = File.expand_path(path)
      fail!("#{label} is not a plain executable") unless File.file?(full) && File.executable?(full) && !File.symlink?(full)
      full
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

    def binary_sha
      Digest::SHA256.file(@binary).hexdigest
    end

    def helper_sha
      Digest::SHA256.file(@helper).hexdigest
    end

    def write_failure_summary
      summary = {
        status: 'runner_failure_or_observation_mismatch', fatal_error: @fatal_error,
        runtime: {path: @binary, expected_sha256: BINARY_SHA256,
                  sha256_before: @binary_sha_before, sha256_after: @binary_sha_after},
        helper_executable: {path: @helper, sha256_before: @helper_sha_before, sha256_after: @helper_sha_after},
        evidence_root: @root, invocations: @invocations,
        source_parts_before_helper: @part_snapshots, source_parts_after_helper: @part_snapshots_after,
      }
      write_new(File.join(@root, 'summary-failure.json'), JSON.pretty_generate(summary) + "\n")
    end

    def write_new(path, bytes)
      fail!("refusing to overwrite evidence path #{path}") if File.exist?(path) || File.symlink?(path)
      File.open(path, 'wbx', 0o600) { |file| file.write(bytes) }
    end

    def fail!(message)
      raise RuntimeError, "W199 QBit stock runner: #{message}"
    end
  end

  def self.self_test!
    Probe.self_test!
  end
end

if ARGV == ['--self-test']
  CheckObjectSharedQBitW199.self_test!
  exit 0
end

unless ARGV.size == 2
  warn 'usage: ruby scripts/check_object_shared_qbit_w199.rb CRYSTAL_HELPER /private/tmp/EMPTY_EVIDENCE_ROOT'
  exit 64
end

probe = CheckObjectSharedQBitW199::Probe.new(ARGV[0], ARGV[1])
exit(probe.run ? 0 : 1)
