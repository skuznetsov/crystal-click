#!/usr/bin/env ruby
# Bounded W253 reciprocal native witness for persisted JSON SKIP path policy.
# Reuses the W252/W210 process owner and part snapshots; it does not compile.

require 'digest'
require 'json'
require 'optparse'
require_relative 'probe_json_path_identity_w252'

module ProbeJSONSkipPathsW253
  W252 = ProbeJSONPathIdentityW252
  W210 = W252::W210
  FORMAT_INPUT = 'json_skip_paths_w253_input_v1'.freeze
  FORMAT_HELPER = 'json_skip_paths_w253_helper_v1'.freeze
  FORMAT_CAPTURE = 'json_skip_paths_w253_capture_v1'.freeze
  VERSION_PROFILES = {'v1' => 'single_stream', 'v2' => 'with_size_stream'}.freeze
  CASE_IDS = %w[root_dynamic array_dynamic root_object].freeze
  IMPLEMENTATION_FILES = %w[
    src/crystal_click.cr
    src/crystal_click/binary_codec_context.cr
    src/crystal_click/binary_data_type.cr
    src/crystal_click/binary_json_type.cr
    src/crystal_click/binary_json_type_codec.cr
    src/crystal_click/binary_json_value_codec.cr
    src/crystal_click/binary_recursive_data_type_name_reader.cr
    src/crystal_click/binary_type_name_budget.cr
    src/crystal_click/dynamic_json_object_binding.cr
    src/crystal_click/json_path_sql_name.cr
    src/crystal_click/json_skip_paths.cr
    src/crystal_click/object_document_schema.cr
    src/crystal_click/object_document_schema_parser.cr
  ].map { |name| File.expand_path(name, File.expand_path('..', __dir__)) }.freeze
  SOURCE_FILES = ([
    File.expand_path(__FILE__),
    File.expand_path('check_json_skip_paths_w253.cr', __dir__),
  ] + W252::SOURCE_FILES + IMPLEMENTATION_FILES).uniq.freeze
  PARENT_MARK_ROWS = [2, 2, 2].freeze
  JSON_CHILD_MARK_ROWS = [2, 2, 2, 0].freeze
  RAW_PATHS = %w[a.b a%2Eb a`b id maybe x=y].freeze
  DYNAMIC_PATHS = %w[counter secretary zz].freeze
  OBJECT_DYNAMIC_PATHS = %w[secretary zz].freeze
  JSON_TYPE = 'JSON(max_dynamic_types=1, max_dynamic_paths=3, `a%2Eb` UInt8, `a.b` UInt8, `a\\`b` UInt8, id UInt8, maybe Nullable(UInt8), `x=y` UInt8, SKIP secret, SKIP z)'.freeze
  UNUSED_JSON_TYPE = JSON_TYPE.sub('max_dynamic_types=1', 'max_dynamic_types=2').freeze
  DYNAMIC_TYPE = 'Dynamic(max_types=3)'.freeze
  ARRAY_DYNAMIC_TYPE = "Array(#{DYNAMIC_TYPE})".freeze
  UINT8_TYPE = 'UInt8'.freeze
  INT64_TYPE = 'Int64'.freeze
  WINDOWS = %w[candidate_marks eof_zero].freeze

  class Probe < W252::Probe
    def initialize(binary, crystal_helper, evidence_root, dynamic_version, helper_mode)
      super
      fail_w253!('Dynamic version must be v1 or v2') unless VERSION_PROFILES.key?(dynamic_version)
      fail_w253!('helper mode must be debug or release') unless %w[debug release].include?(helper_mode)
      @dynamic_version = dynamic_version
      @profile = VERSION_PROFILES.fetch(dynamic_version)
      @helper_mode = helper_mode
    end

    private

    def fail_w253!(message)
      raise "W253 JSON SKIP path witness: #{message}"
    end

    def source_pins
      SOURCE_FILES.map do |path|
        fail_w253!("pinned harness source is missing or symlinked: #{path}") unless File.file?(path) && !File.symlink?(path)
        {'path' => path, 'sha256' => Digest::SHA256.file(path).hexdigest}
      end
    end

    def table_type(case_id)
      case case_id
      when 'root_dynamic' then DYNAMIC_TYPE
      when 'array_dynamic' then ARRAY_DYNAMIC_TYPE
      when 'root_object' then JSON_TYPE
      else fail_w253!("unknown case #{case_id.inspect}")
      end
    end

    def object_row(index)
      {
        'a' => {'b' => 17 + index}, 'a%2Eb' => 23 + index, 'a`b' => 31 + index,
        'id' => 41 + index, 'maybe' => nil, 'x=y' => 42 + index,
        'secretary' => 51 + index, 'zz' => 61 + index,
      }
    end

    def dynamic_json_row(index)
      row = object_row(index)
      row['counter'] = 401 + index
      row
    end

    def dynamic_json_sql(index)
      json = JSON.generate(dynamic_json_row(index))
      "CAST(CAST(#{quote_sql(json)}, #{quote_sql(JSON_TYPE)}), #{quote_sql(DYNAMIC_TYPE)})"
    end

    def source_value_rows(case_id)
      values = case case_id
               when 'root_dynamic'
                 [dynamic_uint8_sql(17), dynamic_uint8_sql(18), dynamic_uint8_sql(19), dynamic_uint8_sql(20), dynamic_json_sql(0), dynamic_json_sql(1)]
               when 'array_dynamic'
                 [array_dynamic_sql([]), array_dynamic_sql([]), array_dynamic_sql([17, 18]), array_dynamic_sql([19]),
                  array_dynamic_sql([{'json_index' => 0}]), array_dynamic_sql([{'json_index' => 1}])]
               when 'root_object'
                 (0...6).map { |index| "CAST(#{quote_sql(JSON.generate(object_row(index)))}, #{quote_sql(JSON_TYPE)})" }
               else
                 fail_w253!("unknown source case #{case_id.inspect}")
               end
      values.each_with_index.map { |value, index| "(#{index + 1}, #{value})" }
    end

    def json_projection(base, path)
      "(#{base}).#{identifier(path)}"
    end

    def value_queries(table_name, case_id)
      if case_id == 'root_object'
        fields = RAW_PATHS.map do |path|
          path == 'maybe' ? "toString(isNull(payload.#{identifier(path)}))" : "toString(payload.#{identifier(path)})"
        end
        DYNAMIC_PATHS.drop(1).each do |path|
          fields << "hex(dynamicType(payload.#{identifier(path)}))"
          fields << "toString(payload.#{identifier(path)})"
        end
        query = "SELECT '__W252_OBJECT_VALUES__', '#{table_name}', toString(pk), hex(toTypeName(payload)), #{fields.join(', ')} FROM default.#{table_name} ORDER BY pk FORMAT TSVRaw;"
      elsif case_id == 'root_dynamic'
        base = "dynamicElement(payload, #{quote_sql(JSON_TYPE)})"
        guard = "dynamicType(payload) = #{quote_sql(JSON_TYPE)}"
        fields = RAW_PATHS.map do |path|
          expression = json_projection(base, path)
          path == 'maybe' ? "if(#{guard}, toString(isNull(#{expression})), '-')" : "if(#{guard}, toString(#{expression}), '-')"
        end
        DYNAMIC_PATHS.each do |path|
          expression = json_projection(base, path)
          fields << "if(#{guard}, hex(dynamicType(#{expression})), '-')"
          fields << "if(#{guard}, toString(#{expression}), '-')"
        end
        query = "SELECT '__W252_DYNAMIC_VALUES__', '#{table_name}', toString(pk), hex(dynamicType(payload)), #{fields.join(', ')} FROM default.#{table_name} ORDER BY pk SETTINGS print_pretty_type_names=0 FORMAT TSVRaw;"
      else
        fields = ["arrayStringConcat(arrayMap(x -> hex(dynamicType(x)), payload), ',')"]
        RAW_PATHS.each do |path|
          expression = json_projection("dynamicElement(x, #{quote_sql(JSON_TYPE)})", path)
          projected = path == 'maybe' ? "toString(isNull(#{expression}))" : "toString(#{expression})"
          fields << "arrayStringConcat(arrayMap(x -> if(dynamicType(x) = #{quote_sql(JSON_TYPE)}, #{projected}, '-'), payload), ',')"
        end
        DYNAMIC_PATHS.each do |path|
          expression = json_projection("dynamicElement(x, #{quote_sql(JSON_TYPE)})", path)
          fields << "arrayStringConcat(arrayMap(x -> if(dynamicType(x) = #{quote_sql(JSON_TYPE)}, hex(dynamicType(#{expression})), '-'), payload), ',')"
          fields << "arrayStringConcat(arrayMap(x -> if(dynamicType(x) = #{quote_sql(JSON_TYPE)}, toString(#{expression}), '-'), payload), ',')"
        end
        query = "SELECT '__W252_DYNAMIC_VALUES__', '#{table_name}', toString(pk), #{fields.join(', ')} FROM default.#{table_name} ORDER BY pk SETTINGS print_pretty_type_names=0 FORMAT TSVRaw;"
      end
      [query,
       "SELECT '__W252_ZERO_BEGIN__', '#{table_name}', '#{@profile}', 'values' FORMAT TSVRaw;",
       "SELECT '__W252_ZERO_ROW__', '#{table_name}', toString(pk) FROM default.#{table_name} WHERE pk > 6 ORDER BY pk FORMAT TSVRaw;",
       "SELECT '__W252_ZERO_END__', '#{table_name}', '#{@profile}', 'values' FORMAT TSVRaw;"]
    end

    def parse_native(stdout)
      lines = stdout.dup.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
      fail_w253!('native output is not valid UTF-8') unless lines.all?(&:valid_encoding?)
      known = %w[__W252_PIN__ __W252_SCHEMA__ __W252_DATA_PATH__ __W252_PART__ __W252_CHECK_BEGIN__ __W252_CHECK_END__ __W252_OBJECT_VALUES__ __W252_DYNAMIC_VALUES__ __W252_ZERO_BEGIN__ __W252_ZERO_END__ __W252_ZERO_ROW__]
      unknown = lines.select { |line| line.start_with?('__W252_') }.map { |line| line.split("\t", 2).first }.uniq - known
      fail_w253!("unknown native marker tags #{unknown.inspect}") unless unknown.empty?
      records = ->(tag) { lines.select { |line| line.start_with?("#{tag}\t") }.map { |line| line.split("\t", -1) } }
      pins = records.call('__W252_PIN__')
      fail_w253!('native pin row shape differs') unless pins.size == 1 && pins.first.size == 3
      schemas = records.call('__W252_SCHEMA__').map do |fields|
        fail_w253!('native schema row width differs') unless fields.size == 4
        fields.drop(1)
      end
      path_rows = records.call('__W252_DATA_PATH__')
      paths = path_rows.to_h do |fields|
        fail_w253!('native data-path row width differs') unless fields.size == 3
        [fields[1], fields[2]]
      end
      part_rows = records.call('__W252_PART__')
      parts = part_rows.to_h do |fields|
        fail_w253!('native part row width differs') unless fields.size == 7
        [fields[1], {name: fields[2], path: fields[3], type: fields[4], rows: fields[5], marks: fields[6]}]
      end
      fail_w253!('native data-path rows contain duplicates') unless path_rows.map { |fields| fields[1] }.uniq.size == path_rows.size
      fail_w253!('native part rows contain duplicates') unless part_rows.map { |fields| fields[1] }.uniq.size == part_rows.size
      check_blocks = {}
      active = nil
      lines.each do |line|
        if line.start_with?("__W252_CHECK_BEGIN__\t")
          fields = line.split("\t", -1)
          fail_w253!('CHECK begin boundary malformed or nested') unless fields.size == 2 && !active
          active = fields[1]
          fail_w253!('duplicate CHECK block') if check_blocks.key?(active)
          check_blocks[active] = []
        elsif line.start_with?("__W252_CHECK_END__\t")
          fields = line.split("\t", -1)
          fail_w253!('CHECK end boundary malformed') unless fields.size == 2 && active == fields[1]
          active = nil
        elsif active
          check_blocks.fetch(active) << line
        end
      end
      fail_w253!('unterminated CHECK block') if active
      value_rows = records.call('__W252_OBJECT_VALUES__').map { |fields| ['object', fields.drop(1)] }
      value_rows.concat(records.call('__W252_DYNAMIC_VALUES__').map { |fields| ['dynamic', fields.drop(1)] })
      values = Hash.new { |hash, key| hash[key] = [] }
      value_rows.each do |kind, fields|
        expected_width = kind == 'object' ? 13 : 15
        fail_w253!("#{kind} native value row width differs") unless fields.size == expected_width
        values[[fields[0], kind]] << fields.drop(1)
      end
      zero_events = lines.select { |line| line.start_with?("__W252_ZERO_BEGIN__\t") || line.start_with?("__W252_ZERO_END__\t") }.map { |line| line.split("\t", -1) }
      zero_rows = records.call('__W252_ZERO_ROW__')
      {pin: pins.first, schemas: schemas, data_paths: paths, parts: parts, checks: check_blocks,
       values: values, zero_events: zero_events, zero_rows: zero_rows}
    end

    def expected_dynamic_rows(case_id)
      uint_hex = UINT8_TYPE.unpack1('H*').upcase
      json_hex = JSON_TYPE.unpack1('H*').upcase
      int_hex = INT64_TYPE.unpack1('H*').upcase
      if case_id == 'root_dynamic'
        (17..20).each_with_index.map { |value, index| [index + 1, uint_hex] + Array.new(12, '-') }.map { |row| row.map(&:to_s) } + [
          ['5', json_hex, '17', '23', '31', '41', '1', '42', int_hex, '401', int_hex, '51', int_hex, '61'],
          ['6', json_hex, '18', '24', '32', '42', '1', '43', int_hex, '402', int_hex, '52', int_hex, '62'],
        ]
      else
        [
          ['1'] + Array.new(13, ''),
          ['2'] + Array.new(13, ''),
          ['3', [uint_hex, uint_hex].join(',')] + Array.new(12, '-,-'),
          ['4', uint_hex] + Array.new(12, '-'),
          ['5', json_hex, '17', '23', '31', '41', '1', '42', int_hex, '401', int_hex, '51', int_hex, '61'],
          ['6', json_hex, '18', '24', '32', '42', '1', '43', int_hex, '402', int_hex, '52', int_hex, '62'],
        ]
      end
    end

    def expected_object_rows
      type_hex = JSON_TYPE.unpack1('H*').upcase
      int_hex = INT64_TYPE.unpack1('H*').upcase
      (0...6).map do |index|
        [(index + 1).to_s, type_hex, (17 + index).to_s, (23 + index).to_s,
         (31 + index).to_s, (41 + index).to_s, '1', (42 + index).to_s,
         int_hex, (51 + index).to_s, int_hex, (61 + index).to_s]
      end
    end

    def assert_values!(native, table_names)
      table_names.each do |name|
        case_id = @table_identity.fetch(name).first
        if case_id == 'root_object'
          actual = native[:values].fetch([name, 'object'], [])
          expected = expected_object_rows
          fail_w253!("#{name} raw Object typed/dynamic path values differ: #{actual.inspect}") unless actual == expected
        else
          actual = native[:values].fetch([name, 'dynamic'], [])
          expected = expected_dynamic_rows(case_id)
          fail_w253!("#{name} Dynamic JSON path/value/type rows differ: #{actual.inspect}") unless actual == expected
        end
      end
      expected_keys = table_names.map { |name| [name, @table_identity.fetch(name).first == 'root_object' ? 'object' : 'dynamic'] }.sort
      fail_w253!('native value query roster differs') unless native[:values].keys.sort == expected_keys
    end

    def build_helper_input
      capture_root = File.realpath(File.join(@root, 'stores', 'native'))
      cases = CASE_IDS.map do |case_id|
        {
          'case_id' => case_id, 'profile_id' => @profile, 'capture_root' => capture_root,
          'version' => @dynamic_version,
          'source_part' => @source_parts.fetch(table(case_id, 'source')),
          'library_part' => File.join(@root, 'generated', case_id, @profile, 'all_1_1_0'),
        }
      end
      {'format' => FORMAT_INPUT, 'dynamic_version' => @dynamic_version,
       'profile_id' => @profile, 'capture_root' => capture_root, 'cases' => cases}
    end

    def expected_helper_rows(case_id)
      json1 = 'json[17,23,31,41,null,42;counter=401;secretary=51;zz=61]'
      json2 = 'json[18,24,32,42,null,43;counter=402;secretary=52;zz=62]'
      case case_id
      when 'root_dynamic' then [['u8:17', 'u8:18'], ['u8:19', 'u8:20'], [json1, json2]]
      when 'array_dynamic' then [['[]', '[]'], ['[u8:17|u8:18]', '[u8:19]'], ["[#{json1}]", "[#{json2}]"]]
      when 'root_object'
        (0...6).map { |index| [(17 + index), (23 + index), (31 + index), (41 + index), 'null', (42 + index), (51 + index), (61 + index)].join(',') }.each_slice(2).map(&:to_a)
      else fail_w253!("unknown helper case #{case_id.inspect}")
      end
    end

    def run_helper(input_path)
      before = helper_sha
      fail_w253!('prebuilt helper changed before invocation') unless before == @helper_sha_before
      argv = [@helper, input_path, File.join(@root, 'generated')]
      invocation = @executor.send(:execute_record, 'crystal_helper', argv, ''.b,
                                  'prebuilt W253 Crystal helper', before, @helper)
      fail_w253!('Crystal helper process failed') unless send(:successful?, invocation)
      fail_w253!('Crystal helper emitted stderr') unless invocation[:stderr].empty?
      fail_w253!('Crystal helper changed during invocation') unless helper_sha == before
      lines = invocation[:stdout].lines.map(&:chomp).reject(&:empty?)
      fail_w253!('Crystal helper must emit exactly one JSON record') unless lines.size == 1
      data = JSON.parse(lines.first)
      fail_w253!('Crystal helper output format differs') unless data['format'] == FORMAT_HELPER
      @invocations << invocation[:record]
      {data: data, record: invocation[:record]}
    end

    def assert_helper_output!(data)
      root_keys = %w[case_ids cases dynamic_version dynamic_version_wire format json_child_mark_rows parent_mark_rows profile_id]
      fail_w253!('helper output keys/format differ') unless data.keys.sort == root_keys && data['format'] == FORMAT_HELPER
      expected_wire = @dynamic_version == 'v1' ? 1 : 2
      fail_w253!('helper version/profile/P contract differs') unless data['dynamic_version'] == @dynamic_version && data['dynamic_version_wire'] == expected_wire &&
        data['profile_id'] == @profile && data['case_ids'] == CASE_IDS && data['parent_mark_rows'] == PARENT_MARK_ROWS && data['json_child_mark_rows'] == JSON_CHILD_MARK_ROWS
      cases = data.fetch('cases')
      fail_w253!('helper case roster/order differs') unless cases.map { |item| item.fetch('case_id') } == CASE_IDS
      expected_side_keys = %w[case_id profile_id schema_declaration row_count mark_count mark_row_counts rows_by_mark physical_stream_names selected_checksum_names object_child_stream_names bound_json_type_names structure_audits owned_values offline_values windows].sort
      cases.each do |item|
        case_id = item.fetch('case_id')
        expected_path = File.join(@root, 'generated', case_id, @profile, 'all_1_1_0')
        fail_w253!("#{case_id} helper case keys/path differ") unless item.keys.sort == %w[case_id library library_part_path profile_id source] && item['profile_id'] == @profile && File.expand_path(item['library_part_path']) == expected_path
        %w[source library].each do |origin|
          side = item.fetch(origin)
          fail_w253!("#{case_id}/#{origin} helper keys differ") unless side.keys.sort == expected_side_keys
          fail_w253!("#{case_id}/#{origin} helper nominal/value/P census differs") unless side['case_id'] == case_id && side['profile_id'] == @profile &&
            side['schema_declaration'] == table_type(case_id) && side['row_count'] == 6 && side['mark_count'] == 3 &&
            side['mark_row_counts'] == PARENT_MARK_ROWS && side['rows_by_mark'] == expected_helper_rows(case_id)
          fail_w253!("#{case_id}/#{origin} physical name report is malformed") unless side['physical_stream_names'].is_a?(Array) && side['physical_stream_names'].uniq == side['physical_stream_names'] &&
            side['selected_checksum_names'].is_a?(Array) && side['selected_checksum_names'].uniq == side['selected_checksum_names'] &&
            side['object_child_stream_names'].is_a?(Array) && side['bound_json_type_names'].is_a?(Array) && side['structure_audits'].is_a?(Array)
          expected_audit_count = if case_id == 'root_object'
                                   2
                                 elsif origin == 'source'
                                   4
                                 else
                                   7
                                 end
          audits = side['structure_audits']
          fail_w253!("#{case_id}/#{origin} Dynamic structure audit count differs") unless audits.size == expected_audit_count
          if case_id == 'root_object'
            expected_sites = OBJECT_DYNAMIC_PATHS.map { |path| "root_object/#{path}" }
            fail_w253!("#{case_id}/#{origin} Object Dynamic audit site roster differs") unless audits.map { |audit| audit['site'] } == expected_sites
            audits.each do |audit|
              expected_legacy = @dynamic_version == 'v1' ? 1 : nil
              fail_w253!("#{case_id}/#{origin} Object Dynamic raw/decoded roster differs") unless audit['version'] == expected_wire &&
                audit['legacy_max_dynamic_types'] == expected_legacy && audit['types'] == ['Int64'] &&
                audit['canonical_variant_names'].size == 2 && audit.dig('statistics', 'counts') == [6, 0] &&
                audit.dig('statistics', 'shared') == []
            end
            fail_w253!("#{case_id}/#{origin} offline rows differ") unless side['offline_values'] == expected_helper_rows(case_id).flatten && side['owned_values'].nil?
          else
            fail_w253!("#{case_id}/#{origin} Dynamic offline-values field should be null") unless side['offline_values'].nil?
            owned = side['owned_values']
            fail_w253!("#{case_id}/#{origin} owned-values census differs") unless owned.is_a?(Hash) && owned['schema_declaration'] == table_type(case_id) &&
              owned['row_count'] == 6 && owned['mark_row_counts'] == PARENT_MARK_ROWS && owned['values_by_mark'] == expected_helper_rows(case_id)
          end
        end
        library_path = item.fetch('library_part_path')
        send(:validate_plain_tree!, library_path)
        @library_parts[case_id] = library_path
        @library_snapshots[case_id] = send(:snapshot_part, library_path)
      end
    end

    def write_summary(status)
      return unless @root && File.directory?(@root) && File.directory?(File.join(@root, 'invocations'))
      summary = {
        'format' => FORMAT_CAPTURE, 'status' => status, 'fatal_error' => @fatal_error,
        'scope' => {
          'dynamic_version' => @dynamic_version, 'dynamic_version_wire' => (@dynamic_version == 'v1' ? 1 : 2),
          'string_profile' => @profile, 'helper_mode' => @helper_mode, 'case_ids' => CASE_IDS,
          'claim' => 'finite JSON SKIP metadata and persisted value witness: root Dynamic, Array(Dynamic), and root Object only',
          'typed_raw_paths' => RAW_PATHS, 'skip_raw_paths' => %w[secret z], 'dot_setting' => 'json_type_escape_dots_in_keys=0',
          'dynamic_raw_paths' => DYNAMIC_PATHS, 'dynamic_child_type' => INT64_TYPE,
          'parent_mark_rows' => PARENT_MARK_ROWS, 'json_child_mark_rows' => JSON_CHILD_MARK_ROWS,
          'unused_json_arm' => 'library-generated Dynamic parent only',
        },
        'runtime' => {'path' => @binary, 'expected_sha256' => W210::BINARY_SHA256,
                      'sha256_before' => @binary_sha_before, 'sha256_after' => @binary_sha_after,
                      'expected_version' => W210::VERSION, 'expected_version_git_hash' => W210::BUILD},
        'helper' => {'path' => @helper, 'mode' => @helper_mode,
                     'sha256_before' => @helper_sha_before, 'sha256_after' => @helper_sha_after,
                     'source_path' => File.expand_path('check_json_skip_paths_w253.cr', __dir__),
                     'source_sha256' => source_pin_for(File.expand_path('check_json_skip_paths_w253.cr', __dir__))},
        'harness_source_pins' => {'before' => @source_pins_before, 'after' => @source_pins_after},
        'helper_input' => @helper_input, 'helper_output' => @helper_output,
        'invocations' => @invocations,
        'native' => {'initial' => (@native_initial && normalized_native(@native_initial)),
                     'attached' => (@native_attached && normalized_native(@native_attached))},
        'parts' => {'source_paths' => @source_parts, 'library_paths' => @library_parts,
                    'source_snapshots' => @source_snapshots, 'library_snapshots' => @library_snapshots},
        'limits' => {'max_threads' => 1, 'local_max_memory_usage_bytes' => W210::MEMORY,
                     'required_outer_run_safe_memory_limit_bytes' => W210::OUTER_RUN_SAFE_LIMIT,
                     'timeout_seconds' => W210::TIMEOUT, 'termination_grace_seconds' => W210::GRACE,
                     'executor' => 'JsonBinaryKernelW180Probe#execute'},
      }
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n") unless File.exist?(File.join(@root, 'summary.json'))
      write_new(File.join(@root, 'summary.md'), [
        '# W253 JSON SKIP path compatibility', '', "Status: `#{status}`", '',
        "Scope: `#{@dynamic_version}` / `#{@profile}`, cases #{CASE_IDS.join(', ')}. SKIP metadata is `secret,z`; persisted parts independently retain `secretary` and `zz`. Typed values distinguish nested `a.b` from literal `a%2Eb` with `json_type_escape_dots_in_keys=0`. This finite witness does not claim every JSON layout or SKIP text-ingest behavior.", '',
        "Runtime: #{W210::VERSION} / VERSION_GITHASH #{W210::BUILD} / SHA256 `#{W210::BINARY_SHA256}`", '',
        "Evidence root: `#{@root}`", '',
      ].join("\n")) unless File.exist?(File.join(@root, 'summary.md'))
    end

    def source_pin_for(path)
      @source_pins_before&.find { |item| item['path'] == path }&.fetch('sha256')
    end
  end

  if $PROGRAM_NAME == __FILE__
    options = {binary: W210::BINARY, helper: nil, root: nil, dynamic_version: nil, helper_mode: nil}
    OptionParser.new do |parser|
      parser.banner = 'Usage: ruby scripts/probe_json_skip_paths_w253.rb --dynamic-version v1|v2 --helper-mode debug|release --crystal-helper PREBUILT --evidence-root EMPTY_/private/tmp_CHILD [--clickhouse PINNED]'
      parser.on('--clickhouse PATH', 'Pinned ClickHouse executable') { |value| options[:binary] = value }
      parser.on('--crystal-helper PATH', 'Prebuilt W253 Crystal helper; this runner never compiles it') { |value| options[:helper] = value }
      parser.on('--evidence-root PATH', 'Existing empty direct child of /private/tmp') { |value| options[:root] = value }
      parser.on('--dynamic-version VERSION', 'One pair: v1/single_stream or v2/with_size_stream') { |value| options[:dynamic_version] = value }
      parser.on('--helper-mode MODE', 'Prebuilt Crystal helper mode: debug or release') { |value| options[:helper_mode] = value }
    end.parse!
    abort 'W253: --dynamic-version, --helper-mode, --crystal-helper and --evidence-root are required' unless
      options[:helper] && options[:root] && options[:dynamic_version] && options[:helper_mode]
    exit(Probe.new(options[:binary], options[:helper], options[:root], options[:dynamic_version], options[:helper_mode]).run ? 0 : 1)
  end
end
