#!/usr/bin/env ruby
# Narrow W246 stock-reader falsifier. Reuses W241's bounded raw-process owner;
# it does not launch Crystal, build binaries, or claim a COMPACT Dynamic layout.
#
# Usage (root runs each cell serially under run_safe):
#   ruby scripts/probe_multi_column_tuple_dynamic_w246.rb \
#     --binary PINNED_CLICKHOUSE --helper PREBUILT_W246_HELPER \
#     --evidence-root EMPTY_DIRECT_CHILD_OF_PRIVATE_TMP \
#     --string-profile single|sized --dynamic-mode basic|compact \
#     --write-mode legacy|multi
# legacy+compact is rejected. The only native cells that qualify layout are
# legacy single/sized and multi single/sized BASIC; requested COMPACT is only an
# operation-option regression because DynamicBulkColumnWriter emits BASIC.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'optparse'
require_relative 'probe_object_shared_json_interop_w241'

module ProbeMultiColumnTupleDynamicW246
  W241 = ProbeObjectSharedJSONInteropW241
  FORMAT = 'multi_column_tuple_dynamic_w246_native_capture_v1'.freeze
  HELPER_FORMAT = 'multi_column_tuple_dynamic_w246_fixture_v1'.freeze
  HELPER_SOURCE = File.expand_path('check_multi_column_tuple_dynamic_w246.cr', __dir__).freeze
  FIXTURE_SOURCE = File.expand_path('support/multi_column_tuple_dynamic_w246_fixture.cr', __dir__).freeze
  PART_NAME = 'all_1_1_0'.freeze
  FRAME = 32
  MARK_ROWS = [2, 2, 1].freeze
  MARKS_WITH_EOF = [2, 2, 1, 0].freeze
  KEY = {'name' => 'pk', 'type' => 'UInt64'}.freeze
  DYNAMIC = 'Dynamic(max_types=1)'.freeze
  ARRAY_DYNAMIC = 'Array(Dynamic(max_types=1))'.freeze
  NAMED_TYPE = 'Tuple(sequence Dynamic(max_types=1), items Array(Dynamic(max_types=1)))'.freeze
  UNNAMED_TYPE = 'Tuple(Dynamic(max_types=1), Dynamic(max_types=1))'.freeze
  COLUMNS = [
    {'name' => 'named_tuple', 'type' => NAMED_TYPE, 'tuple_kind' => 'named', 'fields' => [
      {'name' => 'sequence', 'type' => DYNAMIC, 'dynamic_site' => 'root.field.0', 'registered_actual_types' => ['UInt64']},
      {'name' => 'items', 'type' => ARRAY_DYNAMIC, 'dynamic_site' => 'root.field.1.elements', 'registered_actual_types' => ['String']},
    ]},
    {'name' => 'unnamed_tuple', 'type' => UNNAMED_TYPE, 'tuple_kind' => 'unnamed', 'fields' => [
      {'name' => nil, 'type' => DYNAMIC, 'dynamic_site' => 'root.field.0', 'registered_actual_types' => ['Bool']},
      {'name' => nil, 'type' => DYNAMIC, 'dynamic_site' => 'root.field.1', 'registered_actual_types' => ['UInt32']},
    ]},
  ].freeze
  # Independent semantic oracle. NULL uses actual_type:null in the helper JSON;
  # native SQL reports the explicit witness string "NULL".
  N = ->(type, storage, value) { {'actual_type' => type, 'storage' => storage, 'value' => value} }
  ROWS = [
    {'pk' => 1, 'named_tuple' => {'sequence' => N.call('UInt64', 'dedicated', 7), 'items' => []},
     'unnamed_tuple' => [N.call('Bool', 'dedicated', true), N.call('UInt32', 'dedicated', 10)]},
    {'pk' => 2, 'named_tuple' => {'sequence' => N.call(nil, 'null', nil), 'items' => []},
     'unnamed_tuple' => [N.call('String', 'shared', 'left-overflow'), N.call('UInt64', 'shared', 20)]},
    {'pk' => 3, 'named_tuple' => {'sequence' => N.call('UInt64', 'dedicated', 42), 'items' => [
       N.call('String', 'dedicated', 'array-dedicated'), N.call('UInt8', 'shared', 9), N.call(nil, 'null', nil)]},
     'unnamed_tuple' => [N.call(nil, 'null', nil), N.call('UInt32', 'dedicated', 42)]},
    {'pk' => 4, 'named_tuple' => {'sequence' => N.call('String', 'shared', 'sequence-overflow'),
                                  'items' => [N.call('UInt64', 'shared', 99)]},
     'unnamed_tuple' => [N.call('Bool', 'dedicated', false), N.call(nil, 'null', nil)]},
    {'pk' => 5, 'named_tuple' => {'sequence' => N.call('String', 'shared', 'sequence-overflow-tail'),
                                  'items' => [N.call('String', 'dedicated', 'array-dedicated-tail'), N.call(nil, 'null', nil)]},
     'unnamed_tuple' => [N.call('String', 'shared', 'left-overflow-tail'), N.call('UInt64', 'shared', 100)]},
  ].freeze
  BASE_FILES = %w[checksums.txt columns.txt columns_substreams.txt count.txt default_compression_codec.txt metadata_version.txt primary.idx serialization.json].freeze
  TAGS = {path: '__W246_PATH__', check_begin: '__W246_CHECK_BEGIN__', check_end: '__W246_CHECK_END__',
          schema: '__W246_SCHEMA__', part: '__W246_PART__', values: '__W246_VALUES__',
          children: '__W246_CHILDREN__'}.freeze
  MAX_PART_BYTES = 64 * 1024 * 1024
  MAX_FILE_BYTES = W241::MAX_PART_FILE_BYTES

  class Failure < StandardError; end

  def self.closure(roots, boundary, pattern, suffix)
    root = File.realpath(boundary)
    pending = roots.map { |path| File.expand_path(path) }
    seen = {}
    until pending.empty?
      path = pending.pop
      canonical = File.realpath(path)
      unless canonical.start_with?(root + File::SEPARATOR) && File.file?(canonical) && !File.symlink?(path)
        raise Failure, "source dependency escapes its tree or is not a regular file: #{path}"
      end
      next if seen.key?(canonical)
      seen[canonical] = true
      File.foreach(canonical) do |line|
        match = pattern.match(line)
        next unless match
        dependency = File.expand_path(match[1], File.dirname(canonical))
        dependency += suffix if File.extname(dependency).empty?
        pending << dependency
      end
    end
    seen.keys.sort
  rescue Errno::ENOENT => error
    raise Failure, "source dependency is missing: #{error.message}"
  end

  def self.ruby_closure(path)
    closure([path], __dir__, /^\s*require_relative\s+['"]([^'"]+)['"]/, '.rb')
  end

  def self.crystal_closure(paths, root)
    closure(paths, root, /^\s*require\s+['"]((?:\.\/|\.\.\/)[^'"]+)['"]/, '.cr')
  end

  class Probe
    def initialize(binary:, helper:, evidence_root:, string_profile:, dynamic_mode:, write_mode:)
      @binary = File.expand_path(binary)
      @helper = File.expand_path(helper)
      @root = File.expand_path(evidence_root)
      @profile = string_profile
      @mode = dynamic_mode
      @write_mode = write_mode
      require_true(%w[single sized].include?(@profile), 'String profile must be single or sized')
      require_true(%w[basic compact].include?(@mode), 'requested operation mode must be basic or compact')
      require_true(%w[legacy multi].include?(@write_mode), 'write mode must be legacy or multi')
      require_true(@write_mode != 'legacy' || @mode == 'basic', 'legacy pair API has no compact argument')
      require_true(File.file?(@binary) && File.executable?(@binary) && !File.symlink?(@binary), 'ClickHouse executable is invalid')
      require_true(File.file?(@helper) && File.executable?(@helper) && !File.symlink?(@helper), 'helper executable is invalid')
      require_true(File.directory?(@root) && !File.symlink?(@root) && File.realpath(@root) == @root &&
                   File.dirname(@root) == File.realpath('/private/tmp') && Dir.children(@root).empty?,
                   'evidence root must be an empty canonical direct child of /private/tmp')
      @repo = File.realpath(File.expand_path('..', __dir__))
      @probe = File.realpath(__FILE__)
      @ruby_sources = ProbeMultiColumnTupleDynamicW246.ruby_closure(@probe)
      @crystal_sources = ProbeMultiColumnTupleDynamicW246.crystal_closure([HELPER_SOURCE, FIXTURE_SOURCE], @repo)
      @runner = W241::Probe.new(@binary, @helper, @root, FRAME)
      @invocations = @runner.instance_variable_get(:@invocations)
      @token = Digest::SHA256.hexdigest(@root)[0, 8]
      @table = "w246_#{@token}_#{@write_mode}_#{@profile}_#{@mode}"
    end

    def run
      prepare!
      pin_sources!
      make_part!
      attach_and_read!
      stable_parts!
      summary = build_summary
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      puts "W246 status=library_written_stock_read_observed write=#{@write_mode} string=#{@profile} requested=#{@mode} actual_dynamic=BASIC evidence=#{@root}"
      true
    rescue StandardError => error
      warn "W246 inconclusive: #{error.class}: #{error.message}"
      false
    end

    private

    def require_true(value, message)
      raise Failure, "W246: #{message}" unless value
    end

    def sha(path)
      Digest::SHA256.file(path).hexdigest
    end

    def write_new(path, bytes)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(bytes) }
    end

    def prepare!
      %w[invocations generated stores parts].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      Dir.mkdir(File.join(@root, 'stores', 'native'), 0o700)
      Dir.mkdir(File.join(@root, 'parts', 'pre_attach'), 0o700)
      @part = File.join(@root, 'generated', PART_NAME)
      @pre_attach = File.join(@root, 'parts', 'pre_attach', PART_NAME)
      @runtime_sha = sha(@binary)
      require_true(@runtime_sha == W241::BINARY_SHA256, 'ClickHouse runtime does not match W241 pin')
      @helper_sha = sha(@helper)
      @ruby_sha = source_hashes(@ruby_sources)
      @crystal_sha = source_hashes(@crystal_sources)
    end

    def source_hashes(paths)
      paths.map { |path| {'path' => path, 'sha256' => sha(path)} }
    end

    def pin_sources!
      require_true(source_hashes(@ruby_sources) == @ruby_sha && source_hashes(@crystal_sources) == @crystal_sha,
                   'source closure changed before execution')
    end

    def make_part!
      result = @runner.send(:run_process, 'crystal_helper',
                            [@helper, @part, @profile, @mode, @write_mode], ''.b,
                            'crystal-helper', expected_sha: @helper_sha, binary_path: @helper)
      require_true(result[:classification] == 'success' && result[:status]&.success? && result[:stderr].empty? &&
                   !result[:record][:timed_out] && result[:record][:binary_sha_after] == @helper_sha,
                   'Crystal helper process did not complete cleanly')
      text = result[:stdout].dup.force_encoding(Encoding::UTF_8)
      require_true(text.valid_encoding? && text.lines.size == 1 && text.end_with?("\n"), 'helper output is not one JSON line')
      @manifest = JSON.parse(text)
      validate_manifest!
      @generated = snapshot(@part)
      require_true(@manifest.fetch('files').map { |f| [f.fetch('path'), f.fetch('size'), f.fetch('sha256')] } == @generated,
                   'manifest inventory differs from actual generated files')
      validate_part!
    end

    def expected_columns
      @write_mode == 'legacy' ? [COLUMNS.first] : COLUMNS
    end

    def expected_rows
      ROWS.map { |row| @write_mode == 'legacy' ? row.reject { |k, _| k == 'unnamed_tuple' } : row }
    end
    def serialization
      columns = @write_mode == 'legacy' ? [
        {'exact_num_defaults' => true, 'kind' => 'Default', 'name' => 'pk',
         'num_defaults' => 0, 'num_rows' => 5}
      ] : []
      {'columns' => columns, 'propagate_types_serialization_versions_to_nested_types' => true,
       'types_serialization_versions' => {'string' => (@profile == 'single' ? 0 : 1)}, 'version' => 1}
    end

    def profile
      id = @profile == 'single' ? 'advanced_s0' : 'advanced_s1'
      W241::PROFILES.find { |entry| entry.fetch(:id) == id } || raise(Failure, "missing W241 reader profile #{id}")
    end

    def validate_manifest!
      expected = {'format' => HELPER_FORMAT, 'status' => 'part_created', 'part_path' => @part,
                  'write_mode' => @write_mode, 'requested_string_profile' => @profile,
                  'requested_operation_mode' => @mode, 'actual_bulk_discriminator_mode' => 'basic',
                  'frame_bytes' => FRAME, 'rows_per_mark' => 2, 'key_column' => KEY,
                  'columns' => expected_columns, 'keys' => (1..5).to_a, 'mark_row_counts' => MARK_ROWS,
                  'rows' => expected_rows, 'serialization' => serialization}
      expected.each { |key, value| require_true(@manifest[key] == value, "helper manifest #{key} differs from literal oracle") }
      require_true(@manifest.keys.sort == (expected.keys + ['files']).sort, 'helper manifest key set differs')
    end

    def snapshot(path)
      require_true(File.directory?(path) && !File.symlink?(path) && File.realpath(path) == path, "invalid part tree #{path}")
      entries = []
      total = 0
      Find.find(path) do |item|
        stat = File.lstat(item)
        require_true(!stat.symlink? && (stat.directory? || stat.file?), "part has special entry #{item}")
        next if stat.directory?
        relative = item.delete_prefix(path + File::SEPARATOR)
        require_true(!relative.include?(File::SEPARATOR), 'part must contain only regular files at its root')
        total += stat.size
        require_true(entries.size < 4096 && stat.size <= MAX_FILE_BYTES && total <= MAX_PART_BYTES, 'part exceeds file/byte bound')
        entries << [relative, stat.size, sha(item)]
      end
      entries.sort
    end

    def validate_part!
      names = @generated.map(&:first)
      require_true(File.binread(File.join(@part, 'columns.txt')) ==
        ("columns format version: 1\n#{expected_columns.size + 1} columns:\n`pk` UInt64\n" +
         expected_columns.map { |c| "`#{c.fetch('name')}` #{c.fetch('type')}\n" }.join).b, 'columns.txt differs')
      require_true(File.binread(File.join(@part, 'serialization.json')).then { |b| JSON.parse(b) == serialization },
                   'serialization.json is not the exact JSON-free/String-profile envelope')
      streams = File.binread(File.join(@part, 'columns_substreams.txt')).lines.map do |line|
        value = line.chomp
        value.delete_prefix("\t") if value.start_with?("\t")
      end.compact
      require_true(streams.include?('pk') && streams.uniq == streams && !streams.empty?, 'logical substream roster is malformed')
      expected_stream_files = streams.flat_map { |s| stem = W241::Auditor.stream_hash(s); ["#{stem}.bin", "#{stem}.mrk2"] }.sort
      require_true((names - expected_stream_files).sort == BASE_FILES.sort, 'metadata/hashed stream file roster differs')
      require_true(names.sort == (BASE_FILES + expected_stream_files).sort, 'generated regular-file roster is incomplete')
      @marks = expected_stream_files.grep(/\.mrk2\z/).map do |name|
        bytes = File.binread(File.join(@part, name))
        tuples = bytes.unpack('Q<*').each_slice(3).to_a
        require_true(bytes.bytesize > 0 && (bytes.bytesize % 24).zero? && tuples.map { |t| t[2] } == MARKS_WITH_EOF,
                     "mark row counts differ for #{name}")
        {'name' => name, 'sha256' => Digest::SHA256.hexdigest(bytes), 'tuples' => tuples}
      end.sort_by { |entry| entry.fetch('name') }
    end

    def native(label, sql)
      input = [@runner.send(:pin_sql), 'SET print_pretty_type_names=0;', sql].join("\n") + "\n"
      result = @runner.send(:native, label, File.join(@root, 'stores', 'native'), input)
      @runner.send(:assert_native_success!, result, label)
      @runner.send(:assert_pin!, result.fetch(:stdout), label)
      result
    end

    def tagged(stdout, tag, width)
      stdout.lines.map do |line|
        next unless line.start_with?(tag + "\t")
        fields = line.chomp.split("\t", -1)
        require_true(fields.size == width, "malformed #{tag} result")
        fields
      end.compact
    end

    def attach_and_read!
      declarations = ([KEY] + expected_columns).map { |c| "`#{c.fetch('name')}` #{c.fetch('type')}" }.join(', ')
      create = native('native_create_table', "CREATE TABLE default.#{@table} (#{declarations}) ENGINE=MergeTree ORDER BY pk SETTINGS #{@runner.send(:settings, profile)};\nSELECT '#{TAGS[:path]}', database, name, arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{@table}' FORMAT TSVRaw;")
      paths = tagged(create.fetch(:stdout), TAGS[:path], 4)
      require_true(paths.size == 1 && paths[0][1, 2] == ['default', @table], 'native table binding is not unique')
      @data_path = @runner.send(:validate_store_path!, paths[0][3])
      FileUtils.cp_r(@part, @pre_attach, preserve: true)
      @pre_attach_snapshot = snapshot(@pre_attach)
      require_true(@pre_attach_snapshot == @generated, 'pre-attach copy differs from generated bytes')
      @runner.send(:attach_part!, @part, @data_path)
      @detached = File.join(@data_path, 'detached', PART_NAME)
      @detached_snapshot = snapshot(@detached)
      require_true(@detached_snapshot == @generated, 'detached input differs from generated bytes')
      attach_sql = [
        "ALTER TABLE default.#{@table} ATTACH PART '#{PART_NAME}';",
        "SELECT '#{TAGS[:check_begin]}' FORMAT TSVRaw;", "CHECK TABLE default.#{@table} FORMAT TSV;",
        "SELECT '#{TAGS[:check_end]}' FORMAT TSVRaw;",
        "SELECT '#{TAGS[:schema]}', name, type FROM system.columns WHERE database='default' AND table='#{@table}' ORDER BY position FORMAT TSVRaw;",
        "SELECT '#{TAGS[:part]}', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table='#{@table}' AND active ORDER BY name FORMAT TSVRaw;",
      ].join("\n")
      attached = native('native_attach_check', attach_sql)
      check = check_lines(attached.fetch(:stdout))
      require_true(check == ["#{PART_NAME}\t1\t"], 'ATTACH CHECK is not exactly CHECK=1')
      @schema_rows = tagged(attached.fetch(:stdout), TAGS[:schema], 3).map { |r| r.drop(1) }
      expected_schema = ([KEY] + expected_columns).map { |c| [c.fetch('name'), c.fetch('type')] }
      require_true(@schema_rows == expected_schema, 'stock schema/type/field order differs')
      part_rows = tagged(attached.fetch(:stdout), TAGS[:part], 7)
      require_true(part_rows.size == 1 && part_rows[0].values_at(1, 2, 4, 5, 6) ==
                   [@table, PART_NAME, 'Wide', '5', '4'], 'active one-part inventory differs')
      @active_path = @runner.send(:validate_store_path!, part_rows[0][3])
      require_true(@active_path == File.join(@data_path, PART_NAME), 'active part path differs')
      @attached_snapshot = snapshot(@active_path)
      verify_attached_files!
      @check = check
      @active_part = part_rows[0].drop(1)
      read_native_values!
    end

    def check_lines(stdout)
      lines = []
      active = false
      stdout.lines.map(&:chomp).each do |line|
        if line == TAGS[:check_begin]
          require_true(!active, 'nested CHECK marker')
          active = true
        elsif line == TAGS[:check_end]
          require_true(active, 'unmatched CHECK marker')
          active = false
        elsif active
          lines << line
        end
      end
      require_true(!active, 'incomplete CHECK output')
      lines
    end

    def verify_attached_files!
      source = @generated.to_h { |name, size, hash| [name, [size, hash]] }
      attached = @attached_snapshot.to_h { |name, size, hash| [name, [size, hash]] }
      require_true((source.keys - attached.keys).empty? && (attached.keys - source.keys) == ['invalidated_system_columns.txt'],
                   'attached part file inventory differs from generated plus expected metadata')
      source.each { |name, identity| require_true(attached[name] == identity, "ATTACH altered #{name}") }
      require_true(File.binread(File.join(@active_path, 'invalidated_system_columns.txt')) == "_block_offset\n_block_number\n".b,
                   'ATTACH metadata differs')
    end

    def actual_and_json(expr)
      "if(isNull(#{expr}), 'NULL', dynamicType(#{expr})), if(isNull(#{expr}), 'null', hex(toJSONString(#{expr})))"
    end

    def read_native_values!
      exprs = ['toTypeName(named_tuple)', 'toTypeName(named_tuple.sequence)', actual_and_json('named_tuple.sequence'),
               'toTypeName(named_tuple.items)', 'toString(length(named_tuple.items))']
      exprs.concat(['toTypeName(unnamed_tuple)', 'toTypeName(unnamed_tuple.1)', actual_and_json('unnamed_tuple.1'),
                    'toTypeName(unnamed_tuple.2)', actual_and_json('unnamed_tuple.2')]) if @write_mode == 'multi'
      values = native('native_typed_values', "SELECT '#{TAGS[:values]}', toString(pk), #{exprs.join(', ')} FROM default.#{@table} ORDER BY pk FORMAT TSVRaw;")
      width = @write_mode == 'multi' ? 15 : 8
      @value_rows = tagged(values.fetch(:stdout), TAGS[:values], width)
      validate_values!
      children = native('native_array_children', "SELECT '#{TAGS[:children]}', toString(pk), toString(item_index), toTypeName(item), #{actual_and_json('item')} FROM default.#{@table} ARRAY JOIN arrayEnumerate(named_tuple.items) AS item_index, named_tuple.items AS item ORDER BY pk, item_index FORMAT TSVRaw;")
      @child_rows = tagged(children.fetch(:stdout), TAGS[:children], 6)
      expected = ROWS.flat_map { |row| row.fetch('named_tuple').fetch('items').each_with_index.map { |item, i| [row.fetch('pk'), i + 1, item] } }
      require_true(@child_rows.size == expected.size, 'Array child occurrence count differs')
      @child_rows.zip(expected).each do |observed, (pk, index, item)|
        require_true(observed.values_at(1, 2, 3) == [pk.to_s, index.to_s, DYNAMIC], 'Array child order/type differs')
        compare_dynamic!(observed[4], observed[5], item)
      end
    end

    def validate_values!
      require_true(@value_rows.size == ROWS.size, 'native typed row count differs')
      @value_rows.zip(ROWS).each do |row, expected|
        pk = expected.fetch('pk')
        require_true(row[1] == pk.to_s && row.values_at(2, 3, 6, 7) == [NAMED_TYPE, DYNAMIC, ARRAY_DYNAMIC, expected['named_tuple']['items'].length.to_s],
                     "named Tuple schema/field order/Array size differs at pk #{pk}")
        compare_dynamic!(row[4], row[5], expected.fetch('named_tuple').fetch('sequence'))
        next if @write_mode == 'legacy'
        unnamed = expected.fetch('unnamed_tuple')
        require_true(row.values_at(8, 9, 12) == [UNNAMED_TYPE, DYNAMIC, DYNAMIC], "unnamed Tuple declaration/order differs at pk #{pk}")
        compare_dynamic!(row[10], row[11], unnamed[0])
        compare_dynamic!(row[13], row[14], unnamed[1])
      end
    end

    def compare_dynamic!(actual_type, json_hex, expected)
      type = expected.fetch('actual_type') || 'NULL'
      require_true(actual_type == type, "Dynamic actual type differs: #{actual_type.inspect} != #{type.inspect}")
      if type == 'NULL'
        require_true(json_hex == 'null', 'NULL Dynamic JSON witness differs')
        value = nil
      else
        require_true(json_hex.is_a?(String) && /\A(?:[0-9a-fA-F]{2})+\z/.match?(json_hex),
                     'Dynamic JSON value witness is malformed')
        value = JSON.parse([json_hex].pack('H*'))
      end
      require_true(value == expected.fetch('value'), "Dynamic value differs for #{type}")
    end

    def stable_parts!
      require_true(snapshot(@part) == @generated && snapshot(@pre_attach) == @pre_attach_snapshot && snapshot(@active_path) == @attached_snapshot,
                   'part bytes changed during native read')
      require_true(!File.exist?(@detached) && !File.symlink?(@detached), 'ATTACH left the detached source behind')
      require_true(sha(@binary) == W241::BINARY_SHA256 && sha(@helper) == @helper_sha, 'runtime/helper changed during capture')
      require_true(source_hashes(@ruby_sources) == @ruby_sha && source_hashes(@crystal_sources) == @crystal_sha,
                   'source closure changed during capture')
      @runtime_sha_after = sha(@binary)
      @helper_sha_after = sha(@helper)
      @ruby_sha_after = source_hashes(@ruby_sources)
      @crystal_sha_after = source_hashes(@crystal_sources)
    end

    def build_summary
      {'format' => FORMAT, 'status' => 'library_written_stock_read_observed', 'fatal_error' => nil,
       'evidence_root' => @root, 'write_mode' => @write_mode, 'string_profile' => @profile,
       'requested_operation_mode' => @mode, 'actual_bulk_discriminator_mode' => 'BASIC',
       'frame_bytes' => FRAME, 'schema' => ([KEY] + expected_columns).map { |c| {'name' => c.fetch('name'), 'type' => c.fetch('type')} },
       'keys' => (1..5).to_a, 'mark_row_counts' => MARK_ROWS, 'rows' => expected_rows,
       'serialization' => serialization, 'helper_manifest' => @manifest,
       'runtime' => {'path' => @binary, 'sha256_before' => @runtime_sha, 'sha256_after' => @runtime_sha_after,
                     'version' => W241::VERSION, 'build' => W241::BUILD},
       'helper' => {'path' => @helper, 'sha256_before' => @helper_sha, 'sha256_after' => @helper_sha_after},
       'source_pins' => {'ruby_before' => @ruby_sha, 'ruby_after' => @ruby_sha_after,
                         'crystal_before' => @crystal_sha, 'crystal_after' => @crystal_sha_after},
       'limits' => {'timeout_seconds' => W241::TIMEOUT, 'termination_grace_seconds' => W241::GRACE,
                    'max_threads' => 1, 'max_memory_usage_bytes' => W241::MEMORY,
                    'outer_run_safe_memory_limit_bytes' => W241::OUTER_RUN_SAFE_LIMIT},
       'parts' => {'generated' => @generated, 'pre_attach' => @pre_attach_snapshot,
                   'detached' => @detached_snapshot, 'attached' => @attached_snapshot,
                   'marks' => @marks, 'check' => @check, 'schema' => @schema_rows,
                   'active_part' => @active_part, 'active_path' => @active_path},
       'native_rows' => {'values' => @value_rows, 'array_children' => @child_rows},
       'invocations' => @invocations,
       'paths' => {'generated' => @part, 'pre_attach' => @pre_attach, 'detached' => @detached,
                   'attached' => @active_path, 'data_path' => @data_path}}
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = {}
  parser = OptionParser.new do |opts|
    opts.banner = 'Usage: probe_multi_column_tuple_dynamic_w246.rb --binary PATH --helper PATH --evidence-root EMPTY_DIR --string-profile single|sized --dynamic-mode basic|compact --write-mode legacy|multi'
    opts.on('--binary PATH') { |v| options[:binary] = v }
    opts.on('--helper PATH') { |v| options[:helper] = v }
    opts.on('--evidence-root PATH') { |v| options[:evidence_root] = v }
    opts.on('--string-profile VALUE', %w[single sized]) { |v| options[:string_profile] = v }
    opts.on('--dynamic-mode VALUE', %w[basic compact]) { |v| options[:dynamic_mode] = v }
    opts.on('--write-mode VALUE', %w[legacy multi]) { |v| options[:write_mode] = v }
  end
  parser.parse!
  abort(parser.to_s) unless ARGV.empty? && %i[binary helper evidence_root string_profile dynamic_mode write_mode].all? { |key| options.key?(key) }
  begin
    exit(ProbeMultiColumnTupleDynamicW246::Probe.new(**options).run ? 0 : 1)
  rescue ProbeMultiColumnTupleDynamicW246::Failure, ArgumentError, TypeError => error
    warn "W246 probe: #{error.class}: #{error.message}"
    exit 1
  end
end
