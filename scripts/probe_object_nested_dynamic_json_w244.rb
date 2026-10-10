#!/usr/bin/env ruby
# Narrow W244 generated-part/native-reader qualification for a JSON-bearing
# actual selected inside a real nested Dynamic Array element.
#
# This is one-way evidence: Crystal writes one advanced_s0 part and the pinned
# stock runtime attaches and reads it. Dynamic type/value observations are the
# primary oracle. isDynamicElementInSharedData is recorded only as query-column
# placement diagnostics; it is not treated as persisted per-mark roster proof.

require 'digest'
require 'fileutils'
require 'json'
require 'optparse'
require 'find'
require_relative 'probe_object_shared_json_interop_w241'

module ProbeObjectNestedDynamicJSONW244
  W241 = ProbeObjectSharedJSONInteropW241

  FORMAT = 'object_nested_dynamic_json_w244_native_capture_v1'.freeze
  HELPER_INPUT_FORMAT = 'object_nested_dynamic_json_w244_input_v1'.freeze
  HELPER_OUTPUT_FORMAT = 'object_nested_dynamic_json_w244_helper_v1'.freeze
  HELPER_SOURCE = File.expand_path('check_object_nested_dynamic_json_w244.cr', __dir__).freeze
  HELPER_SOURCE_SHA256 = '0a83bf1cae58a920f0d0a3e5b3e2a38169ab9bb8d232a63ddeb15715d5a62af2'.freeze
  FRAME_BYTES = 32
  ROW_COUNT = 4
  MARK_ROWS = [2, 2].freeze
  MARK_ROWS_WITH_EOF = [2, 2, 0].freeze
  PHYSICAL_MARKS = MARK_ROWS_WITH_EOF.size

  OUTER_ACTUAL_TYPE = 'Tuple(JSON(max_dynamic_types=2, max_dynamic_paths=1, v UInt8), Array(Dynamic(max_types=1)))'.freeze
  OUTER_JSON_TYPE = 'JSON(max_dynamic_types=2, max_dynamic_paths=1, v UInt8)'.freeze
  INNER_ARRAY_TYPE = 'Array(Dynamic(max_types=1))'.freeze
  INNER_ACTUAL_TYPE = 'Tuple(JSON(max_dynamic_types=0, max_dynamic_paths=0, v Int64), UInt8)'.freeze
  INNER_JSON_TYPE = 'JSON(max_dynamic_types=0, max_dynamic_paths=0, v Int64)'.freeze
  OUTER_NESTED_SITE = 'root.arm.1.field.1.elements'.freeze
  STOCK_TYPE = W241::STOCK_TYPE

  EXPECTED_DOCS = [
    {'pk' => 1, 'doc' => {'payload' => [{'v' => 7}, [[{'v' => 7}, 9], 'spill', nil]]}},
    {'pk' => 2, 'doc' => {'payload' => [{'v' => 7}, []]}},
    {'pk' => 3, 'doc' => {'payload' => [{'v' => 7}, ['ordinary', nil]]}},
    {'pk' => 4, 'doc' => {'payload' => [{'v' => 7}, []]}},
  ].freeze
  EXPECTED_ITEM_TYPES = {
    1 => [INNER_ACTUAL_TYPE, 'String', 'NULL'],
    2 => [],
    3 => ['String', 'NULL'],
    4 => [],
  }.freeze
  EXPECTED_MARK_WINDOWS = {
    'first' => {'first_mark' => 0, 'mark_count' => 1, 'pks' => [1, 2]},
    'last' => {'first_mark' => 1, 'mark_count' => 1, 'pks' => [3, 4]},
    'zero_count_end' => {'first_mark' => 2, 'mark_count' => 0, 'pks' => []},
  }.freeze

  PATH_TAG = '__W244_PATH__'.freeze
  CHECK_BEGIN_TAG = '__W244_CHECK_BEGIN__'.freeze
  CHECK_END_TAG = '__W244_CHECK_END__'.freeze
  SCHEMA_TAG = '__W244_SCHEMA__'.freeze
  PART_TAG = '__W244_PART__'.freeze
  TYPE_TAG = '__W244_TYPE__'.freeze
  CHILD_TAG = '__W244_CHILD__'.freeze
  FULL_TAG = '__W244_FULL__'.freeze
  WINDOW_TAG = '__W244_WINDOW__'.freeze
  PLACEMENT_TAG = '__W244_PLACEMENT__'.freeze

  class Failure < StandardError; end

  class Probe
    def initialize(binary, helper, evidence_root)
      @binary = validate_executable(binary, 'ClickHouse')
      @helper = validate_executable(helper, 'Crystal helper')
      @root = validate_root(evidence_root)
      @token = Digest::SHA256.hexdigest(@root)[0, 8]
      @runner = W241::Probe.new(@binary, @helper, @root, FRAME_BYTES)
      @invocations = @runner.instance_variable_get(:@invocations)
      @table = "w244_#{@token}_advanced_s0"
      @fatal_error = nil
    end

    def run
      prepare_tree!
      @runtime_sha_before = Digest::SHA256.file(@binary).hexdigest
      require_true(@runtime_sha_before == W241::BINARY_SHA256, 'runtime SHA differs from the pinned ClickHouse executable')
      @helper_sha_before = Digest::SHA256.file(@helper).hexdigest
      @helper_source_sha_before = Digest::SHA256.file(HELPER_SOURCE).hexdigest
      require_true(@helper_source_sha_before == HELPER_SOURCE_SHA256, 'helper source SHA differs from its frozen pin')

      capture_generated_part!
      create_native_table!
      attach_and_check!
      capture_native_oracles!
      assert_unchanged_parts!

      @runtime_sha_after = Digest::SHA256.file(@binary).hexdigest
      @helper_sha_after = Digest::SHA256.file(@helper).hexdigest
      @helper_source_sha_after = Digest::SHA256.file(HELPER_SOURCE).hexdigest
      require_true(@runtime_sha_after == W241::BINARY_SHA256, 'runtime SHA changed during capture')
      require_true(@helper_sha_after == @helper_sha_before, 'helper executable changed during capture')
      require_true(@helper_source_sha_after == HELPER_SOURCE_SHA256, 'helper source changed during capture')

      summary = build_summary('library_written_native_read_observed', nil)
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      puts "W244 status=library_written_native_read_observed; profile=advanced_s0; rows=#{ROW_COUNT}; frame_bytes=#{FRAME_BYTES}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      @runtime_sha_after = Digest::SHA256.file(@binary).hexdigest rescue nil
      @helper_sha_after = Digest::SHA256.file(@helper).hexdigest rescue nil
      @helper_source_sha_after = Digest::SHA256.file(HELPER_SOURCE).hexdigest rescue nil
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(build_summary('capture_failure_inconclusive', @fatal_error)) + "\n") rescue nil
      warn "W244 generated/native oracle incomplete: #{@fatal_error}"
      false
    end

    private

    def require_true(condition, message)
      raise Failure, "W244: #{message}" unless condition
    end

    def validate_executable(path, label)
      require_true(path.is_a?(String) && !path.empty?, "#{label} path is required")
      expanded = File.expand_path(path)
      require_true(File.file?(expanded) && File.executable?(expanded) && !File.symlink?(expanded),
                   "#{label} must be a regular executable, not a symlink")
      expanded
    end

    def validate_root(path)
      require_true(path.is_a?(String) && !path.empty?, 'evidence root is required')
      expanded = File.expand_path(path)
      require_true(File.dirname(expanded) == File.realpath('/private/tmp') &&
                   File.directory?(expanded) && !File.symlink?(expanded) &&
                   File.realpath(expanded) == expanded && Dir.children(expanded).empty?,
                   'evidence root must be an empty canonical direct child of /private/tmp')
      expanded
    rescue Errno::ENOENT
      raise Failure, 'evidence root must already exist'
    end

    def prepare_tree!
      %w[invocations stores parts generated].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      Dir.mkdir(File.join(@root, 'stores', 'native'), 0o700)
    end

    def write_new(path, bytes)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(bytes) }
    end

    def capture_generated_part!
      @helper_input = JSON.generate({'format' => HELPER_INPUT_FORMAT, 'frame_bytes' => FRAME_BYTES}) + "\n"
      input_path = File.join(@root, 'invocations', 'helper_input.json')
      write_new(input_path, @helper_input)
      helper_sha = Digest::SHA256.file(@helper).hexdigest
      invocation = @runner.send(:run_process, 'crystal_helper', [@helper, input_path, File.join(@root, 'generated')],
                                ''.b, 'crystal-helper', expected_sha: helper_sha, binary_path: @helper)
      require_process_success!(invocation, 'Crystal helper')
      output = JSON.parse(invocation.fetch(:stdout))
      validate_helper_output!(output, input_path)
      @helper_invocation = invocation.fetch(:record)
      @helper_output_sha256 = Digest::SHA256.hexdigest(invocation.fetch(:stdout))
      @helper_data = output
      @source_part = File.join(@root, 'generated', 'advanced_s0')
      @source_snapshot = part_snapshot(@source_part)
      @physical_mark_tuples = read_physical_mark_tuples(@source_part)
      @helper_record = {
        'input_sha256' => Digest::SHA256.hexdigest(@helper_input),
        'output_sha256' => @helper_output_sha256,
        'input_path' => input_path,
        'helper_executable_sha256' => helper_sha,
        'helper_source_sha256' => @helper_source_sha_before,
        'invocation_label' => 'crystal_helper',
      }
    end

    def validate_helper_output!(data, input_path)
      exact_keys!(data, %w[format input_sha256 output_root frame_bytes profile_id row_count mark_row_counts part], 'helper output')
      require_true(data.fetch('format') == HELPER_OUTPUT_FORMAT, 'helper output format differs')
      require_true(data.fetch('input_sha256') == Digest::SHA256.hexdigest(@helper_input), 'helper input digest differs')
      require_true(data.fetch('output_root') == File.join(@root, 'generated') && File.directory?(data.fetch('output_root')),
                   'helper output root differs')
      require_true(File.file?(input_path), 'helper input file disappeared')
      require_true(data.fetch('frame_bytes') == FRAME_BYTES && data.fetch('profile_id') == 'advanced_s0',
                   'helper profile/frame differs')
      require_true(data.fetch('row_count') == ROW_COUNT && data.fetch('mark_row_counts') == MARK_ROWS,
                   'helper row/mark domain differs')
      part = data.fetch('part')
      exact_keys!(part, %w[
        path schema_declaration columns_text count_text count shared_version bucket_count mark_row_counts
        physical_file_inventory full_rows payload_rows nested_type_witnesses bounded_windows
        outer_actual_type nested_actual_type nested_dynamic_type nested_site nested_json_type
      ], 'helper part')
      require_true(part.fetch('path') == File.join(@root, 'generated', 'advanced_s0') &&
                   part.fetch('schema_declaration') == STOCK_TYPE && part.fetch('count') == ROW_COUNT &&
                   part.fetch('count_text').strip == ROW_COUNT.to_s &&
                   part.fetch('shared_version') == 2 && part.fetch('bucket_count') == 1 &&
                   part.fetch('mark_row_counts') == MARK_ROWS,
                   'helper part identity/layout differs')
      require_true(part.fetch('outer_actual_type') == OUTER_ACTUAL_TYPE &&
                   part.fetch('nested_actual_type') == INNER_ACTUAL_TYPE &&
                   part.fetch('nested_dynamic_type') == 'Dynamic(max_types=1)' &&
                   part.fetch('nested_site') == OUTER_NESTED_SITE &&
                   part.fetch('nested_json_type') == INNER_JSON_TYPE,
                   'helper recursive descriptor/site witness differs')
      require_true(part.fetch('full_rows') == EXPECTED_DOCS, 'helper full Object rows differ from literal fixture')
      require_true(part.fetch('nested_type_witnesses').size == ROW_COUNT, 'helper nested type witness count differs')
      require_true(part.fetch('bounded_windows').map { |window| window.fetch('window') } == EXPECTED_MARK_WINDOWS.keys,
                   'helper bounded-window roster differs')
      expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`doc` #{STOCK_TYPE}\n"
      require_true(part.fetch('columns_text') == expected_columns, 'helper physical columns differ')
      true
    rescue KeyError, TypeError => error
      raise Failure, "W244 helper output malformed: #{error.class}: #{error.message}"
    end

    def exact_keys!(hash, keys, label)
      require_true(hash.is_a?(Hash) && hash.keys.sort == keys.sort, "#{label} key set differs")
    end

    def create_native_table!
      profile = W241::PROFILES.find { |candidate| candidate.fetch(:id) == 'advanced_s0' } || raise(Failure, 'advanced_s0 profile is absent')
      store = File.join(@root, 'stores', 'native')
      path_tag = PATH_TAG
      sql = [
        "CREATE TABLE default.#{@table} (pk UInt64, doc #{STOCK_TYPE}) ENGINE=MergeTree ORDER BY pk SETTINGS #{@runner.send(:settings, profile)};",
        "SELECT '#{path_tag}', database, name, arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{@table}' FORMAT TSVRaw;",
      ].join("\n")
      invocation = native_stage('native_create_table', store, sql)
      rows = tagged_rows(invocation.fetch(:stdout), PATH_TAG, 4)
      require_true(rows.size == 1 && rows.first.values_at(1, 2) == ['default', @table], 'native table/path binding differs')
      @data_path = @runner.send(:validate_store_path!, rows.first.fetch(3))
      @runner.send(:attach_part!, @source_part, @data_path)
      @copied_part = File.join(@data_path, 'detached', 'all_1_1_0')
      @copied_snapshot = part_snapshot(@copied_part)
      require_true(@copied_snapshot == @source_snapshot, 'copied part differs from generated source')
      @create_record = invocation.fetch(:record)
    end

    def attach_and_check!
      sql = [
        "ALTER TABLE default.#{@table} ATTACH PART 'all_1_1_0';",
        "SELECT '#{CHECK_BEGIN_TAG}', 'advanced_s0' FORMAT TSVRaw;",
        "CHECK TABLE default.#{@table} FORMAT TSV;",
        "SELECT '#{CHECK_END_TAG}', 'advanced_s0' FORMAT TSVRaw;",
        "SELECT '#{SCHEMA_TAG}', name, type FROM system.columns WHERE database='default' AND table='#{@table}' ORDER BY position FORMAT TSVRaw;",
        "SELECT '#{PART_TAG}', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table='#{@table}' AND active ORDER BY name FORMAT TSVRaw;",
      ].join("\n")
      invocation = native_stage('native_attach_check', File.join(@root, 'stores', 'native'), sql)
      checks = check_rows(invocation.fetch(:stdout))
      require_true(checks == ["all_1_1_0\t1\t"], 'native CHECK result differs')
      schemas = tagged_rows(invocation.fetch(:stdout), SCHEMA_TAG, 3)
      require_true(schemas.map { |row| row.drop(1) } == [['pk', 'UInt64'], ['doc', STOCK_TYPE]], 'attached schema differs')
      parts = tagged_rows(invocation.fetch(:stdout), PART_TAG, 7)
      require_true(parts.size == 1 && parts.first.values_at(1, 2, 4, 5, 6) ==
                   [@table, 'all_1_1_0', 'Wide', ROW_COUNT.to_s, PHYSICAL_MARKS.to_s],
                   'active attached part identity/row/mark counts differ')
      @attached_path = @runner.send(:validate_store_path!, parts.first.fetch(3))
      require_true(attached_snapshot_matches?(@copied_snapshot, @attached_path),
                   'ATTACH modified copied bytes beyond the admitted native metadata exception')
      @attached_snapshot = part_snapshot(@attached_path)
      @check_record = invocation.fetch(:record)
      @attachment_observation = {
        'check_rows' => checks,
        'schema' => schemas.map { |row| row.drop(1) },
        'active_part' => parts.first.drop(1),
        'source_snapshot_sha256' => snapshot_digest(@source_snapshot),
        'copied_snapshot_sha256' => snapshot_digest(@copied_snapshot),
        'attached_snapshot_sha256' => snapshot_digest(@attached_snapshot),
      }
    end

    def capture_native_oracles!
      store = File.join(@root, 'stores', 'native')
      tuple = "assumeNotNull(dynamicElement(doc.payload, #{@runner.send(:sql_string, OUTER_ACTUAL_TYPE)}))"
      type_fields = [
        "toTypeName(doc.payload)",
        "dynamicType(doc.payload)",
        "toTypeName(#{tuple})",
        "toTypeName(#{tuple}.1)",
        "hex(toJSONString(JSONAllPathsWithTypes(#{tuple}.1)))",
        "toTypeName(#{tuple}.2)",
        "hex(toJSONString(arrayMap(x -> if(isNull(x), 'NULL', dynamicType(x)), #{tuple}.2)))",
      ].join(', ')
      type_sql = "SELECT '#{TYPE_TAG}', toString(pk), #{type_fields} FROM default.#{@table} WHERE isNotNull(doc.payload) ORDER BY pk FORMAT TSVRaw;"
      type_invocation = native_stage('native_type_values', store, type_sql)
      type_rows = tagged_rows(type_invocation.fetch(:stdout), TYPE_TAG, 9)
      validate_type_rows!(type_rows)

      inner = "assumeNotNull(dynamicElement(item, #{@runner.send(:sql_string, INNER_ACTUAL_TYPE)}))"
      array_alias = "#{tuple}.2"
      child_sql = "SELECT '#{CHILD_TAG}', toString(pk), toString(item_index), dynamicType(item), " \
                  "toTypeName(#{inner}), toTypeName(#{inner}.1), " \
                  "hex(toJSONString(JSONAllPathsWithTypes(#{inner}.1))), " \
                  "toTypeName(#{inner}.1.v), toString(#{inner}.1.v), " \
                  "toTypeName(#{inner}.2), toString(#{inner}.2) " \
                  "FROM (SELECT pk, #{array_alias} AS nested_array FROM default.#{@table} WHERE isNotNull(doc.payload)) " \
                  "ARRAY JOIN arrayEnumerate(nested_array) AS item_index, nested_array AS item " \
                  "WHERE dynamicType(item) = #{@runner.send(:sql_string, INNER_ACTUAL_TYPE)} " \
                  "ORDER BY pk, item_index FORMAT TSVRaw;"
      child_invocation = native_stage('native_inner_json_child', store, child_sql)
      child_rows = tagged_rows(child_invocation.fetch(:stdout), CHILD_TAG, 11)
      validate_child_rows!(child_rows)

      full_sql = "SELECT '#{FULL_TAG}', toString(pk), toTypeName(doc), hex(toJSONString(doc)) FROM default.#{@table} ORDER BY pk FORMAT TSVRaw;"
      full_invocation = native_stage('native_full_rows', store, full_sql)
      full_rows = tagged_rows(full_invocation.fetch(:stdout), FULL_TAG, 4)
      validate_full_rows!(full_rows)

      windows, window_record = capture_native_windows!(store, tuple)
      placement, placement_record = capture_placement_diagnostics!(store, tuple)
      @native_observations = {
        'type_rows' => type_rows.map { |row| row.drop(1) },
        'child_rows' => child_rows.map { |row| row.drop(1) },
        'full_rows' => full_rows.map { |row| row.drop(1) },
        'windows' => windows,
        'placement_diagnostic' => placement,
        'type_invocation' => type_invocation.fetch(:record).fetch(:label),
        'child_invocation' => child_invocation.fetch(:record).fetch(:label),
        'full_invocation' => full_invocation.fetch(:record).fetch(:label),
        'window_invocation' => window_record.fetch(:label),
        'placement_invocation' => placement_record.fetch(:label),
        'exact_dynamic_type_and_value_checks' => true,
        'nested_json_descriptor_checks' => true,
        'isDynamicElementInSharedData_interpretation' => 'diagnostic query-column placement only; not persisted per-mark roster evidence',
      }
    end

    def validate_type_rows!(rows)
      require_true(rows.size == ROW_COUNT && rows.map { |row| Integer(row.fetch(1), 10) } == (1..ROW_COUNT).to_a,
                   'native root type row domain differs')
      rows.each do |row|
        pk = Integer(row.fetch(1), 10)
        observed_types = parse_hex_json(row.fetch(8), "pk#{pk} nested Dynamic type list")
        require_true(row.values_at(2, 3, 4) == ['Dynamic', OUTER_ACTUAL_TYPE, OUTER_ACTUAL_TYPE] &&
                     row.fetch(5) == OUTER_JSON_TYPE,
                     "root/outer JSON type witness differs at pk #{pk}")
        require_true(parse_hex_json(row.fetch(6), "pk#{pk} outer JSON paths") == {'v' => 'UInt8'},
                     "outer JSON path type differs at pk #{pk}")
        require_true(row.fetch(7) == INNER_ARRAY_TYPE, "nested array type differs at pk #{pk}")
        require_true(observed_types == EXPECTED_ITEM_TYPES.fetch(pk), "nested Dynamic actual roster differs at pk #{pk}")
      end
      true
    rescue KeyError, ArgumentError, TypeError => error
      raise Failure, "native type output malformed: #{error.class}: #{error.message}"
    end

    def validate_child_rows!(rows)
      require_true(rows.size == 1, 'native nested JSON-bearing child row count differs')
      row = rows.first
      require_true(row.values_at(1, 2, 3, 4, 5, 7, 8, 9, 10) ==
                   ['1', '1', INNER_ACTUAL_TYPE, INNER_ACTUAL_TYPE, INNER_JSON_TYPE,
                    'Int64', '7', 'UInt8', '9'] &&
                   parse_hex_json(row.fetch(6), 'nested JSON path types') == {'v' => 'Int64'},
                   'nested JSON/UInt8 exact descriptor/value witness differs')
      true
    rescue KeyError, ArgumentError, TypeError => error
      raise Failure, "native child output malformed: #{error.class}: #{error.message}"
    end

    def validate_full_rows!(rows)
      require_true(rows.size == ROW_COUNT && rows.map { |row| Integer(row.fetch(1), 10) } == (1..ROW_COUNT).to_a,
                   'native full document row domain differs')
      rows.each do |row|
        pk = Integer(row.fetch(1), 10)
        doc = parse_hex_json(row.fetch(3), "full document pk#{pk}")
        require_true(row.fetch(2) == STOCK_TYPE && doc == EXPECTED_DOCS.fetch(pk - 1).fetch('doc'),
                     "native full document differs at pk #{pk}")
      end
      true
    rescue KeyError, ArgumentError, TypeError => error
      raise Failure, "native full output malformed: #{error.class}: #{error.message}"
    end

    def capture_native_windows!(store, tuple)
      statements = EXPECTED_MARK_WINDOWS.map do |name, spec|
        lower = spec.fetch('first_mark') * 2 + 1
        upper = lower + spec.fetch('mark_count') * 2 - 1
        predicate = spec.fetch('mark_count').zero? ? 'pk > 4' : "pk BETWEEN #{lower} AND #{upper}"
        "SELECT '#{WINDOW_TAG}', '#{name}', toString(pk), dynamicType(doc.payload), " \
          "hex(toJSONString(#{tuple}.2)) FROM default.#{@table} WHERE #{predicate} ORDER BY pk FORMAT TSVRaw;"
      end
      invocation = native_stage('native_mark_windows', store, statements.join("\n"))
      rows = tagged_rows(invocation.fetch(:stdout), WINDOW_TAG, 5)
      observations = {}
      EXPECTED_MARK_WINDOWS.each do |name, spec|
        part_rows = rows.select { |row| row.fetch(1) == name }
        require_true(part_rows.map { |row| Integer(row.fetch(2), 10) } == spec.fetch('pks'), "native #{name} row window differs")
        part_rows.each do |row|
          pk = Integer(row.fetch(2), 10)
          require_true(row.fetch(3) == OUTER_ACTUAL_TYPE, "native window outer Dynamic type differs at pk #{pk}")
          expected_array = EXPECTED_DOCS.fetch(pk - 1).fetch('doc').fetch('payload').fetch(1)
          require_true(parse_hex_json(row.fetch(4), "native #{name} pk#{pk} array") == expected_array,
                       "native window nested values differ at pk #{pk}")
        end
        observations[name] = {'pks' => part_rows.map { |row| Integer(row.fetch(2), 10) }, 'row_count' => part_rows.size}
      end
      [observations, invocation.fetch(:record)]
    end

    def capture_placement_diagnostics!(store, tuple)
      statements = EXPECTED_MARK_WINDOWS.reject { |name, _| name == 'zero_count_end' }.map do |name, spec|
        first = spec.fetch('first_mark') * 2 + 1
        last = first + 1
        expression = "arrayMap(x -> if(isNull(x), 'NULL', if(isDynamicElementInSharedData(x), '1', '0')), #{tuple}.2)"
        "SELECT '#{PLACEMENT_TAG}', '#{name}', toString(pk), hex(toJSONString(#{expression})) " \
          "FROM default.#{@table} WHERE pk BETWEEN #{first} AND #{last} ORDER BY pk FORMAT TSVRaw;"
      end
      invocation = native_stage('native_query_column_placement_diagnostic', store, statements.join("\n"))
      rows = tagged_rows(invocation.fetch(:stdout), PLACEMENT_TAG, 4)
      require_true(rows.size == ROW_COUNT, 'placement diagnostic row count differs')
      expected_domain = [['first', 1], ['first', 2], ['last', 3], ['last', 4]]
      require_true(rows.map { |row| [row.fetch(1), Integer(row.fetch(2), 10)] } == expected_domain,
                   'placement diagnostic mark-window row domain differs')
      observations = rows.map do |row|
        pk = Integer(row.fetch(2), 10)
        flags = parse_hex_json(row.fetch(3), 'placement flags')
        expected_width = EXPECTED_DOCS.fetch(pk - 1).fetch('doc').fetch('payload').fetch(1).size
        require_true(flags.is_a?(Array) && flags.size == expected_width && flags.all? { |flag| %w[0 1 NULL].include?(flag) },
                     "placement diagnostic shape differs at pk #{pk}")
        {'window' => row.fetch(1), 'pk' => pk, 'flags' => flags}
      end
      [
        {
          'scope' => 'separate mark-filtered query outputs',
          'meaning' => 'isDynamicElementInSharedData reports in-memory query-column placement and is not persisted per-mark roster proof',
          'observations' => observations,
        },
        invocation.fetch(:record),
      ]
    end

    def native_stage(label, store, sql)
      envelope = [@runner.send(:pin_sql), 'SET print_pretty_type_names=0;',
                  'SET output_format_json_quote_64bit_integers=0;', sql].join("\n")
      invocation = @runner.send(:native, label, store, envelope)
      @runner.send(:assert_native_success!, invocation, label)
      @runner.send(:assert_pin!, invocation.fetch(:stdout), label)
      invocation
    end

    def require_process_success!(invocation, label)
      record = invocation.fetch(:record)
      if record.fetch(:process_kind) == 'clickhouse-local'
        @runner.send(:assert_native_success!, invocation, label)
        @runner.send(:assert_pin!, invocation.fetch(:stdout), label)
      else
        require_true(invocation.fetch(:classification) == 'success' && invocation.fetch(:status)&.success? &&
                     invocation.fetch(:stderr).empty? && record.fetch(:binary_sha_after) == record.fetch(:expected_binary_sha256),
                     "#{label} process failed: #{record.inspect}")
      end
    end

    def tagged_rows(stdout, tag, width)
      stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp).each_with_object([]) do |line, rows|
        next unless line.start_with?(tag + "\t")
        fields = line.split("\t", -1)
        require_true(fields.size == width && fields.first == tag, "malformed #{tag} row")
        rows << fields
      end
    end

    def check_rows(stdout)
      lines = stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
      active = false
      result = []
      lines.each do |line|
        if line == "#{CHECK_BEGIN_TAG}\tadvanced_s0"
          require_true(!active, 'nested CHECK interval')
          active = true
        elsif line == "#{CHECK_END_TAG}\tadvanced_s0"
          require_true(active, 'CHECK end without begin')
          active = false
        elsif active
          result << line
        end
      end
      require_true(!active, 'unterminated CHECK interval')
      result
    end

    def parse_hex_json(value, label)
      require_true(value.is_a?(String) && value.match?(/\A(?:[0-9a-fA-F]{2})*\z/), "#{label} is malformed hex JSON")
      JSON.parse([value].pack('H*'))
    rescue JSON::ParserError => error
      raise Failure, "#{label} contains invalid JSON: #{error.message}"
    end

    def part_snapshot(path)
      require_true(File.directory?(path) && !File.symlink?(path), "part is absent or symlinked: #{path}")
      entries = []
      total = 0
      Find.find(path) do |entry|
        stat = File.lstat(entry)
        require_true(!stat.symlink? && (stat.directory? || stat.file?), "part contains a symlink/special file: #{entry}")
        next if stat.directory?
        require_true(stat.size <= 16 * 1024 * 1024, "part file exceeds size bound: #{entry}")
        total += stat.size
        require_true(total <= 64 * 1024 * 1024, 'part exceeds total byte bound')
        entries << [entry.delete_prefix(path + File::SEPARATOR), stat.size, Digest::SHA256.file(entry).hexdigest]
      end
      entries.sort
    end

    # Capture actual Wide .mrk2 records, including the zero-row terminal
    # sentinel. ObjectColumnReader#mark_row_counts intentionally reports only
    # real marks, so it is not the source of this EOF claim.
    def read_physical_mark_tuples(path)
      names = Dir.children(path).grep(/\.mrk2\z/).sort
      require_true(!names.empty?, 'generated part has no plain .mrk2 mark files')
      names.map do |name|
        file = File.join(path, name)
        stat = File.lstat(file)
        require_true(stat.file? && !stat.symlink? && stat.size <= 16 * 1024 * 1024,
                     "physical mark file is not a bounded regular file: #{name}")
        bytes = File.binread(file)
        require_true(bytes.bytesize == stat.size && !bytes.empty? && (bytes.bytesize % 24).zero?,
                     "physical mark file is not a stable sequence of plain triples: #{name}")
        tuples = bytes.unpack('Q<*').each_slice(3).map(&:dup)
        require_true(tuples.map { |triple| triple.fetch(2) } == MARK_ROWS_WITH_EOF,
                     "physical mark row-count triples differ from #{MARK_ROWS_WITH_EOF.inspect}: #{name}")
        {'name' => name, 'sha256' => Digest::SHA256.hexdigest(bytes), 'tuples' => tuples}
      end
    end

    def snapshot_digest(snapshot)
      Digest::SHA256.hexdigest(JSON.generate(snapshot))
    end

    def attached_snapshot_matches?(copied, attached_path)
      original = copied.to_h { |name, size, sha| [name, [size, sha]] }
      attached = part_snapshot(attached_path).to_h { |name, size, sha| [name, [size, sha]] }
      extra = 'invalidated_system_columns.txt'
      require_true(!original.key?(extra) && (attached.keys - original.keys) == [extra] &&
                   (original.keys - attached.keys).empty?, 'ATTACH file roster differs from source plus admitted metadata')
      original.each { |name, digest| require_true(attached.fetch(name) == digest, "ATTACH modified original file #{name}") }
      File.binread(File.join(attached_path, extra)) == "_block_offset\n_block_number\n".b
    end

    def assert_unchanged_parts!
      require_true(part_snapshot(@source_part) == @source_snapshot, 'generated source part changed after capture')
      require_true(part_snapshot(@attached_path) == @attached_snapshot, 'attached part changed after native reads')
    end

    def build_summary(status, fatal_error)
      {
        'format' => FORMAT,
        'status' => status,
        'fatal_error' => fatal_error,
        'scope' => 'library_written_native_read_only; one advanced_s0 profile; no stock-authored W244 part claim',
        'runtime' => {
          'path' => @binary,
          'sha256_expected' => W241::BINARY_SHA256,
          'sha256_before' => @runtime_sha_before,
          'sha256_after' => @runtime_sha_after,
        },
        'helper' => @helper_record,
        'helper_sha256_before' => @helper_sha_before,
        'helper_sha256_after' => @helper_sha_after,
        'helper_source_sha256_before' => @helper_source_sha_before,
        'helper_source_sha256_after' => @helper_source_sha_after,
        'helper_output_sha256' => @helper_output_sha256,
        'profile_id' => 'advanced_s0',
        'frame_bytes' => FRAME_BYTES,
        'part' => @helper_data && @helper_data.fetch('part'),
        'physical_mark_tuples' => @physical_mark_tuples,
        'attachment' => @attachment_observation,
        'native_observations' => @native_observations,
        'invocations' => @invocations,
        'evidence_root' => @root,
      }
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    options = {}
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: probe_object_nested_dynamic_json_w244.rb --binary PATH --helper PATH --evidence-root EMPTY_DIR'
      opts.on('--binary PATH', 'Pinned ClickHouse executable') { |value| options[:binary] = value }
      opts.on('--helper PATH', 'Prebuilt W244 Crystal helper executable') { |value| options[:helper] = value }
      opts.on('--evidence-root PATH', 'Existing empty direct child of /private/tmp') { |value| options[:evidence_root] = value }
    end
    parser.parse!
    missing = %i[binary helper evidence_root].reject { |key| options[key] }
    abort(parser.to_s) unless missing.empty? && ARGV.empty?
    exit(ProbeObjectNestedDynamicJSONW244::Probe.new(options[:binary], options[:helper], options[:evidence_root]).run ? 0 : 1)
  rescue ProbeObjectNestedDynamicJSONW244::Failure, ArgumentError, KeyError, TypeError => error
    warn "W244 probe: #{error.class}: #{error.message}"
    exit 2
  end
end
