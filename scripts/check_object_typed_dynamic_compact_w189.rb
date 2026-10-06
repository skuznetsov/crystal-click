#!/usr/bin/env ruby
# Bounded paired stock/library qualifier for declared typed-Dynamic Object
# leaves under Array/Tuple wrappers. Native processes and block decompression
# reuse the pinned W185/W187 supervisors; this file never builds executables.

require 'json'
require 'optparse'
require_relative 'check_recursive_json_array_tuple_parts_w187'

module CheckObjectTypedDynamicCompactW189
  extend self

  Base = CheckRecursiveJSONArrayTuplePartsW187
  Binary = Base::Binary
  BinarySHA256 = Base::BinarySHA256
  Version = Base::Version
  Build = Base::Build
  JsonType = 'JSON(max_dynamic_types=1, max_dynamic_paths=0, array Array(Dynamic(max_types=1)), direct Dynamic(max_types=1))'.freeze
  TupleType = "Tuple(l #{JsonType}, r #{JsonType}, n UInt64)".freeze
  OneType = "Array(#{TupleType})".freeze
  TwoType = "Array(Array(#{TupleType}))".freeze

  ElementLiterals = (1..4).to_h do |index|
    left = {'direct' => {1 => nil, 2 => 102, 3 => 'left-spill-3', 4 => 104}.fetch(index)}
    right = {'direct' => {1 => nil, 2 => 'right-2', 3 => 203, 4 => 'right-4'}.fetch(index)}
    left['array'] = case index
                    when 1 then [nil]
                    when 3 then [31, 'left-array-spill', 33]
                    else        []
                    end
    right['array'] = case index
                     when 1 then [nil]
                     when 3 then [true, 'right-array-spill', false]
                     else        []
                     end
    if index == 1
      left['z_shared'] = 'left-shared'
      right['z_shared'] = 'right-shared'
    end
    [index, {'l' => left, 'r' => right, 'n' => index * 100}]
  end.freeze
  OneValues = [[], [], [], [ElementLiterals.fetch(1)],
               [ElementLiterals.fetch(2), ElementLiterals.fetch(3)],
               [ElementLiterals.fetch(4)], [], []].freeze
  TwoValues = [[], [], [[]], [[ElementLiterals.fetch(1)]],
               [[], [ElementLiterals.fetch(2), ElementLiterals.fetch(3)]],
               [[ElementLiterals.fetch(4)]], [], []].freeze

  ProfilesByMode = %w[basic compact].to_h do |mode|
    profiles = {
      'one' => {source: 'source_one', target: 'library_one', type: OneType,
                json_type: JsonType, tuple_type: TupleType, array_depth: 1,
                values: OneValues, read_values: OneValues, dynamic_mode: mode},
      'two' => {source: 'source_two', target: 'library_two', type: TwoType,
                json_type: JsonType, tuple_type: TupleType, array_depth: 2,
                values: TwoValues, read_values: TwoValues, dynamic_mode: mode},
    }.freeze
    [mode, profiles]
  end.freeze

  class Probe < Base::Probe
    def initialize(binary, crystal_probe, evidence_root, dynamic_mode: 'basic')
      super(binary, crystal_probe, evidence_root, dynamic_mode: dynamic_mode, stock_only: false)
      fail!('W189 supports BASIC or COMPACT only') unless %w[basic compact].include?(dynamic_mode)
      @dynamic_mode = dynamic_mode
    end

    def profiles
      ProfilesByMode.fetch(@dynamic_mode)
    end

    def run
      %w[invocations stores parts].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      Dir.mkdir(File.join(@root, 'stores', 'native'), 0o700)
      Dir.mkdir(File.join(@root, 'parts', 'library_one'), 0o700)
      Dir.mkdir(File.join(@root, 'parts', 'library_two'), 0o700)
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
        inventory[:discriminator_payloads] = inspect_discriminators!(inventory, profile)
        stock_inventories[label] = inventory
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
        inventory[:discriminator_payloads] = inspect_discriminators!(inventory, profile)
        library_inventories[label] = inventory
      end
      profiles.each_value do |profile|
        target_path = source.fetch(:data_paths).fetch(profile.fetch(:target))
        @base.send(:validate_store_path!, target_path)
        @base.send(:attach_part!, library_paths.fetch(profile.fetch(:source).delete_prefix('source_')), target_path)
      end
      attached = @base.send(:run_clickhouse, 'native_attach_check', attached_sql)
      @base.send(:assert_pin!, attached)
      @base.send(:assert_native_invocation!, attached)
      attached_result = @base.send(:parse_native, attached[:stdout])
      assert_attached_native!(attached_result)
      @sha_after = binary_sha
      fail!('pinned ClickHouse executable SHA-256 changed during probe') unless @sha_after == BinarySHA256
      write_summary(status: "paired_declared_typed_dynamic_#{@dynamic_mode}_observed",
                    source: source, stock_part_inventories: stock_inventories,
                    helper: crystal.fetch(:data), helper_invocation: crystal.fetch(:invocation),
                    library_part_inventories: library_inventories, attached: attached_result)
      puts "W189 status=paired_declared_typed_dynamic_#{@dynamic_mode}_observed; stock and library parts checked; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      @sha_after = binary_sha rescue nil
      write_summary(status: 'runner_failure_or_observations_differ', fatal_error: @fatal_error) rescue nil
      warn "W189 declared typed-Dynamic probe failed: #{@fatal_error}"
      false
    end

    def expected_streams(profile)
      level = profile.fetch(:array_depth)
      streams = %w[
        a%2El.object_structure
        a%2El.direct.dynamic_structure a%2El.direct.variant_discr
        a%2El.array.dynamic_structure a%2El.array.variant_discr
        a%2Er.object_structure
        a%2Er.direct.dynamic_structure a%2Er.direct.variant_discr
        a%2Er.array.dynamic_structure a%2Er.array.variant_discr
        a.size0
      ]
      streams << 'a.size1' if level == 2
      streams.concat(%w[
        a%2El.direct.Int64 a%2El.direct.SharedVariant.size a%2El.direct.SharedVariant
        a%2El.array.Int64 a%2El.array.SharedVariant.size a%2El.array.SharedVariant
        a%2El.object_shared_data%2Epaths a%2El.object_shared_data%2Evalues
        a%2Er.direct.SharedVariant.size a%2Er.direct.SharedVariant
        a%2Er.direct.String.size a%2Er.direct.String
        a%2Er.array.Bool a%2Er.array.SharedVariant.size a%2Er.array.SharedVariant
        a%2Er.object_shared_data%2Epaths a%2Er.object_shared_data%2Evalues
        a%2En pk
      ])
      streams.concat(["a%2El.object_shared_data.size#{level}", "a%2Er.object_shared_data.size#{level}"])
      streams.concat(["a%2El.array.size#{level}", "a%2Er.array.size#{level}"])
      streams
    end

    def assert_source_roster!(inventory, profile)
      expected = expected_streams(profile)
      actual = inventory.fetch(:logical_substreams).sort
      fail!("#{inventory[:label]} stock logical roster differs; missing=#{(expected - actual).inspect}; extra=#{(actual - expected).inspect}") unless actual == expected.sort
      assert_physical_rows!(inventory, expected - ['pk'], inventory[:label])
      level = profile.fetch(:array_depth)
      %w[l r].each do |side|
        name = "a%2E#{side}.object_shared_data.size#{level}"
        fail!("stock shared MAP did not inherit enclosing Array level: #{name}") unless actual.include?(name)
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
      expected_roster = expected_streams(profile) - ['pk']
      fail!("#{label} #{source} recursive reader physical roster differs") unless record.fetch('physical_stream_names').sort == expected_roster.sort
    end

    def inspect_discriminators!(inventory, _profile)
      expected = {
        'a%2El.direct.variant_discr' => [255, 0, 1, 0],
        'a%2Er.direct.variant_discr' => [255, 1, 0, 1],
        'a%2El.array.variant_discr' => [255, 0, 1, 0],
        'a%2Er.array.variant_discr' => [255, 0, 1, 0],
      }
      expected_occurrences = {
        'a%2El.direct.variant_discr' => [0, 1, 3, 0],
        'a%2Er.direct.variant_discr' => [0, 1, 3, 0],
        'a%2El.array.variant_discr' => [0, 1, 3, 0],
        'a%2Er.array.variant_discr' => [0, 1, 3, 0],
      }
      expected.to_h do |logical_name, tags|
        fail!("#{inventory[:label]} missing #{@dynamic_mode.upcase} discriminator #{logical_name}") unless
          inventory.fetch(:logical_substreams).include?(logical_name)
        decoded = decode_stock_stream!(inventory, logical_name)
        bytes = decoded.fetch(:bytes)
        fail!("#{logical_name} mode prefix is truncated") if bytes.bytesize < 8
        mode = bytes.byteslice(0, 8).unpack1('Q<')
        expected_mode = @dynamic_mode == 'compact' ? 1 : 0
        fail!("#{logical_name} mode prefix differs from selected #{@dynamic_mode} profile") unless mode == expected_mode
        groups = nil
        alignment = nil
        if @dynamic_mode == 'compact'
          groups = parse_w189_compact_groups!(bytes, logical_name, tags)
          alignment = bind_compact_mark_groups!(inventory, logical_name, groups,
                                                decoded.fetch(:frame_spans),
                                                decoded.fetch(:compressed_file_size),
                                                decoded.fetch(:decoded_size))
        else
          child_counts = expected_occurrences.fetch(logical_name)
          groups = parse_w189_basic_groups!(bytes, logical_name, tags, child_counts)
          alignment = bind_compact_mark_groups!(inventory, logical_name, groups,
                                                decoded.fetch(:frame_spans),
                                                decoded.fetch(:compressed_file_size),
                                                decoded.fetch(:decoded_size))
        end
        observation = {
          groups: groups,
          basic_body_tags: (@dynamic_mode == 'basic' ? tags : nil),
          logical_occurrence_counts: expected_occurrences.fetch(logical_name),
          compressed_frame_spans: decoded.fetch(:frame_spans),
          mark_alignment: alignment,
        }
        stem = JsonArrayStorageW183.stream_hash(logical_name)
        @base.send(:write_new, File.join(@root, 'parts', "#{inventory.fetch(:label)}_#{stem}_mark_alignment.json"),
                   JSON.pretty_generate(observation) + "\n")
        [logical_name, observation]
      end
    end

    def parse_w189_basic_groups!(bytes, logical_name, expected_tags, child_counts)
      fail!("#{logical_name} BASIC mode prefix is truncated") if bytes.bytesize < 8
      fail!("#{logical_name} mode prefix is not BASIC=0") unless bytes.byteslice(0, 8).unpack1('Q<').zero?
      body = bytes.byteslice(8, bytes.bytesize - 8).bytes
      fail!("#{logical_name} BASIC normalized tag bytes differ") unless body == expected_tags
      offset = 8
      tag_offset = 0
      child_counts.each_with_index.map do |count, mark|
        start = offset
        tags = body.slice(tag_offset, count) || []
        fail!("#{logical_name} BASIC mark #{mark} tag count differs") unless tags.size == count
        tag_offset += count
        offset += count
        {mark: mark, child_count: count, format: nil, tags: tags,
         body_bytes: count, offset_start: start, offset_end: offset}
      end.tap do
        fail!("#{logical_name} BASIC groups do not consume the normalized body") unless tag_offset == body.size
      end
    end

    def parse_w189_compact_groups!(bytes, logical_name, expected_tags)
      fail!("#{logical_name} COMPACT mode prefix is truncated") if bytes.bytesize < 8
      fail!("#{logical_name} mode prefix is not COMPACT=1") unless bytes.byteslice(0, 8).unpack1('Q<') == 1
      offset = 8
      [0, 1, 3, 0].each_with_index.map do |count, mark|
        start = offset
        if count.zero?
          {mark: mark, child_count: 0, body_bytes: 0, offset_start: offset, offset_end: offset}
        else
          rows, offset = read_varuint!(bytes, offset, logical_name)
          fail!("#{logical_name} mark #{mark} row count differs") unless rows == count
          fail!("#{logical_name} mark #{mark} format byte is absent") if offset >= bytes.bytesize
          format = bytes.getbyte(offset)
          offset += 1
          if count == 1
            fail!("#{logical_name} all-NULL singleton must use COMPACT format1") unless format == 1
            fail!("#{logical_name} singleton tag is absent") if offset >= bytes.bytesize
            tags = [bytes.getbyte(offset)]
            offset += 1
            fail!("#{logical_name} positive all-NULL group tag differs") unless tags == [expected_tags.fetch(0)]
          else
            fail!("#{logical_name} mixed three-row group must use format0") unless format == 0
            fail!("#{logical_name} mixed tags are truncated") if bytes.bytesize - offset < count
            tags = bytes.byteslice(offset, count).bytes
            offset += count
            fail!("#{logical_name} mixed group tags differ") unless tags == expected_tags.drop(1)
          end
          {mark: mark, child_count: count, format: format, tags: tags,
           body_bytes: offset - start, offset_start: start, offset_end: offset}
        end
      end.tap do
        fail!("#{logical_name} has trailing or missing COMPACT payload bytes") unless offset == bytes.bytesize
      end
    end

    def write_summary(data)
      summary = {
        probe: "W189 declared typed-Dynamic #{@dynamic_mode} Array/Tuple qualification",
        status: data[:status], fatal_error: data[:fatal_error],
        runtime: {path: @binary, expected_sha256: BinarySHA256, sha256_before: @sha_before,
                  sha256_after: @sha_after, expected_version: Version, expected_build: Build},
        helper_path: @crystal_probe,
        limits: {max_threads: 1, local_max_memory_usage_bytes: Base::Memory,
                 required_outer_run_safe_memory_limit_bytes: Base::OuterRunSafeLimit,
                 timeout_seconds: Base::Timeout, termination_grace_seconds: Base::Grace,
                 executor: 'JsonBinaryKernelW180Probe#execute'},
        dynamic_mode: @dynamic_mode, settings: send(:settings),
        evidence_root: @root,
        claims: {
          complete_parent_grid: true,
          zero_selection_authenticates_unselected_discriminator_bodies: false,
          selected_payload_authentication_only: true,
          nested_declared_array_dynamic_sites: true,
          equal_nominal_json_siblings_with_distinct_actual_rosters: true,
        },
      }.merge(data.reject { |key, _value| %i[status fatal_error].include?(key) })
      @base.send(:write_new, File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      note = [
        '# W189 declared typed-Dynamic qualification', '',
        "Status: `#{summary[:status]}`", '',
        'The profile covers direct Dynamic and Array(Dynamic) typed lanes in two equal-nominal JSON leaves under one and repeated Array/Tuple wrappers. Each leaf has independently authored actual arm rosters; one positive group is all NULL while zero-child groups have no body. The helper reads full, middle, and zero-selected windows; zero selection validates physical grids and headers, not unselected discriminator bodies.', '',
        "Runtime: #{Version} / #{Build} / SHA256 `#{BinarySHA256}`; explicit mode: #{@dynamic_mode}", '',
        "Evidence root: `#{@root}`", '',
      ].join("\n")
      @base.send(:write_new, File.join(@root, 'summary.md'), note)
    end

    def fail!(message)
      raise RuntimeError, "W189 declared typed-Dynamic probe: #{message}"
    end
  end
end

def main
  options = {binary: CheckObjectTypedDynamicCompactW189::Binary, dynamic_mode: 'basic'}
  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby scripts/check_object_typed_dynamic_compact_w189.rb --evidence-root EMPTY_CHILD_OF_PRIVATE_TMP --crystal-probe PREBUILT_HELPER [--binary CLICKHOUSE] [--dynamic-mode basic|compact]'
    parser.on('--binary PATH') { |value| options[:binary] = value }
    parser.on('--crystal-probe PATH') { |value| options[:crystal_probe] = value }
    parser.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
    parser.on('--dynamic-mode MODE') { |value| options[:dynamic_mode] = value }
  end.parse!
  raise 'prebuilt Crystal helper required via --crystal-probe' unless options[:crystal_probe]
  exit(CheckObjectTypedDynamicCompactW189::Probe.new(
    options[:binary], options[:crystal_probe], options[:evidence_root],
    dynamic_mode: options[:dynamic_mode]
  ).run ? 0 : 1)
rescue StandardError => error
  warn "W189 runner error: #{error.class}: #{error.message}"
  exit 1
end

main if $PROGRAM_NAME == __FILE__
