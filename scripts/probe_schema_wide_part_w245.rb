#!/usr/bin/env ruby
# One-way W245 qualification: a Crystal library part is attached and read by
# the pinned stock ClickHouse runtime. This captures one string profile and
# one Dynamic discriminator mode per empty evidence root.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'optparse'
require_relative 'probe_object_shared_json_interop_w241'

module ProbeSchemaWidePartW245
  W241 = ProbeObjectSharedJSONInteropW241

  FORMAT = 'schema_wide_part_w245_native_capture_v1'.freeze
  HELPER_FORMAT = 'schema_wide_part_w245_fixture_v1'.freeze
  SOURCE = File.expand_path('check_schema_wide_part_w245.cr', __dir__).freeze
  FIXTURE_SOURCE = File.expand_path('support/schema_wide_part_w245_fixture.cr', __dir__).freeze
  ROW_COUNT = 5
  MARK_ROWS = [2, 2, 1].freeze
  MARK_ROWS_WITH_EOF = [2, 2, 1, 0].freeze
  FRAME_BYTES = 32
  KEY = {'name' => 'pk', 'type' => 'UInt64'}.freeze
  VALUE_COLUMNS = [
    {'name' => 'state', 'type' => 'Tuple(label LowCardinality(String), total AggregateFunction(sum, UInt8))'},
    {'name' => 'dyn', 'type' => 'Dynamic(max_types=1)'},
    {'name' => 'object', 'type' => 'JSON(max_dynamic_types=1, max_dynamic_paths=1, label String)'},
    {'name' => 'recursive', 'type' => 'Array(Tuple(doc JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8), sample Dynamic(max_types=1)))'},
  ].map(&:freeze).freeze
  ALL_COLUMNS = ([KEY] + VALUE_COLUMNS).freeze
  TAGS = {
    path: '__W245_PATH__', check_begin: '__W245_CHECK_BEGIN__', check_end: '__W245_CHECK_END__',
    schema: '__W245_SCHEMA__', part: '__W245_PART__', values: '__W245_VALUES__',
    children: '__W245_CHILDREN__', aggregate: '__W245_AGGREGATE__',
  }.freeze
  PART_NAME = 'all_1_1_0'.freeze
  ATTACH_METADATA = 'invalidated_system_columns.txt'.freeze

  class Failure < StandardError; end

  def self.ruby_source_closure_paths(root_source)
    scripts_root = File.realpath(__dir__)
    pending = [File.expand_path(root_source)]
    seen = {}
    until pending.empty?
      path = pending.pop
      canonical = File.realpath(path)
      unless canonical.start_with?(scripts_root + File::SEPARATOR) && File.file?(canonical) && !File.symlink?(path)
        raise Failure, "Ruby source dependency escapes the scripts tree or is not a regular file: #{path}"
      end
      next if seen.key?(canonical)
      seen[canonical] = true
      File.foreach(canonical) do |line|
        match = /^\s*require_relative\s+['"]([^'"]+)['"]/.match(line)
        next unless match
        dependency = File.expand_path(match[1], File.dirname(canonical))
        dependency += '.rb' if File.extname(dependency).empty?
        pending << dependency
      end
    end
    seen.keys.sort
  rescue Errno::ENOENT => error
    raise Failure, "Ruby source dependency is missing: #{error.message}"
  end

  def self.dynamic(kind, value = :missing)
    result = {'kind' => kind}
    result['value'] = value unless value == :missing
    result
  end

  def self.explicit_32_byte_frame_assignment?(text)
    assignments = text.each_line.select { |line| /\A[ \t]*FRAME_BYTES[ \t]*=/.match?(line) }
    assignments.size == 1 &&
      /\A[ \t]*FRAME_BYTES[ \t]*=[ \t]*32[ \t]*(?:\#[^\r\n]*)?\r?\n?\z/.match?(assignments.first)
  end

  def self.expected_rows
    sums = [0, 42, 200, 255, 1000]
    labels = %w[red red blue red blue]
    dyn = [dynamic('uint64', 7), dynamic('string', 'spill'), dynamic('null'),
           dynamic('uint64', 42), dynamic('string', 'tail-spill')]
    object_shapes = [dynamic('uint64', 7), dynamic('string', 'spill'), dynamic('null'),
                     dynamic('uint64', 42), dynamic('string', 'object-spill')]
    children = [[], [],
                [{'doc' => {'t' => 31}, 'sample' => dynamic('uint64', 7)}],
                [{'doc' => {'t' => 41}, 'sample' => dynamic('string', 'recursive-spill')}],
                [{'doc' => {'t' => 51}, 'sample' => dynamic('uint64', 42)},
                 {'doc' => {'t' => 52}, 'sample' => dynamic('string', 'tail-recursive')},
                 {'doc' => {'t' => 53}, 'sample' => dynamic('null')}]]
    (1..ROW_COUNT).map do |pk|
      sum = sums.fetch(pk - 1)
      {
        'pk' => pk,
        'state' => {'label' => labels.fetch(pk - 1), 'sum' => sum},
        'dyn' => dyn.fetch(pk - 1),
        'object' => {'label' => "doc-#{pk}", 'shape' => object_shapes.fetch(pk - 1)},
        'recursive' => children.fetch(pk - 1),
      }
    end
  end

  EXPECTED_ROWS = expected_rows.map(&:freeze).freeze
  EXPECTED_AGGREGATE = 1497

  class Probe
    def initialize(binary:, helper:, evidence_root:, string_profile:, dynamic_mode:, source:, fixture_source:)
      @binary = validate_executable(binary, 'ClickHouse')
      @helper = validate_executable(helper, 'Crystal helper')
      @root = validate_root(evidence_root)
      @string_profile = choice(string_profile, %w[single sized], 'String profile')
      @dynamic_mode = choice(dynamic_mode, %w[basic compact], 'Dynamic discriminator mode')
      @source = validate_source(source, 'helper entrypoint source')
      @fixture_source = validate_source(fixture_source, 'fixture dependency source')
      @probe_source = validate_source(__FILE__, 'Ruby probe source')
      @ruby_source_closure_paths = ProbeSchemaWidePartW245.ruby_source_closure_paths(@probe_source)
      @profile_id = @string_profile == 'single' ? 'advanced_s0' : 'advanced_s1'
      @token = Digest::SHA256.hexdigest(@root)[0, 8]
      @table = "w245_#{@token}_#{@string_profile}_#{@dynamic_mode}"
      @invocations = []
      @fatal_error = nil
      @runner = W241::Probe.new(@binary, @helper, @root, FRAME_BYTES)
      @invocations = @runner.instance_variable_get(:@invocations)
    end

    def run
      prepare_tree!
      @runtime_sha_before = Digest::SHA256.file(@binary).hexdigest
      require_true(@runtime_sha_before == W241::BINARY_SHA256, 'runtime SHA differs from the W241-pinned ClickHouse executable')
      @helper_sha_before = Digest::SHA256.file(@helper).hexdigest
      @source_sha_before = Digest::SHA256.file(@source).hexdigest
      @fixture_sha_before = Digest::SHA256.file(@fixture_source).hexdigest
      @probe_sha_before = Digest::SHA256.file(@probe_source).hexdigest
      @ruby_source_closure_before = source_closure_snapshot
      require_true(@ruby_source_closure_before.any? { |entry| entry.fetch('path') == @probe_source && entry.fetch('sha256') == @probe_sha_before },
                   'Ruby probe source is absent from its imported source closure')

      capture_generated_part!
      create_table_and_copy_part!
      attach_and_check!
      capture_native_values!
      assert_stable_artifacts!

      @runtime_sha_after = Digest::SHA256.file(@binary).hexdigest
      @helper_sha_after = Digest::SHA256.file(@helper).hexdigest
      @source_sha_after = Digest::SHA256.file(@source).hexdigest
      @fixture_sha_after = Digest::SHA256.file(@fixture_source).hexdigest
      @probe_sha_after = Digest::SHA256.file(@probe_source).hexdigest
      @ruby_source_closure_after = source_closure_snapshot
      require_true(@runtime_sha_after == W241::BINARY_SHA256, 'runtime SHA changed during capture')
      require_true(@helper_sha_after == @helper_sha_before, 'helper executable changed during capture')
      require_true(@source_sha_after == @source_sha_before && @fixture_sha_after == @fixture_sha_before,
                   'helper source changed during capture')
      require_true(@probe_sha_after == @probe_sha_before, 'Ruby probe source changed during capture')
      require_true(@ruby_source_closure_after == @ruby_source_closure_before,
                   'Ruby probe or imported source closure changed during capture')

      summary = build_summary('library_written_native_read_observed', nil)
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      puts "W245 status=library_written_native_read_observed; string_profile=#{@string_profile}; dynamic_mode=#{@dynamic_mode}; rows=#{ROW_COUNT}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      @runtime_sha_after = Digest::SHA256.file(@binary).hexdigest rescue nil
      @helper_sha_after = Digest::SHA256.file(@helper).hexdigest rescue nil
      @source_sha_after = Digest::SHA256.file(@source).hexdigest rescue nil
      @fixture_sha_after = Digest::SHA256.file(@fixture_source).hexdigest rescue nil
      @probe_sha_after = Digest::SHA256.file(@probe_source).hexdigest rescue nil
      @ruby_source_closure_after = source_closure_snapshot rescue nil
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(build_summary('capture_failure_inconclusive', @fatal_error)) + "\n") rescue nil
      warn "W245 generated/native oracle incomplete: #{@fatal_error}"
      false
    end

    private

    def require_true(condition, message)
      raise Failure, "W245: #{message}" unless condition
    end

    def source_closure_snapshot
      @ruby_source_closure_paths.map do |path|
        require_true(File.file?(path) && !File.symlink?(path) && File.realpath(path) == path,
                     "Ruby source dependency is no longer canonical: #{path}")
        {'path' => path, 'sha256' => Digest::SHA256.file(path).hexdigest}
      end
    end

    def choice(value, choices, label)
      require_true(choices.include?(value), "#{label} must be one of #{choices.join(', ')}")
      value
    end

    def validate_executable(path, label)
      require_true(path.is_a?(String) && !path.empty?, "#{label} path is required")
      expanded = File.expand_path(path)
      require_true(File.file?(expanded) && File.executable?(expanded) && !File.symlink?(expanded),
                   "#{label} must be a regular executable, not a symlink")
      expanded
    end

    def validate_source(path, label)
      require_true(path.is_a?(String) && !path.empty?, "#{label} path is required")
      expanded = File.expand_path(path)
      require_true(File.file?(expanded) && !File.symlink?(expanded) && File.realpath(expanded) == expanded,
                   "#{label} must be a canonical regular file")
      expanded
    end

    def validate_root(path)
      require_true(path.is_a?(String) && !path.empty?, 'evidence root is required')
      expanded = File.expand_path(path)
      require_true(File.dirname(expanded) == File.realpath('/private/tmp') && File.directory?(expanded) &&
                   !File.symlink?(expanded) && File.realpath(expanded) == expanded && Dir.children(expanded).empty?,
                   'evidence root must be an existing empty canonical direct child of /private/tmp')
      expanded
    rescue Errno::ENOENT
      raise Failure, 'evidence root or /private/tmp must already exist'
    end

    def prepare_tree!
      %w[invocations stores parts generated].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      Dir.mkdir(File.join(@root, 'stores', 'native'), 0o700)
      Dir.mkdir(File.join(@root, 'parts', 'pre_attach'), 0o700)
    end

    def write_new(path, bytes)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(bytes) }
    end

    def capture_generated_part!
      @source_part = File.join(@root, 'generated', PART_NAME)
      invocation = @runner.send(:run_process, 'crystal_helper',
                                [@helper, @source_part, @string_profile, @dynamic_mode], ''.b,
                                'crystal-helper', expected_sha: @helper_sha_before, binary_path: @helper)
      require_true(invocation[:classification] == 'success' && invocation[:status]&.success? &&
                   invocation[:status]&.termsig.nil? && invocation[:stderr].empty? &&
                   invocation[:record][:binary_sha_after] == @helper_sha_before,
                   "Crystal helper failed: #{invocation[:record].inspect}")
      output = parse_single_json_line!(invocation.fetch(:stdout), 'helper stdout')
      validate_helper_output!(output)
      @helper_record = {
        'invocation_label' => 'crystal_helper',
        'helper_executable_sha256' => @helper_sha_before,
        'helper_source_sha256' => @source_sha_before,
        'fixture_source_sha256' => @fixture_sha_before,
        'output_sha256' => Digest::SHA256.hexdigest(invocation.fetch(:stdout)),
      }
      @helper_output = output
      @source_snapshot = part_snapshot(@source_part)
      @physical_mark_tuples = read_physical_mark_tuples(@source_part)
      @helper_record['source_snapshot_sha256'] = snapshot_digest(@source_snapshot)
    end

    def validate_helper_output!(data)
      exact_keys!(data, %w[format part_path key_column columns keys mark_row_counts string_profile dynamic_mode rows files], 'helper manifest')
      require_true(data['format'] == HELPER_FORMAT, 'helper format differs')
      require_true(data['part_path'] == @source_part, 'helper part path differs')
      require_true(data['key_column'] == KEY && data['columns'] == VALUE_COLUMNS,
                   'helper key/value declarations or their order differ from the literal schema')
      require_true(data['keys'] == (1..ROW_COUNT).to_a && data['mark_row_counts'] == MARK_ROWS,
                   'helper key/parent mark domain differs')
      require_true(data['string_profile'] == @string_profile && data['dynamic_mode'] == @dynamic_mode,
                   'helper String profile or Dynamic discriminator mode differs')
      require_true(data['rows'] == EXPECTED_ROWS, 'helper typed rows differ from the literal fixture')
      require_true(inventory_from_manifest(data['files']) == part_snapshot(@source_part),
                   'helper file inventory differs from the independent directory scan')
      expected_columns = "columns format version: 1\n5 columns:\n`pk` UInt64\n" +
                         VALUE_COLUMNS.map { |column| "`#{column.fetch('name')}` #{column.fetch('type')}\n" }.join
      require_true(File.binread(File.join(@source_part, 'columns.txt')) == expected_columns.b,
                   'physical columns.txt differs from the exact ordered key/value schema')
      require_true(File.binread(File.join(@source_part, 'count.txt')).strip == ROW_COUNT.to_s,
                   'physical count.txt differs')
      codec = File.binread(File.join(@source_part, 'default_compression_codec.txt')).strip
      require_true(codec == 'CODEC(LZ4)', 'part compression codec is not LZ4')
      serialization = JSON.parse(File.binread(File.join(@source_part, 'serialization.json')))
      expected_string_version = @string_profile == 'single' ? 0 : 1
      require_true(serialization.is_a?(Hash) && serialization['version'] == 1 &&
                   serialization['propagate_types_serialization_versions_to_nested_types'] == true &&
                   serialization.dig('types_serialization_versions', 'string') == expected_string_version,
                   'part serialization metadata does not pin nested propagation and the requested String profile')
      @serialization = serialization
      @columns_substreams_text = File.binread(File.join(@source_part, 'columns_substreams.txt'))
      @substream_sections = parse_substream_sections!(@columns_substreams_text)
      expected_stream_files = @substream_sections.flat_map do |_column, streams|
        streams.flat_map do |logical|
          stem = W241::Auditor.stream_hash(logical)
          ["#{stem}.bin", "#{stem}.mrk2"]
        end
      end.sort
      actual_stream_files = Dir.children(@source_part).select { |name| name.end_with?('.bin', '.mrk2') }.sort
      require_true(actual_stream_files == expected_stream_files,
                   'hashed .bin/.mrk2 files do not match the table-wide logical substream roster')
      fixture_source_text = File.binread(@fixture_source)
      require_true(ProbeSchemaWidePartW245.explicit_32_byte_frame_assignment?(fixture_source_text),
                   'fixture source does not pin the requested 32-byte writer frame')
      require_true(Dir.children(@source_part).none? { |name| name.end_with?('.cmrk2') },
                   'part contains compressed marks instead of plain .mrk2')
      true
    rescue KeyError, TypeError, ArgumentError, Errno::ENOENT, JSON::ParserError => error
      raise Failure, "helper manifest is malformed: #{error.class}: #{error.message}"
    end

    def parse_substream_sections!(text)
      lines = text.force_encoding(Encoding::UTF_8).split("\n", -1)
      require_true(lines.pop == '' && lines.shift == 'columns substreams version: 1',
                   'columns_substreams.txt version/final newline differs')
      count_line = lines.shift
      match = /\A([1-9][0-9]*) columns:\z/.match(count_line.to_s)
      require_true(match && match[1].to_i == ALL_COLUMNS.size,
                   'columns_substreams.txt column count differs')
      sections = []
      until lines.empty?
        header = lines.shift
        header_match = /\A(0|[1-9][0-9]*) substreams for column `([a-z][a-z0-9_]*)`:\z/.match(header.to_s)
        require_true(header_match, 'malformed columns_substreams section header')
        amount = Integer(header_match[1], 10)
        require_true(amount <= 4096 && lines.size >= amount, 'logical substream roster exceeds bounds')
        streams = amount.times.map do
          line = lines.shift
          stream_match = /\A\t([A-Za-z0-9_.%]+)\z/.match(line.to_s)
          require_true(stream_match, 'malformed logical substream name')
          stream_match[1]
        end
        sections << [header_match[2], streams]
      end
      require_true(sections.map(&:first) == ALL_COLUMNS.map { |column| column.fetch('name') },
                   'logical substream column roster/order differs from the literal complete schema')
      streams = sections.flat_map(&:last)
      require_true(streams.uniq == streams, 'logical substreams are duplicated or shared across owners')
      stems = streams.map { |logical| W241::Auditor.stream_hash(logical) }
      require_true(stems.uniq == stems, 'logical substreams collide in the hashed physical namespace')
      sections
    end

    def create_table_and_copy_part!
      profile = W241::PROFILES.find { |candidate| candidate.fetch(:id) == @profile_id } || raise(Failure, 'stock-reader profile is absent')
      store = File.join(@root, 'stores', 'native')
      columns = ALL_COLUMNS.map { |column| "`#{column.fetch('name')}` #{column.fetch('type')}" }.join(', ')
      sql = [
        "CREATE TABLE default.#{@table} (#{columns}) ENGINE=MergeTree ORDER BY pk SETTINGS #{@runner.send(:settings, profile)};",
        "SELECT '#{TAGS.fetch(:path)}', database, name, arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{@table}' FORMAT TSVRaw;",
      ].join("\n")
      invocation = native_stage('native_create_table', store, sql)
      rows = tagged_rows(invocation[:stdout], TAGS.fetch(:path), 4)
      require_true(rows.size == 1 && rows.first.values_at(1, 2) == ['default', @table], 'native table/path binding is not unique')
      validated_data_path = @runner.send(:validate_store_path!, rows.first.fetch(3))
      @data_path = canonical_native_directory(validated_data_path, store, 'native table data path')
      @create_record = invocation.fetch(:record)

      @pre_attach_part = File.join(@root, 'parts', 'pre_attach', PART_NAME)
      FileUtils.cp_r(@source_part, @pre_attach_part, preserve: true)
      @pre_attach_snapshot = part_snapshot(@pre_attach_part)
      require_true(@pre_attach_snapshot == @source_snapshot, 'retained pre-attach bytes differ from generated part')
      @runner.send(:attach_part!, @source_part, @data_path)
      @detached_part = File.join(@data_path, 'detached', PART_NAME)
      @detached_snapshot = part_snapshot(@detached_part)
      require_true(@detached_snapshot == @source_snapshot, 'detached/pre-attach bytes differ from generated part')
    end

    def attach_and_check!
      sql = [
        "ALTER TABLE default.#{@table} ATTACH PART '#{PART_NAME}';",
        "SELECT '#{TAGS.fetch(:check_begin)}' FORMAT TSVRaw;",
        "CHECK TABLE default.#{@table} FORMAT TSV;",
        "SELECT '#{TAGS.fetch(:check_end)}' FORMAT TSVRaw;",
        "SELECT '#{TAGS.fetch(:schema)}', name, type FROM system.columns WHERE database='default' AND table='#{@table}' ORDER BY position FORMAT TSVRaw;",
        "SELECT '#{TAGS.fetch(:part)}', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table='#{@table}' AND active ORDER BY name FORMAT TSVRaw;",
      ].join("\n")
      invocation = native_stage('native_attach_check', File.join(@root, 'stores', 'native'), sql)
      checks = check_rows(invocation[:stdout])
      require_true(checks == ["#{PART_NAME}\t1\t"], 'native CHECK TABLE did not report exactly one valid part')
      schemas = tagged_rows(invocation[:stdout], TAGS.fetch(:schema), 3).map { |row| row.drop(1) }
      require_true(schemas == ALL_COLUMNS.map { |column| [column.fetch('name'), column.fetch('type')] },
                   'stock system.columns nominal schema/order differs')
      parts = tagged_rows(invocation[:stdout], TAGS.fetch(:part), 7)
      require_true(parts.size == 1 && parts.first.values_at(1, 2, 4, 5, 6) ==
                   [@table, PART_NAME, 'Wide', ROW_COUNT.to_s, (MARK_ROWS.size + 1).to_s],
                   'active part/table identity, part layout, row count or marks differ')
      validated_attached_path = @runner.send(:validate_store_path!, parts.first.fetch(3))
      @attached_path = canonical_native_directory(validated_attached_path, @data_path, 'active part path')
      require_true(@attached_path == File.join(@data_path, PART_NAME), 'active part path is not the exact table child')
      @attached_snapshot = part_snapshot(@attached_path)
      require_true(attached_snapshot_matches?(@source_snapshot, @attached_snapshot, @attached_path),
                   'ATTACH changed the generated bytes beyond admitted native metadata')
      @check_observation = {
        'check_rows' => checks,
        'schema' => schemas,
        'active_part' => parts.first.drop(1),
        'data_path' => @data_path,
        'active_path' => @attached_path,
        'source_snapshot_sha256' => snapshot_digest(@source_snapshot),
        'pre_attach_snapshot_sha256' => snapshot_digest(@pre_attach_snapshot),
        'detached_snapshot_sha256' => snapshot_digest(@detached_snapshot),
        'attached_snapshot_sha256' => snapshot_digest(@attached_snapshot),
      }
      @check_record = invocation.fetch(:record)
    end

    def capture_native_values!
      store = File.join(@root, 'stores', 'native')
      values_sql = "SELECT '#{TAGS.fetch(:values)}', toString(pk), toTypeName(state.1), state.1, " \
                   "toTypeName(finalizeAggregation(state.2)), toString(finalizeAggregation(state.2)), " \
                   "if(isNull(dyn), 'NULL', dynamicType(dyn)), if(isNull(dyn), 'null', hex(toJSONString(dyn))), " \
                   "toTypeName(object.label), object.label, toTypeName(object.shape), " \
                   "if(isNull(object.shape), 'NULL', dynamicType(object.shape)), " \
                   "if(isNull(object.shape), 'null', hex(toJSONString(object.shape))), " \
                   "hex(toJSONString(JSONAllPathsWithTypes(object))), hex(toJSONString(object)) " \
                   "FROM default.#{@table} ORDER BY pk FORMAT TSVRaw;"
      values = native_stage('native_typed_values', store, values_sql)
      value_rows = tagged_rows(values[:stdout], TAGS.fetch(:values), 15)
      validate_value_rows!(value_rows)

      child_sql = "SELECT '#{TAGS.fetch(:children)}', toString(pk), toString(item_index), " \
                  "toTypeName(item.doc), hex(toJSONString(item.doc)), " \
                  "hex(toJSONString(JSONAllPathsWithTypes(item.doc))), toTypeName(item.doc.t), toString(item.doc.t), " \
                  "toTypeName(item.sample), if(isNull(item.sample), 'NULL', dynamicType(item.sample)), " \
                  "if(isNull(item.sample), 'null', hex(toJSONString(item.sample))) " \
                  "FROM default.#{@table} ARRAY JOIN arrayEnumerate(recursive) AS item_index, recursive AS item " \
                  "ORDER BY pk, item_index FORMAT TSVRaw;"
      children = native_stage('native_recursive_children', store, child_sql)
      child_rows = tagged_rows(children[:stdout], TAGS.fetch(:children), 11)
      validate_child_rows!(child_rows)

      aggregate_sql = "SELECT '#{TAGS.fetch(:aggregate)}', toTypeName(sumMerge(state.2)), toString(sumMerge(state.2)) " \
                      "FROM default.#{@table} FORMAT TSVRaw;"
      aggregate = native_stage('native_aggregate_finalize', store, aggregate_sql)
      aggregate_rows = tagged_rows(aggregate[:stdout], TAGS.fetch(:aggregate), 3)
      require_true(aggregate_rows == [[TAGS.fetch(:aggregate), 'UInt64', EXPECTED_AGGREGATE.to_s]],
                   'stock sumMerge aggregate finalization differs from 1497')

      @native_observations = {
        'typed_value_rows' => value_rows.map { |row| row.drop(1) },
        'recursive_child_rows' => child_rows.map { |row| row.drop(1) },
        'aggregate_finalization' => aggregate_rows.map { |row| row.drop(1) },
        'type_checked_same_value' => true,
        'value_invocation' => values.fetch(:record).fetch(:label),
        'children_invocation' => children.fetch(:record).fetch(:label),
        'aggregate_invocation' => aggregate.fetch(:record).fetch(:label),
      }
    end

    def validate_value_rows!(rows)
      require_true(rows.size == ROW_COUNT, 'native typed-value row count differs')
      rows.each_with_index do |row, index|
        expected = EXPECTED_ROWS.fetch(index)
        require_true(row.fetch(1) == expected.fetch('pk').to_s, 'native key order differs')
        require_true(row.values_at(2, 3, 4, 5, 6) ==
                     ['LowCardinality(String)', expected.fetch('state').fetch('label'), 'UInt64', expected.fetch('state').fetch('sum').to_s,
                      native_kind(expected.fetch('dyn').fetch('kind'))],
                     "native state or top-level Dynamic actual type/value differs at pk #{expected.fetch('pk')}")
        expected_dyn = expected.fetch('dyn')
        compare_nullable_json!(row.fetch(6), row.fetch(7), expected_dyn, "top-level Dynamic pk#{expected.fetch('pk')}")
        object = expected.fetch('object')
        require_true(row.fetch(8) == 'String' && row.fetch(9) == object.fetch('label') && row.fetch(10) == 'Dynamic(max_types=1)',
                     "native JSON label String/value differs at pk #{expected.fetch('pk')}")
        expected_shape = object.fetch('shape')
        shape_type = native_kind(expected_shape.fetch('kind'))
        require_true(row.fetch(11) == shape_type, "native JSON Dynamic actual type differs at pk #{expected.fetch('pk')}")
        compare_nullable_json!(row.fetch(11), row.fetch(12), expected_shape, "JSON Dynamic pk#{expected.fetch('pk')}")
        observed_object_types = parse_hex_json(row.fetch(13), "native Object path types pk#{expected.fetch('pk')}")
        require_true(observed_object_types.is_a?(Hash) && observed_object_types['label'] == 'String' &&
                     (expected_shape.fetch('kind') == 'null' ?
                        observed_object_types == {'label' => 'String'} :
                        observed_object_types['shape'] == shape_type),
                     "native Object JSON child type differs at pk #{expected.fetch('pk')}")
        expected_object = {'label' => object.fetch('label')}
        expected_object['shape'] = tagged_value(expected_shape) unless expected_shape.fetch('kind') == 'null'
        require_true(parse_hex_json(row.fetch(14), "native Object pk#{expected.fetch('pk')}") == expected_object,
                     "native full JSON object differs at pk #{expected.fetch('pk')}")
      end
      true
    rescue KeyError, ArgumentError, TypeError => error
      raise Failure, "native typed values malformed: #{error.class}: #{error.message}"
    end

    def compare_nullable_json!(type_field, json_field, expected, label)
      if expected.fetch('kind') == 'null'
        require_true(type_field == 'NULL' && (json_field.nil? || json_field == 'null'), "#{label} NULL witness differs")
      else
        require_true(type_field == native_kind(expected.fetch('kind')), "#{label} exact actual type differs")
        require_true(parse_hex_json(json_field, "#{label} JSON value") == expected.fetch('value'), "#{label} value differs")
      end
    end

    def native_kind(kind)
      {'uint64' => 'UInt64', 'string' => 'String', 'null' => 'NULL'}.fetch(kind)
    end

    def tagged_value(tagged)
      tagged.fetch('kind') == 'null' ? nil : tagged.fetch('value')
    end

    def canonical_native_directory(path, parent, label)
      lexical = path.to_s
      lexical = lexical[0...-1] if lexical.end_with?(File::SEPARATOR)
      require_true(!lexical.empty? && File.expand_path(lexical) == lexical,
                   "#{label} has noncanonical spelling")
      canonical_parent = File.realpath(parent)
      require_true(canonical_parent == parent && !File.symlink?(parent), "#{label} parent is noncanonical")
      require_true(File.directory?(lexical) && !File.symlink?(lexical) && File.realpath(lexical) == lexical,
                   "#{label} is missing, symlinked, or noncanonical")
      require_true(lexical.start_with?(canonical_parent + File::SEPARATOR), "#{label} escapes its expected parent")
      lexical
    rescue Errno::ENOENT
      raise Failure, "#{label} is missing"
    end

    def validate_child_rows!(rows)
      expected = EXPECTED_ROWS.each_with_index.flat_map do |row, index|
        row.fetch('recursive').each_with_index.map { |child, child_index| [index + 1, child_index + 1, child] }
      end
      require_true(rows.size == expected.size, 'native recursive child occurrence count differs')
      rows.zip(expected).each do |observed, (pk, child_index, child)|
        doc_t = child.fetch('doc').fetch('t')
        sample = child.fetch('sample')
        sample_type = native_kind(sample.fetch('kind'))
        require_true(observed.values_at(1, 2, 3, 6, 7, 8, 9) ==
                     [pk.to_s, child_index.to_s, 'JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8)', 'UInt8', doc_t.to_s,
                      'Dynamic(max_types=1)', sample_type],
                     "native recursive JSON/Dynamic exact type witness differs at pk #{pk}/child #{child_index}")
        doc = parse_hex_json(observed.fetch(4), "recursive JSON pk#{pk}/child#{child_index}")
        path_types = parse_hex_json(observed.fetch(5), "recursive JSON path types pk#{pk}/child#{child_index}")
        require_true(doc == {'t' => doc_t} && path_types == {'t' => 'UInt8'},
                     "native recursive JSON value or declared leaf type differs at pk #{pk}/child #{child_index}")
        compare_nullable_json!(observed.fetch(9), observed.fetch(10), sample,
                               "recursive Dynamic pk#{pk}/child#{child_index}")
      end
      true
    rescue KeyError, ArgumentError, TypeError => error
      raise Failure, "native recursive child output malformed: #{error.class}: #{error.message}"
    end

    def native_stage(label, store, sql)
      envelope = [@runner.send(:pin_sql), 'SET print_pretty_type_names=0;',
                  'SET output_format_json_quote_64bit_integers=0;', sql].join("\n")
      invocation = @runner.send(:native, label, store, envelope)
      @runner.send(:assert_native_success!, invocation, label)
      @runner.send(:assert_pin!, invocation.fetch(:stdout), label)
      invocation
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
        if line == TAGS.fetch(:check_begin)
          require_true(!active, 'nested CHECK interval')
          active = true
        elsif line == TAGS.fetch(:check_end)
          require_true(active, 'CHECK end without begin')
          active = false
        elsif active
          result << line
        end
      end
      require_true(!active, 'unterminated CHECK interval')
      result
    end

    def parse_single_json_line!(bytes, label)
      text = bytes.dup.force_encoding(Encoding::UTF_8)
      require_true(text.valid_encoding? && text.lines.size == 1 && text.end_with?("\n"),
                   "#{label} is not one UTF-8 JSON line")
      JSON.parse(text)
    rescue JSON::ParserError => error
      raise Failure, "#{label} is invalid JSON: #{error.message}"
    end

    def parse_hex_json(value, label)
      require_true(value.is_a?(String) && value.match?(/\A(?:[0-9a-fA-F]{2})*\z/), "#{label} is malformed hex JSON")
      JSON.parse([value].pack('H*'))
    rescue JSON::ParserError => error
      raise Failure, "#{label} contains invalid JSON: #{error.message}"
    end

    def exact_keys!(hash, keys, label)
      require_true(hash.is_a?(Hash) && hash.keys.sort == keys.sort, "#{label} key set differs")
    end

    def inventory_from_manifest(files)
      require_true(files.is_a?(Array), 'helper physical file inventory is not an array')
      names = files.map do |entry|
        exact_keys!(entry, %w[name size sha256], 'helper file inventory entry')
        name = entry.fetch('name')
        require_true(name.is_a?(String) && File.basename(name) == name && /\A[A-Za-z0-9_.-]+\z/.match?(name),
                     'helper file name is unsafe')
        size = entry.fetch('size')
        require_true(size.is_a?(Integer) && size >= 0, 'helper file size is malformed')
        sha = entry.fetch('sha256')
        require_true(sha.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(sha), 'helper file SHA is malformed')
        [name, size, sha]
      end
      require_true(names.map(&:first).uniq == names.map(&:first) && names == names.sort,
                   'helper file inventory is duplicated or unsorted')
      names
    end

    def part_snapshot(path)
      require_true(File.directory?(path) && !File.symlink?(path) && File.realpath(path) == path,
                   "part is absent, noncanonical, or symlinked: #{path}")
      entries = []
      total = 0
      count = 0
      Find.find(path) do |entry|
        stat = File.lstat(entry)
        require_true(!stat.symlink? && (stat.directory? || stat.file?), "part contains a symlink/special file: #{entry}")
        next if stat.directory?
        count += 1
        require_true(count <= 4096 && stat.size <= W241::MAX_PART_FILE_BYTES, "part file count/size exceeds bound")
        total += stat.size
        require_true(total <= 64 * 1024 * 1024, 'part exceeds total byte bound')
        entries << [entry.delete_prefix(path + File::SEPARATOR), stat.size, Digest::SHA256.file(entry).hexdigest]
      end
      entries.sort
    end

    def read_physical_mark_tuples(path)
      names = Dir.children(path).grep(/\.mrk2\z/).sort
      require_true(!names.empty? && Dir.children(path).none? { |name| name.end_with?('.cmrk2') },
                   'part lacks plain .mrk2 files or contains compressed marks')
      names.map do |name|
        file = File.join(path, name)
        stat = File.lstat(file)
        require_true(stat.file? && !stat.symlink? && stat.size <= W241::MAX_PART_FILE_BYTES,
                     "physical mark file is not a bounded regular file: #{name}")
        bytes = File.binread(file)
        require_true(bytes.bytesize == stat.size && (bytes.bytesize % 24).zero?,
                     "physical mark file is not a complete sequence of 24-byte triples: #{name}")
        tuples = bytes.unpack('Q<*').each_slice(3).map(&:dup)
        require_true(tuples.map { |tuple| tuple.fetch(2) } == MARK_ROWS_WITH_EOF,
                     "physical mark row-count grid differs from #{MARK_ROWS_WITH_EOF.inspect}: #{name}")
        {'name' => name, 'sha256' => Digest::SHA256.hexdigest(bytes), 'tuples' => tuples}
      end
    end

    def attached_snapshot_matches?(source, attached, path)
      original = source.to_h { |name, size, sha| [name, [size, sha]] }
      actual = attached.to_h { |name, size, sha| [name, [size, sha]] }
      require_true(!original.key?(ATTACH_METADATA) && (actual.keys - original.keys) == [ATTACH_METADATA] &&
                   (original.keys - actual.keys).empty?, 'ATTACH file roster differs from source plus admitted metadata')
      original.each { |name, identity| require_true(actual.fetch(name) == identity, "ATTACH modified original file #{name}") }
      File.binread(File.join(path, ATTACH_METADATA)) == "_block_offset\n_block_number\n".b
    end

    def snapshot_digest(snapshot)
      Digest::SHA256.hexdigest(JSON.generate(snapshot))
    end

    def assert_stable_artifacts!
      require_true(part_snapshot(@source_part) == @source_snapshot, 'generated part changed after capture')
      require_true(part_snapshot(@pre_attach_part) == @pre_attach_snapshot, 'retained pre-attach part changed after capture')
      require_true(part_snapshot(@attached_path) == @attached_snapshot, 'active part changed after native reads')
    end

    def build_summary(status, fatal_error)
      {
        'format' => FORMAT,
        'status' => status,
        'fatal_error' => fatal_error,
        'scope' => 'library_written_stock_read_only; one String profile and one Dynamic discriminator mode; no reciprocal or live-table claim',
        'evidence_root' => @root,
        'runtime' => {
          'path' => @binary, 'sha256_expected' => W241::BINARY_SHA256,
          'sha256_before' => @runtime_sha_before, 'sha256_after' => @runtime_sha_after,
        },
        'source_pins' => {
          'ruby_probe_path' => @probe_source, 'ruby_probe_sha256_before' => @probe_sha_before,
          'ruby_probe_sha256_after' => @probe_sha_after,
          'ruby_source_closure_before' => @ruby_source_closure_before,
          'ruby_source_closure_after' => @ruby_source_closure_after,
          'helper_entrypoint_source_path' => @source, 'helper_entrypoint_source_sha256_before' => @source_sha_before,
          'helper_entrypoint_source_sha256_after' => @source_sha_after,
          'fixture_source_path' => @fixture_source, 'fixture_source_sha256_before' => @fixture_sha_before,
          'fixture_source_sha256_after' => @fixture_sha_after,
        },
        'helper' => @helper_record,
        'helper_executable' => {
          'path' => @helper, 'sha256_before' => @helper_sha_before, 'sha256_after' => @helper_sha_after,
        },
        'helper_manifest' => @helper_output,
        'helper_output_sha256' => @helper_record && @helper_record['output_sha256'],
        'string_profile' => @string_profile,
        'dynamic_mode' => @dynamic_mode,
        'profile_id' => @profile_id,
        'frame_bytes' => FRAME_BYTES,
        'string_serialization_version' => @string_profile == 'single' ? 0 : 1,
        'serialization' => @serialization,
        'columns_substreams_text' => @columns_substreams_text,
        'substream_sections' => @substream_sections,
        'schema' => ALL_COLUMNS,
        'generated_snapshot' => @source_snapshot,
        'pre_attach_snapshot' => @pre_attach_snapshot,
        'detached_snapshot' => @detached_snapshot,
        'attached_snapshot' => @attached_snapshot,
        'physical_mark_tuples' => @physical_mark_tuples,
        'attachment' => @check_observation,
        'native_observations' => @native_observations,
        'invocations' => @invocations,
        'evidence_paths' => {
          'generated_part' => @source_part, 'pre_attach_part' => @pre_attach_part,
          'detached_part' => @detached_part, 'attached_part' => @attached_path,
          'data_path' => @data_path,
        },
      }
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    options = {}
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: probe_schema_wide_part_w245.rb --binary PATH --helper PATH --evidence-root EMPTY_DIR --string-profile single|sized --dynamic-mode basic|compact'
      opts.on('--binary PATH', 'Pinned ClickHouse executable') { |value| options[:binary] = value }
      opts.on('--helper PATH', 'Prebuilt W245 Crystal fixture executable') { |value| options[:helper] = value }
      opts.on('--evidence-root PATH', 'Existing empty direct child of /private/tmp') { |value| options[:evidence_root] = value }
      opts.on('--string-profile PROFILE', %w[single sized], 'Global String stream profile') { |value| options[:string_profile] = value }
      opts.on('--dynamic-mode MODE', %w[basic compact], 'Dynamic discriminator mode (not Compact part layout)') { |value| options[:dynamic_mode] = value }
      opts.on('--source PATH', 'Fixture helper entrypoint source') { |value| options[:source] = value }
      opts.on('--fixture-source PATH', 'Fixture implementation dependency source') { |value| options[:fixture_source] = value }
    end
    parser.parse!
    options[:source] ||= ProbeSchemaWidePartW245::SOURCE
    options[:fixture_source] ||= ProbeSchemaWidePartW245::FIXTURE_SOURCE
    required = %i[binary helper evidence_root string_profile dynamic_mode]
    abort(parser.to_s) unless ARGV.empty? && required.all? { |key| options[key] }
    exit(ProbeSchemaWidePartW245::Probe.new(**options).run ? 0 : 1)
  rescue ProbeSchemaWidePartW245::Failure, ArgumentError, KeyError, TypeError => error
    warn "W245 probe: #{error.class}: #{error.message}"
    exit 2
  end
end
