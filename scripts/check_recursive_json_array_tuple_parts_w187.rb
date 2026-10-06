#!/usr/bin/env ruby
# Stock baseline and paired stock/library discriminator for named
# Tuple(JSON, JSON, UInt64) sites under one or two Array edges. Native
# execution remains bounded by the W180/W185 runner; this script never builds
# either executable.

require 'digest'
require 'json'
require 'optparse'
require_relative 'check_array_json_parts_w185'

module CheckRecursiveJSONArrayTuplePartsW187
  extend self

  Binary = CheckArrayJSONPartsW185::BINARY.freeze
  BinarySHA256 = CheckArrayJSONPartsW185::BINARY_SHA256.freeze
  Version = CheckArrayJSONPartsW185::VERSION.freeze
  Build = CheckArrayJSONPartsW185::BUILD.freeze
  Memory = CheckArrayJSONPartsW185::MEMORY
  Timeout = CheckArrayJSONPartsW185::TIMEOUT
  Grace = CheckArrayJSONPartsW185::GRACE
  OuterRunSafeLimit = CheckArrayJSONPartsW185::OUTER_RUN_SAFE_LIMIT
  # Preserve W187's BASIC default, while letting this runner explicitly select
  # the pinned stock COMPACT profile without changing W185/W186 settings.
  Settings = {
    'basic' => [CheckArrayJSONPartsW185::SETTINGS,
                'use_compact_variant_discriminators_serialization=0'].join(', ').freeze,
    'compact' => [CheckArrayJSONPartsW185::SETTINGS,
                  'use_compact_variant_discriminators_serialization=1'].join(', ').freeze,
  }.freeze

  JsonType = 'JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8)'.freeze
  TupleType = "Tuple(l #{JsonType}, r #{JsonType}, n UInt64)".freeze
  OneType = "Array(#{TupleType})".freeze
  TwoType = "Array(Array(#{TupleType}))".freeze
  Key = 'pk'.freeze
  Column = 'a'.freeze

  def element(index)
    left = {'t' => index, 'a_left' => index + 10}
    right = {'t' => index + 20, 'b_right' => "right-#{index}"}
    if index == 1
      left['z_shared'] = 'left-shared'
      right['z_shared'] = 'right-shared'
    end
    {'l' => left, 'r' => right, 'n' => index * 100}
  end

  ElementLiterals = (1..4).to_h { |index| [index, element(index)] }.freeze
  OneValues = [[], [], [], [ElementLiterals.fetch(1)],
               [ElementLiterals.fetch(2), ElementLiterals.fetch(3)],
               [ElementLiterals.fetch(4)], [], []].freeze
  TwoValues = [[], [], [[]], [[ElementLiterals.fetch(1)]],
               [[], [ElementLiterals.fetch(2), ElementLiterals.fetch(3)]],
               [[ElementLiterals.fetch(4)]], [], []].freeze

  Profiles = {
    'one' => {source: 'source_one', target: 'library_one', type: OneType,
              array_depth: 1, values: OneValues},
    'two' => {source: 'source_two', target: 'library_two', type: TwoType,
              array_depth: 2, values: TwoValues},
  }.freeze

  CompactJsonType = 'JSON(max_dynamic_types=2, max_dynamic_paths=1, t UInt8)'.freeze
  CompactTupleType = "Tuple(l #{CompactJsonType}, r #{CompactJsonType}, n UInt64)".freeze
  CompactOneType = "Array(#{CompactTupleType})".freeze
  CompactTwoType = "Array(Array(#{CompactTupleType}))".freeze
  CompactElements = (1..4).to_h do |index|
    left = {'t' => index}
    right = {'t' => index + 20}
    if index <= 2
      left['a_left'] = index + 10
      right['b_right'] = "right-#{index}"
    elsif index == 3
      left['a_left'] = nil
      right['b_right'] = nil
    else
      left['a_left'] = "left-#{index}"
      right['b_right'] = index + 20
    end
    if index == 1
      left['z_shared'] = 'left-shared'
      right['z_shared'] = 'right-shared'
    end
    [index, {'l' => left, 'r' => right, 'n' => index * 100}]
  end.freeze
  # INSERT literals retain NULL so the stock COMPACT lane must encode a real
  # NULL discriminator. ClickHouse's JSON object projection omits untyped NULL
  # paths on read, so keep the independently authored read oracle separate.
  CompactReadElements = {
    1 => {'l' => {'t' => 1, 'a_left' => 11, 'z_shared' => 'left-shared'},
          'r' => {'t' => 21, 'b_right' => 'right-1', 'z_shared' => 'right-shared'}, 'n' => 100},
    2 => {'l' => {'t' => 2, 'a_left' => 12}, 'r' => {'t' => 22, 'b_right' => 'right-2'}, 'n' => 200},
    3 => {'l' => {'t' => 3}, 'r' => {'t' => 23}, 'n' => 300},
    4 => {'l' => {'t' => 4, 'a_left' => 'left-4'}, 'r' => {'t' => 24, 'b_right' => 24}, 'n' => 400},
  }.freeze
  CompactReadOneValues = [[], [], [], [CompactReadElements.fetch(1)],
                          [CompactReadElements.fetch(2), CompactReadElements.fetch(3)],
                          [CompactReadElements.fetch(4)], [], []].freeze
  CompactReadTwoValues = [[], [], [[]], [[CompactReadElements.fetch(1)]],
                          [[], [CompactReadElements.fetch(2), CompactReadElements.fetch(3)]],
                          [[CompactReadElements.fetch(4)]], [], []].freeze
  CompactOneValues = [[], [], [], [CompactElements.fetch(1)],
                      [CompactElements.fetch(2), CompactElements.fetch(3)],
                      [CompactElements.fetch(4)], [], []].freeze
  CompactTwoValues = [[], [], [[]], [[CompactElements.fetch(1)]],
                      [[], [CompactElements.fetch(2), CompactElements.fetch(3)]],
                      [[CompactElements.fetch(4)]], [], []].freeze
  CompactProfiles = {
    'one' => {source: 'source_one', target: 'library_one', type: CompactOneType,
              json_type: CompactJsonType, tuple_type: CompactTupleType,
              array_depth: 1, values: CompactOneValues, read_values: CompactReadOneValues,
              dynamic_mode: 'compact'},
    'two' => {source: 'source_two', target: 'library_two', type: CompactTwoType,
              json_type: CompactJsonType, tuple_type: CompactTupleType,
              array_depth: 2, values: CompactTwoValues, read_values: CompactReadTwoValues,
              dynamic_mode: 'compact'},
  }.freeze

  class Probe
    def initialize(binary, crystal_probe, evidence_root, dynamic_mode: 'basic', stock_only: false)
      @base = CheckArrayJSONPartsW185::Probe.new(binary, crystal_probe, evidence_root)
      @root = File.expand_path(evidence_root)
      @binary = File.expand_path(binary)
      @crystal_probe = File.expand_path(crystal_probe)
      fail!('dynamic mode must be basic or compact') unless %w[basic compact].include?(dynamic_mode)
      fail!('stock-only baseline is meaningful only for compact mode') if stock_only && dynamic_mode != 'compact'
      @dynamic_mode = dynamic_mode
      @stock_only = stock_only
      @invocations = []
      @fatal_error = nil
    end

    def profiles
      @dynamic_mode == 'compact' ? CompactProfiles : Profiles
    end

    def run
      %w[invocations stores parts].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      Dir.mkdir(File.join(@root, 'stores', 'native'), 0o700)
      unless @stock_only
        Dir.mkdir(File.join(@root, 'parts', 'library_one'), 0o700)
        Dir.mkdir(File.join(@root, 'parts', 'library_two'), 0o700)
      end
      @sha_before = binary_sha
      fail!('pinned ClickHouse executable SHA-256 mismatch before probe') unless @sha_before == BinarySHA256

      initial = @base.send(:run_clickhouse, 'native_sources', initial_sql)
      @base.send(:assert_pin!, initial)
      @base.send(:assert_native_invocation!, initial)
      source = @base.send(:parse_native, initial[:stdout])
      source_parts = assert_initial_native!(source)
      stock_inventories = {}
      profiles.each do |label, profile|
        part = source_parts.fetch(label)
        inventory = @base.send(:inspect_part, "stock_#{label}", part[:path], part)
        assert_source_roster!(inventory, profile)
        inventory[:compact_discriminator_payloads] = inspect_compact_discriminators!(inventory, profile) if @dynamic_mode == 'compact'
        stock_inventories[label] = inventory
      end

      if @stock_only
        crystal = run_helper(source_parts, {}, stock_only: true)
        assert_stock_only_helper!(crystal)
        @sha_after = binary_sha
        fail!('pinned ClickHouse executable SHA-256 changed during probe') unless @sha_after == BinarySHA256
        write_summary(
          status: 'stock_compact_array_tuple_json_observed_and_reader_refused',
          source: source, stock_part_inventories: stock_inventories,
          helper: crystal.fetch(:data), helper_invocation: crystal.fetch(:invocation),
        )
        puts "W188 status=stock_compact_array_tuple_json_observed_and_reader_refused; stock sources checked, no library part attached; evidence=#{@root}"
        return true
      end

      library_paths = {
        'one' => File.join(@root, 'parts', 'library_one', 'all_1_1_0'),
        'two' => File.join(@root, 'parts', 'library_two', 'all_1_1_0'),
      }
      crystal = run_helper(source_parts, library_paths)
      assert_helper!(crystal, library_paths)

      library_inventories = {}
      profiles.each do |label, profile|
        inventory = inspect_library_part(label, library_paths.fetch(label), profile)
        assert_library_roster!(inventory, profile, crystal.fetch(:data).fetch('profiles').fetch(label))
        inventory[:compact_discriminator_payloads] = inspect_compact_discriminators!(inventory, profile) if @dynamic_mode == 'compact'
        library_inventories[label] = inventory
      end

      profiles.each do |label, profile|
        target_path = source.fetch(:data_paths).fetch(profile.fetch(:target))
        @base.send(:validate_store_path!, target_path)
        @base.send(:attach_part!, library_paths.fetch(label), target_path)
      end
      attached = @base.send(:run_clickhouse, 'native_attach_check', attached_sql)
      @base.send(:assert_pin!, attached)
      @base.send(:assert_native_invocation!, attached)
      attached_result = @base.send(:parse_native, attached[:stdout])
      assert_attached_native!(attached_result)

      @sha_after = binary_sha
      fail!('pinned ClickHouse executable SHA-256 changed during probe') unless @sha_after == BinarySHA256
      write_summary(
        status: "paired_recursive_array_tuple_json_#{@dynamic_mode}_observed",
        source: source, stock_part_inventories: stock_inventories,
        helper: crystal.fetch(:data), helper_invocation: crystal.fetch(:invocation),
        library_part_inventories: library_inventories, attached: attached_result,
      )
      puts "W188 status=paired_recursive_array_tuple_json_#{@dynamic_mode}_observed; one/two-array parts stock-checked and attached; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      @sha_after = binary_sha rescue nil
      write_summary(status: 'runner_failure_or_observations_differ', fatal_error: @fatal_error) rescue nil
      warn "W187 recursive Array/Tuple JSON probe failed: #{@fatal_error}"
      false
    end

    private

    def settings
      Settings.fetch(@dynamic_mode)
    end

    def initial_sql
      statements = [
        "SELECT '__W185_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
        'SET output_format_json_named_tuples_as_objects=1;',
      ]
      profiles.each do |label, profile|
        statements << "CREATE TABLE default.#{profile.fetch(:source)} (pk UInt64, a #{profile.fetch(:type)}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings};"
        unless @stock_only
          statements << "CREATE TABLE default.#{profile.fetch(:target)} (pk UInt64, a #{profile.fetch(:type)}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings};"
        end
        statements << insert_sql(profile)
      end
      profiles.each_value do |profile|
        table = profile.fetch(:source)
        statements << "SELECT '__W185_CHECK_BEGIN__', '#{table}' FORMAT TSVRaw;"
        statements << "CHECK TABLE default.#{table} FORMAT TSV;"
        statements << "SELECT '__W185_CHECK_END__', '#{table}' FORMAT TSVRaw;"
        statements << row_sql(table)
        statements << middle_row_sql(table)
      end
      tables = profiles.values.flat_map do |profile|
        @stock_only ? [profile.fetch(:source)] : [profile.fetch(:source), profile.fetch(:target)]
      end
      table_list = tables.map { |table| "'#{table}'" }.join(',')
      statements << "SELECT '__W185_SCHEMA__', table, name, type FROM system.columns WHERE database='default' AND table IN (#{table_list}) ORDER BY table,position FORMAT TSVRaw;"
      statements << "SELECT '__W185_DATA_PATH__', name, arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name IN (#{table_list}) ORDER BY name FORMAT TSVRaw;"
      source_list = profiles.values.map { |profile| "'#{profile.fetch(:source)}'" }.join(',')
      statements << "SELECT '__W185_PART__', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table IN (#{source_list}) AND active ORDER BY table,name FORMAT TSVRaw;"
      statements.join("\n") + "\n"
    end

    def insert_sql(profile)
      declaration = profile.fetch(:type)
      depth = profile.fetch(:array_depth)
      json_type = profile.fetch(:json_type, JsonType)
      values = profile.fetch(:values).each_with_index.map do |row_value, index|
        if depth == 1
          payload = sql_array(row_value.map { |tuple| tuple_sql(tuple, json_type, profile.fetch(:tuple_type, TupleType)) })
        else
          payload = sql_array(row_value.map do |inner|
            sql_array(inner.map { |tuple| tuple_sql(tuple, json_type, profile.fetch(:tuple_type, TupleType)) })
          end)
        end
        "(#{index + 1}, CAST(#{payload}, #{sql_string(declaration)}))"
      end.join(",\n")
      "INSERT INTO default.#{profile.fetch(:source)} VALUES #{values};"
    end

    def tuple_sql(tuple, json_type, tuple_type)
      left = "CAST(#{sql_string(JSON.generate(tuple.fetch('l')))}, #{sql_string(json_type)})"
      right = "CAST(#{sql_string(JSON.generate(tuple.fetch('r')))}, #{sql_string(json_type)})"
      "CAST((#{left}, #{right}, #{tuple.fetch('n')}), #{sql_string(tuple_type)})"
    end

    def sql_array(values)
      "[#{values.join(', ')}]"
    end

    def row_sql(table)
      "SELECT '__W185_ROW__', '#{table}', toString(pk), hex(toJSONString(a)) FROM default.#{table} ORDER BY pk FORMAT TSVRaw;"
    end

    def middle_row_sql(table)
      "SELECT '__W185_MIDDLE_ROW__', '#{table}', toString(pk), hex(toJSONString(a)) FROM default.#{table} WHERE pk BETWEEN 3 AND 6 ORDER BY pk FORMAT TSVRaw;"
    end

    def attached_sql
      statements = [
        "SELECT '__W185_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
        'SET output_format_json_named_tuples_as_objects=1;',
      ]
      profiles.each_value do |profile|
        table = profile.fetch(:target)
        statements << "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0';"
        statements << "SELECT '__W185_CHECK_BEGIN__', '#{table}' FORMAT TSVRaw;"
        statements << "CHECK TABLE default.#{table} FORMAT TSV;"
        statements << "SELECT '__W185_CHECK_END__', '#{table}' FORMAT TSVRaw;"
        statements << row_sql(table)
        statements << middle_row_sql(table)
      end
      targets = profiles.values.map { |profile| "'#{profile.fetch(:target)}'" }.join(',')
      statements << "SELECT '__W185_SCHEMA__', table, name, type FROM system.columns WHERE database='default' AND table IN (#{targets}) ORDER BY table,position FORMAT TSVRaw;"
      statements << "SELECT '__W185_PART__', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table IN (#{targets}) AND active ORDER BY table,name FORMAT TSVRaw;"
      statements.join("\n") + "\n"
    end

    def assert_initial_native!(native)
      expected_checks = profiles.values.to_h do |profile|
        [profile.fetch(:source), ["all_1_1_0\t1\t"]]
      end
      fail!("stock source CHECK differs: #{native[:checks].inspect}") unless native[:checks] == expected_checks

      expected_schemas = []
      profiles.each_value do |profile|
        expected_schemas << [profile.fetch(:source), 'pk', 'UInt64']
        expected_schemas << [profile.fetch(:source), Column, profile.fetch(:type)]
        unless @stock_only
          expected_schemas << [profile.fetch(:target), 'pk', 'UInt64']
          expected_schemas << [profile.fetch(:target), Column, profile.fetch(:type)]
        end
      end
      expected_schemas.sort_by! { |table, name, _type| [table, name == 'pk' ? 0 : 1] }
      fail!("stock schema differs: #{native[:schemas].inspect}") unless native[:schemas] == expected_schemas

      source_parts = {}
      profiles.each do |label, profile|
        source = profile.fetch(:source)
        assert_native_rows!(native[:rows], source, profile, :full)
        assert_native_rows!(native[:middle_rows], source, profile, :middle)
        fail!("data path missing for #{source}") unless native[:data_paths].key?(source)
        part = native[:parts][source] || fail!("stock source part missing for #{source}")
        unless part.values_at(:name, :part_type, :rows, :marks) == ['all_1_1_0', 'Wide', '8', '5']
          fail!("stock source layout differs for #{source}: #{part.inspect}")
        end
        source_parts[label] = part
      end
      source_parts
    end

    def assert_native_rows!(records, table, profile, scope)
      selected = records.select { |record| record[0] == table }
      decoded = selected.map do |fields|
        [table, fields[1], JSON.parse([fields[2]].pack('H*'))]
      rescue JSON::ParserError
        fail!("#{table} native output contained malformed JSON hex")
      end
      rows = expected_rows(profile)
      rows = rows.select { |row| (3..6).cover?(row[1].to_i) } if scope == :middle
      fail!("#{table} #{scope} rows differ from independent authored literals") unless decoded == rows
    end

    def expected_rows(profile)
      profile.fetch(:read_values, profile.fetch(:values)).each_with_index.map do |value, index|
        [profile.fetch(:source), (index + 1).to_s, value]
      end
    end

    def assert_source_roster!(inventory, profile)
      expected = expected_streams(profile)
      actual = inventory.fetch(:logical_substreams).sort
      fail!("#{inventory[:label]} stock logical roster differs; missing=#{(expected - actual).inspect}; extra=#{(actual - expected).inspect}") unless actual == expected.sort
      assert_physical_rows!(inventory, expected - ['pk'], inventory[:label])
      shared_level = profile.fetch(:array_depth)
      fail!('stock Object shared MAP lane did not inherit the full Array nesting level') unless
        ["a%2El.object_shared_data.size#{shared_level}", "a%2Er.object_shared_data.size#{shared_level}"].all? { |name| actual.include?(name) }
    end

    def run_helper(source_parts, library_paths, stock_only: false)
      unless stock_only
        library_paths.each do |label, path|
          fail!("library part destination already exists for #{label}") if File.exist?(path) || File.symlink?(path)
        end
      end
      argv = [@crystal_probe, '--dynamic-mode', @dynamic_mode]
      argv << '--stock-only' if stock_only
      argv.concat([source_parts.fetch('one').fetch(:path), source_parts.fetch('two').fetch(:path)])
      unless stock_only
        argv.concat([library_paths.fetch('one'), library_paths.fetch('two')])
      end
      invocation = @base.send(:execute_record, 'crystal_helper', argv, ''.b,
                              'prebuilt Crystal helper', nil, nil)
      fail!('Crystal helper failed; this is not a ClickHouse format rejection') unless @base.send(:successful?, invocation)
      fail!('Crystal helper wrote diagnostics to stderr') unless invocation[:stderr].empty?
      lines = invocation[:stdout].lines.map(&:chomp).reject(&:empty?)
      fail!('Crystal helper must emit exactly one JSON record') unless lines.size == 1
      {data: JSON.parse(lines.first), invocation: invocation[:record]}
    end

    def assert_stock_only_helper!(crystal)
      record = crystal.fetch(:data)
      fail!('stock-only helper did not report its baseline mode') unless record.fetch('status') == 'baseline_reader_refusal_observed'
      profiles.each do |label, _profile|
        refusal = record.fetch('profiles').fetch(label)
        fail!("#{label} helper did not observe a runtime UnsupportedFormatError") unless
          refusal.fetch('status') == 'unsupported' && refusal.fetch('error_class').end_with?('UnsupportedFormatError')
        fail!("#{label} helper refusal did not identify the compact child discriminator") unless
          refusal.fetch('message').match?(/compact|BASIC|discriminator/i)
      end
    end

    def assert_helper!(crystal, library_paths)
      result = crystal.fetch(:data)
      fail!('Crystal helper did not report observed status') unless result.fetch('status') == 'observed'
      library_parts = result.fetch('library_parts')
      library_paths.each do |label, path|
        fail!("helper library destination differs for #{label}") unless File.expand_path(library_parts.fetch(label)) == path
      end
      profiles.each do |label, profile|
        record = result.fetch('profiles').fetch(label)
        fail!("#{label} helper schema declaration differs") unless record.fetch('schema_declaration') == profile.fetch(:type)
        assert_reader!(record.fetch('stock_reader'), label, profile, 'stock')
        assert_reader!(record.fetch('library_reader'), label, profile, 'library')

        expected = expected_signatures(profile)
        fail!("#{label} stock table full rows differ") unless record.fetch('stock_table_rows') == expected
        fail!("#{label} stock table middle rows differ") unless record.fetch('stock_table_middle_rows') == expected_middle_signatures(profile)
        fail!("#{label} stock table zero read was not empty") unless record.fetch('stock_table_zero_rows') == []
        fail!("#{label} library table full rows differ") unless record.fetch('library_table_rows') == expected
        fail!("#{label} library table middle rows differ") unless record.fetch('library_table_middle_rows') == expected_middle_signatures(profile)
        fail!("#{label} library table zero read was not empty") unless record.fetch('library_table_zero_rows') == []
      end
    end

    def assert_reader!(record, label, profile, source)
      fail!("#{label} #{source} reader schema differs") unless record.fetch('schema_declaration') == profile.fetch(:type)
      fail!("#{label} #{source} reader row count differs") unless record.fetch('row_count') == 8
      fail!("#{label} #{source} reader mark count differs") unless record.fetch('mark_count') == 4
      fail!("#{label} #{source} physical parent grid differs") unless record.fetch('mark_row_counts') == [2, 2, 2, 2]
      fail!("#{label} #{source} full reader literals differ") unless record.fetch('full_rows') == expected_marked_signatures(profile)
      fail!("#{label} #{source} middle reader literals differ") unless record.fetch('middle_rows') == expected_middle_marked_signatures(profile)
      fail!("#{label} #{source} zero-selected-mark read was not empty") unless record.fetch('zero_rows') == []
      fail!("#{label} #{source} logical child occurrence counts differ") unless record.fetch('leaf_occurrence_counts') == [0, 1, 3, 0]

      expected_roster = expected_streams(profile) - ['pk']
      actual_roster = record.fetch('physical_stream_names')
      fail!("#{label} #{source} recursive reader physical roster differs") unless actual_roster.sort == expected_roster.sort
    end

    def expected_signatures(profile)
      profile.fetch(:read_values, profile.fetch(:values)).each_with_index.map { |value, index| [(index + 1).to_s, value] }
    end

    def expected_middle_signatures(profile)
      expected_signatures(profile).select { |row| (3..6).cover?(row[0].to_i) }
    end

    def expected_marked_signatures(profile)
      expected_signatures(profile).each_slice(2).map { |mark| mark }
    end

    def expected_middle_marked_signatures(profile)
      expected_middle_signatures(profile).each_slice(2).map { |mark| mark }
    end

    def expected_streams(profile)
      level = profile.fetch(:array_depth)
      compact = profile.fetch(:dynamic_mode, 'basic') == 'compact'
      streams = %w[
        a%2El.object_structure
        a%2El.a_left.dynamic_structure
        a%2El.a_left.variant_discr
        a%2Er.object_structure
        a%2Er.b_right.dynamic_structure
        a%2Er.b_right.variant_discr
        a.size0
      ]
      streams << 'a.size1' if level == 2
      streams.concat(['a%2El.t', 'a%2El.a_left.Int64'])
      if compact
        streams.concat(%w[a%2El.a_left.String.size a%2El.a_left.String])
      end
      streams.concat(%w[a%2El.a_left.SharedVariant.size a%2El.a_left.SharedVariant])
      streams.concat(["a%2El.object_shared_data.size#{level}",
                      'a%2El.object_shared_data%2Epaths',
                      'a%2El.object_shared_data%2Evalues'])
      streams.concat(%w[a%2Er.t a%2Er.b_right.SharedVariant.size a%2Er.b_right.SharedVariant])
      streams.concat(%w[a%2Er.b_right.String.size a%2Er.b_right.String])
      streams << 'a%2Er.b_right.Int64' if compact
      streams.concat(["a%2Er.object_shared_data.size#{level}",
                      'a%2Er.object_shared_data%2Epaths',
                      'a%2Er.object_shared_data%2Evalues',
                      'a%2En', 'pk'])
      streams
    end

    def inspect_compact_discriminators!(inventory, profile)
      expected_paths = %w[a%2El.a_left.variant_discr a%2Er.b_right.variant_discr]
      expected_paths.to_h do |logical_name|
        fail!("#{inventory[:label]} is missing compact discriminator stream #{logical_name}") unless
          inventory.fetch(:logical_substreams).include?(logical_name)
        decoded = decode_stock_stream!(inventory, logical_name)
        groups = parse_compact_groups!(decoded.fetch(:bytes), [0, 1, 3, 0], logical_name)
        alignment = bind_compact_mark_groups!(
          inventory, logical_name, groups, decoded.fetch(:frame_spans),
          decoded.fetch(:compressed_file_size), decoded.fetch(:decoded_size)
        )
        observation = {
          groups: groups,
          compressed_frame_spans: decoded.fetch(:frame_spans),
          mark_alignment: alignment,
        }
        stem = JsonArrayStorageW183.stream_hash(logical_name)
        @base.send(:write_new,
                   File.join(@root, 'parts', "#{inventory.fetch(:label)}_#{stem}_mark_alignment.json"),
                   JSON.pretty_generate(observation) + "\n")
        [logical_name, observation]
      end
    end

    def decode_stock_stream!(inventory, logical_name)
      stem = JsonArrayStorageW183.stream_hash(logical_name)
      input_path = File.join(inventory.fetch(:part_path), "#{stem}.bin")
      input_size = File.size(input_path)
      limit = JsonArrayStorageW183::COMPRESSED_INPUT_LIMIT
      fail!("#{logical_name} compressed input exceeds #{limit} bytes") if input_size > limit
      compressed = File.binread(input_path)
      fail!("#{logical_name} compressed input changed while reading") unless compressed.bytesize == input_size
      frame_inventory = compressed_frame_spans!(compressed, logical_name)
      label = "#{inventory.fetch(:label)}_#{stem}_decompress"
      input_file = "#{label}.stdin.bin"
      @base.send(:write_new, File.join(@root, 'invocations', input_file), compressed)
      before_sha = binary_sha
      fail!('pinned ClickHouse executable SHA-256 mismatch before compact decompression') unless before_sha == BinarySHA256
      argv = [@binary, 'compressor', '--decompress', '--threads=1']
      invocation = @base.send(:execute_record, label, argv, compressed,
                              'clickhouse compressor --decompress', BinarySHA256, @binary)
      fail!("#{logical_name} compressor utility failed; this is not a format rejection") unless
        @base.send(:successful?, invocation)
      fail!("#{logical_name} compressor wrote diagnostics") unless invocation[:stderr].empty?
      fail!("#{logical_name} decompressed output exceeds bounded 1 MiB witness") if invocation[:stdout].bytesize > 1024 * 1024
      fail!("#{logical_name} decompressor output differs from bounded frame-header sizes") unless
        invocation[:stdout].bytesize == frame_inventory.fetch(:decoded_size)
      fail!('pinned ClickHouse executable SHA-256 changed during compact decompression') unless binary_sha == BinarySHA256
      @base.send(:write_new, File.join(@root, 'invocations', "#{label}.payload.json"),
                 JSON.pretty_generate({
                   logical_stream: logical_name, input_file: input_file,
                   input_bytes: compressed.bytesize, input_sha256: Digest::SHA256.hexdigest(compressed),
                   binary_sha_before: before_sha, binary_sha_after: BinarySHA256,
                   compressed_file_size: compressed.bytesize,
                   decoded_size_from_headers: frame_inventory.fetch(:decoded_size),
                   compressed_frame_spans: frame_inventory.fetch(:spans),
                   compressor_memory_limit_bytes: nil, compressor_memory_limit_applicable: false,
                   utility_invocation: invocation[:record],
                   decoded_bytes: invocation[:stdout].bytesize,
                   decoded_sha256: Digest::SHA256.hexdigest(invocation[:stdout]),
                 }) + "\n")
      {
        bytes: invocation[:stdout], frame_spans: frame_inventory.fetch(:spans),
        compressed_file_size: compressed.bytesize, decoded_size: frame_inventory.fetch(:decoded_size),
      }
    end

    # Independently walk every ClickHouse block header before launching the
    # decompressor. This bounds aggregate output and preserves multi-frame
    # mark coordinates instead of assuming one frame per lane.
    def compressed_frame_spans!(compressed, logical_name)
      max_decoded_bytes = 1024 * 1024
      frame_header_bytes = 16 + 9
      offset = 0
      decoded_offset = 0
      spans = []
      while offset < compressed.bytesize
        fail!("#{logical_name} compressed block header is truncated") if
          compressed.bytesize - offset < frame_header_bytes
        method = compressed.getbyte(offset + 16)
        fail!("#{logical_name} compressed block method is not LZ4") unless method == 0x82
        compressed_size = compressed.byteslice(offset + 17, 4).unpack1('V')
        decoded_size = compressed.byteslice(offset + 21, 4).unpack1('V')
        fail!("#{logical_name} compressed block size is invalid") if compressed_size < 9
        frame_end = offset + 16 + compressed_size
        fail!("#{logical_name} compressed block exceeds the captured file") if frame_end > compressed.bytesize
        fail!("#{logical_name} decoded block size is zero or over the 1 MiB bound") if
          decoded_size.zero? || decoded_size > max_decoded_bytes - decoded_offset
        spans << {
          compressed_offset: offset, compressed_end_offset: frame_end,
          decoded_offset: decoded_offset, decoded_size: decoded_size,
          decoded_end_offset: decoded_offset + decoded_size,
        }
        offset = frame_end
        decoded_offset += decoded_size
      end
      fail!("#{logical_name} compressed stream has no complete frames") if spans.empty?
      fail!("#{logical_name} compressed frame walk did not end at file size") unless offset == compressed.bytesize
      {spans: spans, decoded_size: decoded_offset}
    end

    def normalize_mark_coordinate!(record, frame_spans, compressed_file_size, decoded_size, logical_name, mark)
      compressed_offset, in_frame_offset, _parent_rows = record
      if compressed_offset == compressed_file_size && in_frame_offset.zero?
        return decoded_size
      end
      frame = frame_spans.find { |span| span.fetch(:compressed_offset) == compressed_offset }
      fail!("#{logical_name} mark #{mark} does not point to a compressed frame start or file end") unless frame
      fail!("#{logical_name} mark #{mark} exceeds its decoded frame") if in_frame_offset > frame.fetch(:decoded_size)
      frame.fetch(:decoded_offset) + in_frame_offset
    end

    def bind_compact_mark_groups!(inventory, logical_name, groups, frame_spans, compressed_file_size, decoded_size)
      records = inventory.fetch(:mark_triples).fetch(logical_name)
      expected_parent_rows = [2, 2, 2, 2, 0]
      fail!("#{logical_name} physical mark count differs from four groups plus terminal") unless records.size == 5
      actual_parent_rows = records.map { |record| record[2] }
      fail!("#{logical_name} mark rows differ from physical parent grid [2,2,2,2,0]") unless
        actual_parent_rows == expected_parent_rows
      fail!("#{logical_name} parsed group count differs from physical mark count") unless groups.size == 4

      expected_offsets = groups.map { |group| group.fetch(:offset_start) } + [groups.last.fetch(:offset_end)]
      fail!("#{logical_name} first parsed group does not begin after the 8-byte mode prefix") unless expected_offsets.first == 8
      actual_offsets = records.each_with_index.map do |record, index|
        normalize_mark_coordinate!(record, frame_spans, compressed_file_size, decoded_size, logical_name, index)
      end
      fail!("#{logical_name} .mrk2 decoded coordinates differ from compact group boundaries") unless
        actual_offsets == expected_offsets

      actual_extents = actual_offsets.each_cons(2).map { |left, right| right - left }
      expected_extents = groups.map { |group| group.fetch(:body_bytes) }
      fail!("#{logical_name} positive group extents or empty repeated offsets differ") unless
        actual_extents == expected_extents
      fail!("#{logical_name} leading zero-child mark did not repeat the next group offset") unless
        actual_offsets[0] == actual_offsets[1]
      fail!("#{logical_name} trailing zero-child mark did not repeat the terminal offset") unless
        actual_offsets[3] == actual_offsets[4]
      fail!("#{logical_name} terminal mark does not map to frame/file decoded end") unless
        actual_offsets.last == decoded_size && records.last[2].zero?

      {
        physical_parent_rows: actual_parent_rows,
        raw_mark_triples: records,
        normalized_decoded_offsets: actual_offsets,
        group_body_extents: actual_extents,
        expected_group_body_extents: expected_extents,
        terminal_is_decoded_end: actual_offsets.last == decoded_size,
      }
    end

    def parse_compact_groups!(bytes, child_counts, logical_name)
      fail!("#{logical_name} compact discriminator mode prefix is truncated") if bytes.bytesize < 8
      mode = bytes.byteslice(0, 8).unpack1('Q<')
      fail!("#{logical_name} discriminator mode prefix is not COMPACT=1") unless mode == 1
      offset = 8
      groups = child_counts.each_with_index.map do |count, mark|
        group_start = offset
        if count.zero?
          {mark: mark, child_count: 0, body_bytes: 0, offset_start: offset, offset_end: offset}
        else
          row_count, offset = read_varuint!(bytes, offset, logical_name)
          fail!("#{logical_name} mark #{mark} encoded row count differs") unless row_count == count
          fail!("#{logical_name} mark #{mark} granule format is truncated") if offset >= bytes.bytesize
          format = bytes.getbyte(offset)
          offset += 1
          if count == 1
            fail!("#{logical_name} singleton group is not compact format1") unless format == 1
            fail!("#{logical_name} singleton discriminator is truncated") if offset >= bytes.bytesize
            tags = [bytes.getbyte(offset)]
            offset += 1
            fail!("#{logical_name} singleton group unexpectedly uses NULL") if tags[0] == 255
          else
            fail!("#{logical_name} mixed group is not plain format0") unless format == 0
            fail!("#{logical_name} mixed discriminator vector is truncated") if bytes.bytesize - offset < count
            tags = bytes.byteslice(offset, count).bytes
            offset += count
            fail!("#{logical_name} mixed group did not retain the authored NULL row") unless tags[1] == 255
            fail!("#{logical_name} mixed group does not distinguish Int64 and String tags") unless
              tags[0] != 255 && tags[2] != 255 && tags[0] != tags[2]
          end
          {mark: mark, child_count: count, format: format, tags: tags,
           body_bytes: offset - group_start, offset_start: group_start, offset_end: offset}
        end
      end
      fail!("#{logical_name} compact lane has unaccounted bytes after four groups") unless offset == bytes.bytesize
      groups
    end

    def read_varuint!(bytes, offset, logical_name)
      value = 0
      shift = 0
      10.times do
        fail!("#{logical_name} compact row-count VarUInt is truncated") if offset >= bytes.bytesize
        byte = bytes.getbyte(offset)
        offset += 1
        payload = byte & 0x7f
        fail!("#{logical_name} compact row-count VarUInt overflows") if shift == 63 && payload > 1
        value |= payload << shift
        return [value, offset] if (byte & 0x80).zero?
        shift += 7
      end
      fail!("#{logical_name} compact row-count VarUInt is unterminated")
    end

    def assert_library_roster!(inventory, profile, record)
      expected = expected_streams(profile)
      actual = inventory.fetch(:logical_substreams).sort
      fail!("library #{inventory[:label]} physical roster differs") unless actual == expected.sort
      assert_physical_rows!(inventory, expected - ['pk'], inventory[:label])
      helper_names = record.fetch('library_reader').fetch('physical_stream_names')
      fail!("library #{inventory[:label]} reader/part roster differs") unless helper_names.sort == (expected - ['pk']).sort
      fail!('array wrapper size lanes and Object shared size lane were conflated') if
        (profile.fetch(:array_depth) == 2 && actual.include?('a.size2'))
    end

    def inspect_library_part(label, path, profile)
      expected_path = File.join(@root, 'parts', "library_#{label}", 'all_1_1_0')
      fail!("library part escaped its exact destination: #{path}") unless File.expand_path(path) == expected_path
      fail!("library part is absent: #{path}") unless File.directory?(path)
      @base.send(:validate_plain_tree!, path)

      required_files = %w[
        columns.txt columns_substreams.txt count.txt checksums.txt primary.idx
        serialization.json default_compression_codec.txt metadata_version.txt
      ]
      required_files.each do |name|
        fail!("library #{label} part is missing #{name}") unless File.file?(File.join(path, name))
      end
      columns = File.read(File.join(path, 'columns.txt'))
      fail!("library #{label} exact column declaration differs") unless columns.include?("`a` #{profile.fetch(:type)}\n")
      fail!("library #{label} primary-key declaration differs") unless columns.include?("`pk` UInt64\n")
      fail!("library #{label} count.txt differs") unless File.read(File.join(path, 'count.txt')).strip == '8'
      fail!("library #{label} default codec differs") unless File.read(File.join(path, 'default_compression_codec.txt')).strip == 'CODEC(LZ4)'
      fail!("library #{label} metadata version differs") unless File.read(File.join(path, 'metadata_version.txt')).strip == '0'
      serialization_text = File.binread(File.join(path, 'serialization.json')).force_encoding(Encoding::UTF_8)
      serialization = JSON.parse(serialization_text)
      fail!("library #{label} serialization version differs") unless serialization['version'] == 1
      fail!("library #{label} did not explicitly propagate nested serialization versions") unless
        serialization['propagate_types_serialization_versions_to_nested_types'] == true
      string_version = serialization.dig('types_serialization_versions', 'string')
      fail!("library #{label} ordinary string version is unsupported") unless [0, 1].include?(string_version)

      substreams = File.binread(File.join(path, 'columns_substreams.txt')).force_encoding(Encoding::UTF_8)
      logical = substreams.lines.map do |line|
        line.strip.sub(/\A\*\s*/, '') if line.start_with?("\t")
      end.compact
      fail!("library #{label} logical stream roster differs") unless logical.sort == expected_streams(profile).sort
      fail!("library #{label} has duplicate logical streams") unless logical.uniq.size == logical.size
      filenames = Dir.children(path).sort
      expected_stream_files = logical.flat_map do |name|
        stem = JsonArrayStorageW183.stream_hash(name)
        ["#{stem}.bin", "#{stem}.mrk2"]
      end.sort
      actual_stream_files = filenames.select { |name| name.end_with?('.bin', '.mrk2') }.sort
      fail!("library #{label} hashed lane files differ from its logical roster") unless actual_stream_files == expected_stream_files

      mark_triples = logical.to_h do |name|
        stem = JsonArrayStorageW183.stream_hash(name)
        raw = File.binread(File.join(path, "#{stem}.mrk2"))
        words = raw.unpack('Q<*')
        fail!("library #{label} #{name} has malformed plain marks") unless words.size == 15
        [name, words.each_slice(3).map(&:dup)]
      end
      inventory = {
        label: "library_#{label}", part_name: 'all_1_1_0', part_path: path,
        part_type: 'Wide', rows: '8', marks: 'unattached', count_text: '8',
        logical_substreams: logical, physical_file_names: filenames,
        mark_triples: mark_triples,
        stream_file_inventory: actual_stream_files.to_h do |filename|
          [filename, {size: File.size(File.join(path, filename)), sha256: Digest::SHA256.file(File.join(path, filename)).hexdigest}]
        end,
        serialization_json_sha256: Digest::SHA256.hexdigest(serialization_text),
        ordinary_string_serialization_version: string_version,
        plain_mrk2_only: true,
      }
      assert_physical_rows!(inventory, expected_streams(profile) - ['pk'], "library_#{label}")
      inventory
    end

    def assert_physical_rows!(inventory, stream_names, label)
      expected = [2, 2, 2, 2, 0]
      stream_names.each do |name|
        triples = inventory.fetch(:mark_triples)[name] || fail!("#{label} is missing marks for #{name}")
        fail!("#{label} #{name} physical parent mark grid differs") unless triples.map { |triple| triple[2] } == expected
      end
    end

    def assert_attached_native!(native)
      expected_checks = profiles.values.to_h do |profile|
        [profile.fetch(:target), ["all_1_1_0\t1\t"]]
      end
      fail!("stock rejected or failed a library part CHECK: #{native[:checks].inspect}") unless native[:checks] == expected_checks
      expected_schemas = profiles.values.flat_map do |profile|
        [[profile.fetch(:target), 'pk', 'UInt64'], [profile.fetch(:target), Column, profile.fetch(:type)]]
      end
      expected_schemas.sort_by! { |table, name, _type| [table, name == 'pk' ? 0 : 1] }
      fail!("attached library schemas differ: #{native[:schemas].inspect}") unless native[:schemas] == expected_schemas
      profiles.each_value do |profile|
        table = profile.fetch(:target)
        assert_native_rows!(native[:rows], table, profile.merge(source: table), :full)
        assert_native_rows!(native[:middle_rows], table, profile.merge(source: table), :middle)
        part = native[:parts][table] || fail!("stock did not expose attached part for #{table}")
        fail!("attached #{table} part identity/layout differs") unless
          part.values_at(:name, :part_type, :rows, :marks) == ['all_1_1_0', 'Wide', '8', '5']
      end
    end

    def sql_string(value)
      "'#{value.to_s.gsub('\\') { '\\\\' }.gsub("'") { "\\'" }}'"
    end

    def binary_sha
      Digest::SHA256.file(@binary).hexdigest
    end

    def write_summary(data)
      summary = {
        probe: "W188 #{@dynamic_mode} recursive Array/Tuple JSON qualification",
        status: data[:status], fatal_error: data[:fatal_error],
        runtime: {path: @binary, expected_sha256: BinarySHA256, sha256_before: @sha_before,
                  sha256_after: @sha_after, expected_version: Version, expected_build: Build},
        helper: @crystal_probe,
        limits: {max_threads: 1, local_max_memory_usage_bytes: Memory,
                 compressor_max_memory_usage_bytes: nil, compressor_memory_limit_applicable: false,
                 compressor_compressed_input_limit_bytes: JsonArrayStorageW183::COMPRESSED_INPUT_LIMIT,
                 required_outer_run_safe_memory_limit_bytes: OuterRunSafeLimit,
                 timeout_seconds: Timeout, termination_grace_seconds: Grace,
                 executor: 'JsonBinaryKernelW180Probe#execute'},
        dynamic_mode: @dynamic_mode, stock_only: @stock_only,
        settings: settings, evidence_root: @root,
      }.merge(data.reject { |key, _value| %i[status fatal_error].include?(key) })
      @base.send(:write_new, File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      @base.send(:write_new, File.join(@root, 'summary.md'), [
        '# W188 recursive Array/Tuple JSON qualification', '',
        "Status: `#{summary[:status]}`", '',
        'The one-Array and repeated-Array profiles each have eight parent rows and four two-row physical marks; leaf Tuple occurrence counts are [0, 1, 3, 0]. COMPACT mode additionally checks decompressed stock discriminator headers: empty groups have no body bytes, the singleton uses format1, and the mixed Int64/NULL/String group uses format0. The equal nominal JSON sites have distinct dynamic paths and nonempty shared MAP data.', '',
        (@stock_only ? 'Stock-only baseline: CREATE/INSERT/CHECK and actual compressed discriminator inspection run before the unchanged recursive reader is required to report UnsupportedFormatError. No library part is written or attached.' : 'Paired mode directly reopens stock and library parts, checks the public table path for full/middle/zero-selected reads, then stock ATTACH/CHECKs the library parts and compares exact schemas and authored rows.'), '',
        "Runtime: #{Version} / #{Build} / SHA256 `#{BinarySHA256}`; explicit compact setting: #{settings}", '',
        'Native and decompressor jobs use the bounded W185/W180 executor; a process failure is never classified as a format rejection.', '',
        "Evidence root: `#{@root}`", '',
      ].join("\n"))
    end

    def fail!(message)
      raise RuntimeError, "W187 recursive Array/Tuple JSON probe: #{message}"
    end
  end
end

def main
  options = {binary: CheckRecursiveJSONArrayTuplePartsW187::Binary, dynamic_mode: 'basic', stock_only: false}
  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby scripts/check_recursive_json_array_tuple_parts_w187.rb --evidence-root EMPTY_CHILD_OF_PRIVATE_TMP --crystal-probe PREBUILT_HELPER [--binary CLICKHOUSE] [--dynamic-mode basic|compact] [--stock-only]'
    parser.on('--binary PATH') { |value| options[:binary] = value }
    parser.on('--crystal-probe PATH') { |value| options[:crystal_probe] = value }
    parser.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
    parser.on('--dynamic-mode MODE') { |value| options[:dynamic_mode] = value }
    parser.on('--stock-only') { options[:stock_only] = true }
  end.parse!
  raise 'prebuilt Crystal helper is required via --crystal-probe' unless options[:crystal_probe]
  exit(CheckRecursiveJSONArrayTuplePartsW187::Probe.new(
    options[:binary], options[:crystal_probe], options[:evidence_root],
    dynamic_mode: options[:dynamic_mode], stock_only: options[:stock_only]
  ).run ? 0 : 1)
rescue StandardError => error
  warn "W187 recursive Array/Tuple JSON runner error: #{error.class}: #{error.message}"
  exit 1
end

main if $PROGRAM_NAME == __FILE__
