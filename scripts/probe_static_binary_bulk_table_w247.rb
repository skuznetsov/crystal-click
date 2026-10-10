#!/usr/bin/env ruby
# Bounded W247 handoff probe. The Crystal writer creates the input Wide part;
# pinned stock ClickHouse attaches/checks it, reads literal rows, and re-emits
# those rows into a separate stock-written Wide part for a Crystal inspect.
# This script never builds Crystal or ClickHouse. Root runs it under run_safe.
#
# Usage:
#   ruby scripts/probe_static_binary_bulk_table_w247.rb \
#     --binary PINNED_CLICKHOUSE --helper PREBUILT_W247_HELPER \
#     --evidence-root EMPTY_DIRECT_CHILD_OF_PRIVATE_TMP \
#     --string-profile single|sized

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'open3'
require 'optparse'
require_relative 'probe_object_shared_json_interop_w241'

module ProbeStaticBinaryBulkTableW247
  W241 = ProbeObjectSharedJSONInteropW241
  FORMAT = 'static_binary_bulk_table_w247_native_capture_v1'.freeze
  HELPER_FORMAT = 'static_binary_bulk_table_w247_fixture_v1'.freeze
  HELPER_SOURCE = File.expand_path('check_static_binary_bulk_table_w247.cr', __dir__).freeze
  FIXTURE_SOURCE = File.expand_path('support/static_binary_bulk_table_w247_fixture.cr', __dir__).freeze
  # These source snapshots explain the selected physical output profile. They
  # are deliberately separate from the recovered runtime identity: the runtime
  # is pinned by W241, but is not claimed to have been built from either tree.
  SOURCE_PINS = [
    {'tree' => 'clickhouse-2026-10-07-depth1',
     'root' => '/Users/sergey/SrcArchives/clickhouse-2026-10-07-depth1',
     'revision' => '0ca8150d9b1d0886edb2e3b4ab65eebb768d0357',
     'files' => [
       {'path' => 'src/Core/Settings.cpp', 'sha256' => '1feab11c05a33d9df8c6e4886ad00a81efa358ba320803d720db32eef4f9db9a'},
       {'path' => 'src/Storages/MergeTree/MergeTreeDataWriter.cpp', 'sha256' => '7da96e0583100c60c5c09a3a3f099d99367d8fbb3c4cb03e7bad66e571b8b751'},
       {'path' => 'src/Storages/MergeTree/MergedBlockOutputStream.cpp', 'sha256' => '84be13120fc36b38c54e05965fb504fbce3b741d8d65e0080fe4ac9bd5b1d076'},
       {'path' => 'src/Storages/MergeTree/MergeTreeSettings.cpp', 'sha256' => 'b8bdea86a07f61481c747517b56035855fa9726217d5b7183f292a5432b9b515'},
       {'path' => 'src/Storages/MergeTree/MergeTreeDataPartWriterWide.cpp', 'sha256' => 'a54c556841343f20ffb22b6cbd406f27c9a81df50eddb23ee5dca884d1686a76'},
       {'path' => 'src/Databases/DatabaseAtomic.cpp', 'sha256' => 'f327671aaabe9855e6e275ed86daead8b87659b54c35af39ed18d26e0270e589'},
     ]},
    {'tree' => 'clickhouse-w238-serializer-snapshot',
     'root' => '/private/tmp/crystal-click-w238.4nQqSo/clickhouse',
     'revision' => 'f25eb93a0b890a3b87df05eb34e2af1f933b4089',
     'files' => [
       {'path' => 'src/DataTypes/Serializations/SerializationVariant.cpp', 'sha256' => '9e91cc5a2aa9498841aa7524193247d55a30c77682c65a0991c77a2968b9e022'},
       {'path' => 'src/DataTypes/Serializations/SerializationVariant.h', 'sha256' => '075e43b8c2ab6f69ad0a5954d08e233568c32905ef145841fa3fb6ab9f03f748'},
     ]},
  ].freeze
  PART_NAME = 'all_1_1_0'.freeze
  FRAME = 32
  ROWS_PER_MARK = 2
  KEYS = [1, 2, 3, 4, 5].freeze
  MARK_ROWS = [2, 2, 1].freeze
  MARKS_WITH_EOF = [2, 2, 1, 0].freeze
  KEY = {'name' => 'pk', 'type' => 'UInt64'}.freeze
  TYPES = {
    'root_variant' => 'Variant(Array(UInt16), String)',
    'array_variant' => 'Array(Variant(LowCardinality(String), UInt64))',
    'named_recursive' => 'Tuple(arr Array(Nullable(Int32)), labels LowCardinality(Nullable(String)), choice Variant(Array(UInt16), String))',
    'string0' => 'String',
    'string1' => 'String',
  }.freeze
  TARGET_COLUMNS = %w[root_variant array_variant named_recursive].freeze
  STRING_COLUMNS = %w[string0 string1].freeze
  # This is an independent stock-row oracle. It is intentionally not read from
  # the helper's report or the Crystal fixture.
  V = ->(type, value) { {'type' => type, 'value' => value} }
  ROWS = [
    {'pk' => 1, 'root_variant' => V.call('Array(UInt16)', [7, 65_535]),
     'array_variant' => [V.call('LowCardinality(String)', 'red'), V.call('UInt64', 9)],
     'named_recursive' => {'arr' => [1, nil, -3], 'labels' => 'alpha',
                           'choice' => V.call('Array(UInt16)', [0, 65_535])},
     'string0' => 'plain-1', 'string1' => ''},
    {'pk' => 2, 'root_variant' => V.call('String', 'root-string'), 'array_variant' => [],
     'named_recursive' => {'arr' => [], 'labels' => nil,
                           'choice' => V.call('String', 'tuple-string')},
     'string0' => 'plain-2', 'string1' => 'repeat'},
    {'pk' => 3, 'root_variant' => V.call('Array(UInt16)', []),
     'array_variant' => [V.call('LowCardinality(String)', 'red'), V.call('LowCardinality(String)', 'blue')],
     'named_recursive' => {'arr' => [nil], 'labels' => 'alpha', 'choice' => {'type' => 'NULL', 'value' => nil}},
     'string0' => 'plain-3', 'string1' => 'repeat'},
    {'pk' => 4, 'root_variant' => {'type' => 'NULL', 'value' => nil},
     'array_variant' => [V.call('UInt64', 0)],
     'named_recursive' => {'arr' => [99], 'labels' => 'β', 'choice' => V.call('Array(UInt16)', [])},
     'string0' => 'plain-4', 'string1' => "nul\0byte"},
    {'pk' => 5, 'root_variant' => V.call('String', 'root-tail'),
     'array_variant' => [V.call('LowCardinality(String)', 'tail'), V.call('UInt64', 18_446_744_073_709_551_615)],
     'named_recursive' => {'arr' => [0, -2_147_483_648], 'labels' => nil,
                           'choice' => V.call('String', 'tuple-tail')},
     'string0' => 'plain-5', 'string1' => 'last'},
  ].freeze
  TAGS = {
    path: '__W247_PATH__', check_begin: '__W247_CHECK_BEGIN__', check_end: '__W247_CHECK_END__',
    schema: '__W247_SCHEMA__', part: '__W247_PART__', rows: '__W247_ROWS__',
  }.freeze
  LABELS = %w[
    helper_write native_create_input native_attach_check_rows native_create_reemit
    native_reemit_check_rows helper_inspect_reemit
  ].freeze
  MAX_PART_BYTES = 64 * 1024 * 1024
  MAX_STORE_BYTES = 256 * 1024 * 1024
  MAX_STORE_FILES = 20_000
  MAX_FILE_BYTES = W241::MAX_PART_FILE_BYTES
  PROCESS_KEYS = %w[
    label process_kind argv argv_file argv_sha256 stdin_file stdin_bytes stdin_sha256 stdout_file
    stdout_bytes stdout_sha256 stderr_file stderr_bytes stderr_sha256 exit signal timed_out
    timeout_seconds termination_grace_seconds max_threads max_memory_usage_bytes max_memory_usage_applicable
    required_outer_run_safe_memory_limit_bytes binary_path expected_binary_sha256 binary_sha_before
    binary_sha_after spawn_error stdin_write_error stdout_read_error stderr_read_error process_classification store_path
  ].freeze

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

  def self.sig(type, null = false, variant_index = nil, bytes = ''.b, children = [])
    result = ''.b
    result << type.b << "\0".b << (null ? '1' : '0').b << "\0".b
    unless variant_index.nil?
      result << variant_index.to_s.b << "\0".b
    end
    bytes.each_byte { |byte| result << byte.to_s(16).rjust(2, '0').b }
    result << '['.b
    children.each { |child| result << child << ';'.b }
    result << ']'.b
    result
  end

  def self.fixed_unsigned(type, value, width)
    bytes = (0...width).map { |index| (value >> (index * 8)) & 0xff }.pack('C*')
    sig(type, false, nil, bytes)
  end

  def self.fixed_signed(type, value, width)
    bits = value & ((1 << (width * 8)) - 1)
    fixed_unsigned(type, bits, width)
  end

  def self.string_sig(value)
    sig('String', false, nil, value.b)
  end

  def self.array_sig(type, element_signatures)
    sig(type, false, nil, ''.b, element_signatures)
  end

  def self.nullable_sig(type, child = nil)
    child.nil? ? sig(type, true) : sig(type, false, nil, ''.b, [child])
  end

  def self.lc_sig(type, child)
    sig(type, false, nil, ''.b, [child])
  end

  def self.variant_sig(type, declared_arm, child)
    sig(type, false, declared_arm, ''.b, [child])
  end

  def self.value_sig(type, value)
    case type
    when 'String'
      string_sig(value)
    when 'UInt16'
      fixed_unsigned(type, value, 2)
    when 'UInt64'
      fixed_unsigned(type, value, 8)
    when 'Int32'
      fixed_signed(type, value, 4)
    else
      raise Failure, "no signature encoder for #{type}"
    end
  end

  def self.root_variant_sig(value)
    type = TYPES.fetch('root_variant')
    case value.fetch('type')
    when 'NULL'
      sig(type, true)
    when 'Array(UInt16)'
      child = array_sig('Array(UInt16)', value.fetch('value').map { |item| value_sig('UInt16', item) })
      variant_sig(type, 0, child)
    when 'String'
      variant_sig(type, 1, value_sig('String', value.fetch('value')))
    else
      raise Failure, 'unexpected root Variant arm in literal oracle'
    end
  end

  def self.array_variant_sig(values)
    element_type = 'Variant(LowCardinality(String), UInt64)'
    children = values.map do |value|
      case value.fetch('type')
      when 'LowCardinality(String)'
        arm = lc_sig('LowCardinality(String)', value_sig('String', value.fetch('value')))
        variant_sig(element_type, 0, arm)
      when 'UInt64'
        variant_sig(element_type, 1, value_sig('UInt64', value.fetch('value')))
      else
        raise Failure, 'unexpected Array Variant arm in literal oracle'
      end
    end
    array_sig(TYPES.fetch('array_variant'), children)
  end

  def self.tuple_variant_sig(value)
    type = 'Variant(Array(UInt16), String)'
    case value.fetch('type')
    when 'NULL'
      sig(type, true)
    when 'Array(UInt16)'
      array_type = 'Array(UInt16)'
      child = array_sig(array_type, value.fetch('value').map { |item| value_sig('UInt16', item) })
      variant_sig(type, 0, child)
    when 'String'
      variant_sig(type, 1, value_sig('String', value.fetch('value')))
    else
      raise Failure, 'unexpected tuple Variant arm in literal oracle'
    end
  end

  def self.named_recursive_sig(value)
    arr_type = 'Array(Nullable(Int32))'
    arr = array_sig(arr_type, value.fetch('arr').map do |item|
      child = item.nil? ? nil : value_sig('Int32', item)
      nullable_sig('Nullable(Int32)', child)
    end)
    labels_type = 'LowCardinality(Nullable(String))'
    labels_child = if value.fetch('labels').nil?
      nullable_sig('Nullable(String)')
    else
      nullable_sig('Nullable(String)', value_sig('String', value.fetch('labels')))
    end
    labels = lc_sig(labels_type, labels_child)
    sig(TYPES.fetch('named_recursive'), false, nil, ''.b,
        [arr, labels, tuple_variant_sig(value.fetch('choice'))])
  end

  def self.expected_signatures
    TARGET_COLUMNS.each_with_object({}) do |name, result|
      result[name] = ROWS.map do |row|
        case name
        when 'root_variant' then root_variant_sig(row.fetch(name))
        when 'array_variant' then array_variant_sig(row.fetch(name))
        when 'named_recursive' then named_recursive_sig(row.fetch(name))
        end
      end
    end
  end

  def self.expected_native_rows
    ROWS.map do |row|
      root = row.fetch('root_variant')
      choice = row.fetch('named_recursive').fetch('choice')
      labels = row.fetch('named_recursive').fetch('labels')
      {
        'tag' => TAGS[:rows], 'pk' => row.fetch('pk'),
        'root_variant_type' => root.fetch('type'), 'root_variant' => root.fetch('value'),
        'array_variant_types' => row.fetch('array_variant').map { |value| value.fetch('type') },
        'array_variant' => row.fetch('array_variant').map { |value| value.fetch('value') },
        'named_recursive_arr' => row.fetch('named_recursive').fetch('arr'),
        'named_recursive_labels_null' => labels.nil? ? 'NULL' : 'VALUE',
        'named_recursive_labels' => labels,
        'named_recursive_choice_type' => choice.fetch('type'), 'named_recursive_choice' => choice.fetch('value'),
        'string0' => row.fetch('string0'), 'string1' => row.fetch('string1'),
      }
    end
  end

  class Probe
    def initialize(binary:, helper:, evidence_root:, string_profile:)
      @binary = File.expand_path(binary)
      @helper = File.expand_path(helper)
      @root = File.expand_path(evidence_root)
      @profile = string_profile
      require_true(%w[single sized].include?(@profile), 'String profile must be single or sized')
      require_true(File.file?(@binary) && File.executable?(@binary) && !File.symlink?(@binary), 'ClickHouse executable is invalid')
      require_true(File.file?(@helper) && File.executable?(@helper) && !File.symlink?(@helper), 'helper executable is invalid')
      require_true(File.directory?(@root) && !File.symlink?(@root) && File.realpath(@root) == @root &&
                   File.dirname(@root) == File.realpath('/private/tmp') && Dir.children(@root).empty?,
                   'evidence root must be an empty canonical direct child of /private/tmp')
      @repo = File.realpath(File.expand_path('..', __dir__))
      @probe_source = File.realpath(__FILE__)
      @ruby_sources = ProbeStaticBinaryBulkTableW247.ruby_closure(@probe_source)
      @crystal_sources = ProbeStaticBinaryBulkTableW247.crystal_closure([HELPER_SOURCE, FIXTURE_SOURCE], @repo)
      @runner = W241::Probe.new(@binary, @helper, @root, FRAME)
      @invocations = @runner.instance_variable_get(:@invocations)
      @token = Digest::SHA256.hexdigest(@root)[0, 8]
      @input_table = "w247_#{@token}_#{@profile}_input"
      @reemit_table = "w247_#{@token}_#{@profile}_reemit"
    end

    def run
      prepare!
      make_part!
      create_input_table!
      attach_check_and_read!
      create_reemit_table!
      reemit_check_and_read!
      inspect_reemit!
      stable!
      summary = build_summary
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      puts "W247 status=stock_read_and_reemit_observed string=#{@profile} evidence=#{@root}"
      true
    rescue StandardError => error
      warn "W247 inconclusive: #{error.class}: #{error.message}"
      false
    end

    private

    def require_true(value, message)
      raise Failure, "W247: #{message}" unless value
    end

    def sha(path)
      Digest::SHA256.file(path).hexdigest
    end

    def sha_bytes(bytes)
      Digest::SHA256.hexdigest(bytes)
    end

    def write_new(path, bytes)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(bytes) }
    end

    def source_entries(paths)
      paths.map { |path| {'path' => path, 'sha256' => sha(path)} }
    end

    def prepare!
      %w[invocations generated stores parts].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      Dir.mkdir(File.join(@root, 'stores', 'native'), 0o700)
      Dir.mkdir(File.join(@root, 'parts', 'pre_attach'), 0o700)
      @part = File.join(@root, 'generated', PART_NAME)
      @pre_attach = File.join(@root, 'parts', 'pre_attach', PART_NAME)
      @runtime_sha = sha(@binary)
      require_true(@runtime_sha == W241::BINARY_SHA256, 'ClickHouse runtime does not match the pinned W241 binary')
      @helper_sha = sha(@helper)
      @ruby_sha = source_entries(@ruby_sources)
      @crystal_sha = source_entries(@crystal_sources)
      @clickhouse_source_pins = source_pin_inventory
    end

    def stable_sources!
      require_true(source_entries(@ruby_sources) == @ruby_sha, 'Ruby source closure changed during capture')
      require_true(source_entries(@crystal_sources) == @crystal_sha, 'Crystal source closure changed during capture')
    end

    def make_part!
      result = @runner.send(:run_process, 'helper_write', [@helper, 'write', @part, @profile], ''.b,
                            'crystal-helper', expected_sha: @helper_sha, binary_path: @helper)
      assert_helper_success!(result, 'helper_write')
      @generated = snapshot(@part)
      @write_report = parse_helper_report!(result.fetch(:stdout), 'write')
      validate_report!(@write_report, 'write', @part, @generated)
      validate_generated_physical!
      @generated_physical_profile = validate_physical_profile!(@part, @write_report.fetch('physical_profile'), 'generated')
    end

    def create_table_sql(table)
      declarations = ([KEY] + TYPES.map { |name, type| {'name' => name, 'type' => type} }).map do |column|
        "`#{column.fetch('name')}` #{column.fetch('type')}"
      end.join(', ')
      string_setting = @profile == 'single' ? 'single_stream' : 'with_size_stream'
      settings = [
        'index_granularity=2', 'index_granularity_bytes=10485760', 'enable_mixed_granularity_parts=1',
        'min_rows_for_wide_part=0', 'min_bytes_for_wide_part=0', 'min_level_for_wide_part=0',
        'compress_marks=0', 'compress_primary_key=0', 'min_compress_block_size=0', 'max_compress_block_size=4096',
        'ratio_of_defaults_for_sparse_serialization=1.0', "default_compression_codec='LZ4'",
        "serialization_info_version='with_types'", 'use_compact_variant_discriminators_serialization=0',
        'propagate_types_serialization_versions_to_nested_types=true',
        "string_serialization_version='#{string_setting}'",
      ].join(', ')
      "CREATE TABLE default.#{table} (#{declarations}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings};\n" \
        "SELECT '#{TAGS[:path]}', database, name, arrayElement(data_paths, 1) " \
        "FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw;"
    end

    def create_input_table!
      result = native('native_create_input', create_table_sql(@input_table))
      lines = native_lines(result.fetch(:stdout), 'input table create')
      paths = tagged(lines, TAGS[:path], 4)
      require_true(paths.size == 1 && paths[0].values_at(1, 2) == ['default', @input_table], 'stock input-table binding is not unique')
      @input_data_path = @runner.send(:validate_store_path!, paths[0][3])
    end

    def attach_check_and_read!
      @pre_attach_snapshot = begin
        FileUtils.cp_r(@part, @pre_attach, preserve: true)
        snapshot(@pre_attach)
      end
      require_true(@pre_attach_snapshot == @generated, 'pre-attach copy differs from generated bytes')
      @runner.send(:attach_part!, @part, @input_data_path)
      @detached = File.join(@input_data_path, 'detached', PART_NAME)
      @detached_snapshot = snapshot(@detached)
      require_true(@detached_snapshot == @generated, 'detached source differs from generated part')
      sql = [
        "ALTER TABLE default.#{@input_table} ATTACH PART '#{PART_NAME}';",
        "SELECT '#{TAGS[:check_begin]}' FORMAT TSVRaw;",
        "CHECK TABLE default.#{@input_table} FORMAT TSV;",
        "SELECT '#{TAGS[:check_end]}' FORMAT TSVRaw;",
        schema_query(@input_table),
        parts_query(@input_table),
        rows_query(@input_table),
      ].join("\n")
      result = native('native_attach_check_rows', sql)
      lines = native_lines(result.fetch(:stdout), 'stock ATTACH/CHECK/rows')
      @input_check = check_lines(lines)
      require_true(@input_check == ["#{PART_NAME}\t1\t"], 'stock ATTACH CHECK is not exactly CHECK=1')
      @input_schema = tagged(lines, TAGS[:schema], 3).map { |row| row.drop(1) }
      expected_schema = ([KEY] + TYPES.map { |name, type| {'name' => name, 'type' => type} }).map { |column| [column.fetch('name'), column.fetch('type')] }
      require_true(@input_schema == expected_schema, 'stock input schema/type/order differs from independent literal schema')
      part_rows = tagged(lines, TAGS[:part], 7)
      require_true(part_rows.size == 1 && part_rows[0].values_at(1, 2, 4, 5, 6) ==
                   [@input_table, PART_NAME, 'Wide', '5', '4'], 'attached input part is not one five-row Wide part with three marks')
      @input_active_path = @runner.send(:validate_store_path!, part_rows[0][3])
      require_true(@input_active_path == File.join(@input_data_path, PART_NAME), 'attached input part path differs')
      @attached_snapshot = snapshot(@input_active_path)
      verify_attached_files!(@generated, @attached_snapshot)
      @input_rows = parse_native_rows(tagged(lines, TAGS[:rows], 13), 'attached input')
      require_true(@input_rows == ProbeStaticBinaryBulkTableW247.expected_native_rows, 'stock attached rows differ from independent literal oracle')
      @input_part_row = part_rows[0].drop(1)
    end

    def create_reemit_table!
      result = native('native_create_reemit', create_table_sql(@reemit_table))
      lines = native_lines(result.fetch(:stdout), 're-emission table create')
      paths = tagged(lines, TAGS[:path], 4)
      require_true(paths.size == 1 && paths[0].values_at(1, 2) == ['default', @reemit_table], 'stock re-emission table binding is not unique')
      @reemit_data_path = @runner.send(:validate_store_path!, paths[0][3])
    end

    def reemit_check_and_read!
      sql = [
        'SET materialize_statistics_on_insert=0;',
        "INSERT INTO default.#{@reemit_table} SELECT pk, root_variant, array_variant, named_recursive, string0, string1 " \
          "FROM default.#{@input_table} ORDER BY pk;",
        "SELECT '#{TAGS[:check_begin]}' FORMAT TSVRaw;",
        "CHECK TABLE default.#{@reemit_table} FORMAT TSV;",
        "SELECT '#{TAGS[:check_end]}' FORMAT TSVRaw;",
        schema_query(@reemit_table),
        parts_query(@reemit_table),
        rows_query(@reemit_table),
      ].join("\n")
      result = native('native_reemit_check_rows', sql)
      lines = native_lines(result.fetch(:stdout), 'stock re-emission CHECK/rows')
      @reemit_check = check_lines(lines)
      require_true(@reemit_check == ["#{PART_NAME}\t1\t"], 'stock re-emission CHECK is not exactly CHECK=1')
      @reemit_schema = tagged(lines, TAGS[:schema], 3).map { |row| row.drop(1) }
      require_true(@reemit_schema == @input_schema, 'stock rewrite schema/order differs from attached table')
      part_rows = tagged(lines, TAGS[:part], 7)
      require_true(part_rows.size == 1 && part_rows[0].values_at(1, 2, 4, 5, 6) ==
                   [@reemit_table, PART_NAME, 'Wide', '5', '4'], 'stock rewrite is not one five-row Wide part with three marks')
      @reemit_part_path = @runner.send(:validate_store_path!, part_rows[0][3])
      require_true(@reemit_part_path == File.join(@reemit_data_path, PART_NAME), 'stock rewrite part path differs')
      @reemit_snapshot = snapshot(@reemit_part_path)
      @reemit_rows = parse_native_rows(tagged(lines, TAGS[:rows], 13), 'stock rewrite')
      require_true(@reemit_rows == ProbeStaticBinaryBulkTableW247.expected_native_rows, 'stock rewrite rows differ from independent literal oracle')
      @reemit_part_row = part_rows[0].drop(1)
    end

    def inspect_reemit!
      result = @runner.send(:run_process, 'helper_inspect_reemit', [@helper, 'inspect', @reemit_part_path], ''.b,
                            'crystal-helper', expected_sha: @helper_sha, binary_path: @helper)
      assert_helper_success!(result, 'helper_inspect_reemit')
      @inspect_report = parse_helper_report!(result.fetch(:stdout), 'inspect')
      validate_report!(@inspect_report, 'inspect', @reemit_part_path, @reemit_snapshot)
      require_true(@inspect_report.fetch('public_typed_scan') == expected_public_scan, 'stock-written part public typed scan differs')
      require_true(@inspect_report.fetch('offline_values') == expected_offline_values, 'stock-written part offline values differ')
      @reemit_physical_profile = validate_physical_profile!(@reemit_part_path, @inspect_report.fetch('physical_profile'), 'reemit')
    end

    def assert_helper_success!(result, label)
      record = result.fetch(:record)
      require_true(result[:classification] == 'success' && result[:status]&.success? && result[:status]&.termsig.nil? &&
                   result.fetch(:stderr).empty? && !record[:timed_out] && record[:binary_sha_after] == @helper_sha,
                   "#{label} helper process did not complete cleanly")
    end

    def native(label, sql)
      input = [@runner.send(:pin_sql), 'SET print_pretty_type_names=0;', sql].join("\n") + "\n"
      result = @runner.send(:native, label, File.join(@root, 'stores', 'native'), input)
      @runner.send(:assert_native_success!, result, label)
      @runner.send(:assert_pin!, result.fetch(:stdout), label)
      result
    end

    def schema_query(table)
      "SELECT '#{TAGS[:schema]}', name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw;"
    end

    def parts_query(table)
      "SELECT '#{TAGS[:part]}', table, name, path, part_type, toString(rows), toString(marks) " \
        "FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw;"
    end

    def rows_query(table)
      array_types = "hex(toJSONString(arrayMap(x -> variantType(x), array_variant)))"
      expressions = [
        'toString(pk)',
        "if(isNull(root_variant), 'NULL', variantType(root_variant))",
        "if(isNull(root_variant), hex('null'), hex(toJSONString(root_variant)))",
        array_types, 'hex(toJSONString(array_variant))', 'hex(toJSONString(named_recursive.arr))',
        "if(isNull(named_recursive.labels), 'NULL', 'VALUE')",
        "if(isNull(named_recursive.labels), '', hex(named_recursive.labels))",
        "if(isNull(named_recursive.choice), 'NULL', variantType(named_recursive.choice))",
        "if(isNull(named_recursive.choice), hex('null'), hex(toJSONString(named_recursive.choice)))",
        'hex(string0)', 'hex(string1)',
      ]
      "SELECT '#{TAGS[:rows]}', #{expressions.join(', ')} FROM default.#{table} ORDER BY pk FORMAT TSVRaw;"
    end

    def native_lines(stdout, label)
      text = stdout.dup.force_encoding(Encoding::UTF_8)
      require_true(text.valid_encoding? && text.end_with?("\n"), "#{label} stdout is not valid UTF-8 with a final newline")
      lines = text.lines.map(&:chomp)
      pins = lines.select { |line| line.start_with?("__W241_PIN__\t") }
      require_true(pins == ["__W241_PIN__\t#{W241::VERSION}\t#{W241::BUILD}"], "#{label} runtime pin differs")
      lines
    end

    def tagged(lines, tag, width)
      lines.select { |line| line.start_with?(tag + "\t") }.map do |line|
        fields = line.split("\t", -1)
        require_true(fields.size == width, "malformed #{tag} TSV row")
        fields
      end
    end

    def check_lines(lines)
      active = false
      result = []
      lines.each do |line|
        if line == TAGS[:check_begin]
          require_true(!active, 'nested CHECK marker')
          active = true
        elsif line == TAGS[:check_end]
          require_true(active, 'unmatched CHECK end marker')
          active = false
        elsif active
          result << line
        end
      end
      require_true(!active, 'unterminated CHECK markers')
      result
    end

    def parse_json_hex(hex, label)
      require_true(hex.is_a?(String) && /\A(?:[0-9a-fA-F]{2})*\z/.match?(hex), "#{label} is not even-length hex")
      JSON.parse([hex].pack('H*'))
    rescue JSON::ParserError => error
      raise Failure, "#{label} is not JSON: #{error.message}"
    end

    def parse_string_hex(hex, label)
      require_true(hex.is_a?(String) && /\A(?:[0-9a-fA-F]{2})*\z/.match?(hex), "#{label} is not even-length hex")
      value = [hex].pack('H*').force_encoding(Encoding::UTF_8)
      require_true(value.valid_encoding?, "#{label} is not UTF-8")
      value
    end

    def parse_native_rows(rows, label)
      require_true(rows.size == ROWS.size, "#{label} row count differs")
      rows.map do |fields|
        {
          'tag' => fields[0], 'pk' => Integer(fields[1], 10),
          'root_variant_type' => fields[2], 'root_variant' => parse_json_hex(fields[3], 'root Variant JSON'),
          'array_variant_types' => parse_json_hex(fields[4], 'Array Variant type JSON'),
          'array_variant' => parse_json_hex(fields[5], 'Array Variant JSON'),
          'named_recursive_arr' => parse_json_hex(fields[6], 'Tuple Array JSON'),
          'named_recursive_labels_null' => fields[7],
          'named_recursive_labels' => fields[7] == 'NULL' ? nil : parse_string_hex(fields[8], 'Tuple label'),
          'named_recursive_choice_type' => fields[9],
          'named_recursive_choice' => parse_json_hex(fields[10], 'Tuple Variant JSON'),
          'string0' => parse_string_hex(fields[11], 'string0'), 'string1' => parse_string_hex(fields[12], 'string1'),
        }
      end
    end

    def snapshot(path)
      require_true(File.directory?(path) && !File.symlink?(path) && File.realpath(path) == path, "part tree is absent, symlinked, or noncanonical: #{path}")
      entries = []
      total = 0
      Find.find(path) do |item|
        stat = File.lstat(item)
        require_true(!stat.symlink? && (stat.directory? || stat.file?), "part contains a symlink or special entry: #{item}")
        next if stat.directory?
        relative = item.delete_prefix(path + File::SEPARATOR)
        total += stat.size
        require_true(entries.size < 4096 && stat.size <= MAX_FILE_BYTES && total <= MAX_PART_BYTES, 'part exceeds bounded file inventory')
        entries << [relative, stat.size, sha(item)]
      end
      entries.sort
    end

    def canonical_store_target!(path, store_root, label)
      relative = path.delete_prefix(store_root + File::SEPARATOR)
      pieces = relative.split(File::SEPARATOR)
      uuid = pieces[2]
      require_true(pieces.size == 3 && pieces[0] == 'store' && uuid &&
                   /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/.match?(uuid) &&
                   pieces[1] == uuid[0, 3], "#{label} is not a direct store/<prefix>/<UUID> path")
      current = store_root
      pieces.each do |piece|
        current = File.join(current, piece)
        require_true(!File.symlink?(current), "#{label} crosses a symlink")
      end
      require_true(File.directory?(path) && File.realpath(path) == path, "#{label} is absent or noncanonical")
      path
    end

    def metadata_sql(table_uuid)
      string_version = @profile == 'single' ? 'single_stream' : 'with_size_stream'
      declarations = ([KEY] + TYPES.map { |name, type| {'name' => name, 'type' => type} }).map do |column|
        "    `#{column.fetch('name')}` #{column.fetch('type')}"
      end.join(",\n")
      settings = "index_granularity = 2, index_granularity_bytes = 10485760, " \
        "enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0, " \
        "min_bytes_for_wide_part = 0, min_level_for_wide_part = 0, compress_marks = 0, " \
        "compress_primary_key = 0, min_compress_block_size = 0, max_compress_block_size = 4096, " \
        "ratio_of_defaults_for_sparse_serialization = 1., default_compression_codec = 'LZ4', " \
        "serialization_info_version = 'with_types', use_compact_variant_discriminators_serialization = 0, " \
        "propagate_types_serialization_versions_to_nested_types = true, " \
        "string_serialization_version = '#{string_version}'"
      "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n#{declarations}\n)\nENGINE = MergeTree\nORDER BY pk\nSETTINGS #{settings}\n".b
    end

    def validate_store_aliases!(root)
      [@input_data_path, @reemit_data_path].each_with_index do |path, index|
        canonical_store_target!(path, root, index.zero? ? 'input table data path' : 're-emission table data path')
      end
      require_true(@input_data_path != @reemit_data_path, 'input/re-emission data paths are not distinct')
      input_uuid = File.basename(@input_data_path)
      reemit_uuid = File.basename(@reemit_data_path)
      input_name = "data/default/#{@input_table}"
      reemit_name = "data/default/#{@reemit_table}"
      aliases = {}
      [[input_name, @input_data_path, input_uuid], [reemit_name, @reemit_data_path, reemit_uuid]].each do |relative, target, uuid|
        link = File.join(root, relative)
        require_true(File.symlink?(link), "expected Atomic table alias is absent: #{relative}")
        raw = File.readlink(link)
        expected = "../../store/#{uuid[0, 3]}/#{uuid}"
        require_true(raw == expected && File.expand_path(raw, File.dirname(link)) == target &&
                     File.realpath(link) == target, "Atomic table alias target differs: #{relative}")
        aliases[relative] = raw
      end

      metadata_relative = 'metadata/default'
      metadata_link = File.join(root, metadata_relative)
      require_true(File.symlink?(metadata_link), 'expected Atomic metadata alias is absent')
      metadata_raw = File.readlink(metadata_link)
      match = /\A\.\.\/store\/([0-9a-f]{3})\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\z/.match(metadata_raw)
      require_true(match && match[1] == match[2][0, 3], 'Atomic metadata alias text is not the expected relative UUID path')
      metadata_target = File.expand_path(metadata_raw, File.dirname(metadata_link))
      canonical_store_target!(metadata_target, root, 'Atomic metadata directory')
      require_true(metadata_target != @input_data_path && metadata_target != @reemit_data_path,
                   'Atomic metadata alias resolves to a table data directory')
      require_true(File.realpath(metadata_link) == metadata_target,
                   'Atomic metadata alias resolves differently from its literal target')
      expected_files = {
        "#{@input_table}.sql" => metadata_sql(input_uuid),
        "#{@reemit_table}.sql" => metadata_sql(reemit_uuid),
      }
      require_true(Dir.children(metadata_target).sort == expected_files.keys.sort,
                   'Atomic metadata directory has unexpected SQL children')
      expected_files.each do |name, expected_bytes|
        path = File.join(metadata_target, name)
        require_true(File.file?(path) && !File.symlink?(path) && File.realpath(path) == path &&
                     File.size(path) <= MAX_PART_BYTES && File.binread(path) == expected_bytes,
                     "Atomic metadata SQL identity differs: #{name}")
      end
      aliases[metadata_relative] = metadata_raw
      aliases
    end

    def store_snapshot
      root = File.join(@root, 'stores', 'native')
      aliases = validate_store_aliases!(root)
      seen_aliases = []
      entries = []
      total = 0
      Find.find(root) do |item|
        stat = File.lstat(item)
        relative = item.delete_prefix(root + File::SEPARATOR)
        if stat.symlink?
          raw = aliases[relative]
          require_true(raw && File.readlink(item) == raw, "native store has an unexpected symlink or alias target: #{item}")
          seen_aliases << relative
          total += raw.bytesize
          require_true(entries.size < MAX_STORE_FILES && total <= MAX_STORE_BYTES, 'native store exceeds bounded inventory')
          entries << [relative, 'symlink', raw]
          next
        end
        require_true(stat.directory? || stat.file?, "native store has a special entry: #{item}")
        next if stat.directory?
        total += stat.size
        require_true(entries.size < MAX_STORE_FILES && stat.size <= MAX_PART_BYTES && total <= MAX_STORE_BYTES, 'native store exceeds bounded inventory')
        entries << [relative, 'file', stat.size, sha(item)]
      end
      require_true(seen_aliases.sort == aliases.keys.sort, 'native store Atomic alias closure differs')
      entries.sort
    end

    def validate_generated_physical!
      names = @generated.map(&:first)
      expected_columns = "columns format version: 1\n6 columns:\n`pk` UInt64\n" +
        TYPES.map { |name, type| "`#{name}` #{type}\n" }.join
      require_true(File.binread(File.join(@part, 'columns.txt')) == expected_columns.b, 'generated columns.txt differs from independent schema/order')
      require_true(File.binread(File.join(@part, 'count.txt')).strip == '5', 'generated count.txt differs')
      require_true(File.binread(File.join(@part, 'metadata_version.txt')).strip == '0', 'generated metadata version differs')
      require_true(!File.exist?(File.join(@part, 'by_shape.proj')) && !File.symlink?(File.join(@part, 'by_shape.proj')),
                   'parent attach input unexpectedly contains a projection child')
      streams = File.binread(File.join(@part, 'columns_substreams.txt')).lines.map(&:chomp).map do |line|
        line.start_with?("\t") ? line[1..-1] : line
      end
      require_true(streams.include?('pk') && streams.uniq == streams && !streams.empty?, 'generated logical substream roster is malformed')
      mark_files = names.grep(/\.mrk2\z/)
      require_true(!mark_files.empty?, 'generated part has no mark streams')
      @marks = mark_files.sort.map do |name|
        bytes = File.binread(File.join(@part, name))
        tuples = bytes.unpack('Q<*').each_slice(3).to_a
        require_true(bytes.bytesize > 0 && (bytes.bytesize % 24).zero? && tuples.map { |tuple| tuple[2] } == MARKS_WITH_EOF,
                     "generated marks differ for #{name}")
        {'name' => name, 'sha256' => sha_bytes(bytes), 'tuples' => tuples}
      end
    end

    def validate_physical_profile!(part, profile, role)
      names = snapshot(part).map(&:first)
      require_true(names.include?('default_compression_codec.txt') && names.include?('serialization.json') &&
                   names.include?('columns.txt') && names.include?('columns_substreams.txt'),
                   'stock output is missing profile metadata')
      codec = File.binread(File.join(part, 'default_compression_codec.txt')).force_encoding(Encoding::UTF_8)
      require_true(codec.valid_encoding? && codec.strip == 'CODEC(LZ4)', 'stock output codec is not exactly LZ4')
      require_true(names.grep(/\.cmrk\d?\z/).empty? && names.grep(/\.mrk3\z/).empty? &&
                   names.grep(/\.mrk2\z/).size.positive?, 'stock output is not plain mrk2 without compressed marks')
      require_true(names.grep(/\.bin\z/).size.positive?, 'stock output has no Wide .bin streams')
      serialization_bytes = File.binread(File.join(part, 'serialization.json'))
      serialization = JSON.parse(serialization_bytes)
      require_true(serialization.is_a?(Hash), 'stock serialization.json is not an object')
      recorded_columns = serialization.fetch('columns')
      require_true(recorded_columns.is_a?(Array), 'stock serialization.json columns is not an array')
      seen_serialized_names = []
      recorded_columns.each do |entry|
        require_true(entry.is_a?(Hash) && entry['kind'] == 'Default',
                     'stock output contains a non-Default serialization-kind record')
        require_true(!entry.key?('num_rows') || entry['num_rows'] == 5,
                     'stock output serialization record row count differs from the parent count')
        require_true(TYPES.key?(entry['name']) || entry['name'] == KEY.fetch('name'),
                     'stock output serialization record names an undeclared column')
        require_true(!seen_serialized_names.include?(entry['name']), 'stock output serialization record name repeats')
        seen_serialized_names << entry['name']
      end
      versions = serialization.fetch('types_serialization_versions')
      string_version = @profile == 'single' ? 0 : 1
      require_true(versions.is_a?(Hash) && versions['string'] == string_version &&
                   serialization['version'] == 1 &&
                   serialization['propagate_types_serialization_versions_to_nested_types'] == true,
                   'stock serialization metadata does not record the requested String serialization version')
      substreams_bytes = File.binread(File.join(part, 'columns_substreams.txt'))
      substreams_text = substreams_bytes.dup.force_encoding(Encoding::UTF_8)
      require_true(substreams_text.valid_encoding?, 'stock columns_substreams.txt is not UTF-8')
      logical_streams = parse_stock_substreams!(substreams_text)
      expected_variant_sites = {
        'root_variant' => {'type' => TYPES.fetch('root_variant'), 'role' => 'root.discriminators',
                           'logical_stream' => 'root_variant.variant_discr'},
        'array_variant' => {'type' => TYPES.fetch('array_variant'), 'role' => 'root.elements.discriminators',
                            'logical_stream' => 'array_variant.variant_discr'},
        'named_recursive' => {'type' => TYPES.fetch('named_recursive'), 'role' => 'root.field.2.discriminators',
                              'logical_stream' => 'named_recursive%2Echoice.variant_discr'},
      }
      observed_variant_streams = logical_streams.select { |name| name.include?('variant_discr') }
      require_true(observed_variant_streams.sort == expected_variant_sites.values.map { |site| site.fetch('logical_stream') }.sort,
                   'stock output Variant logical streams differ from the independent schema')
      expected_columns_text = "columns format version: 1\n6 columns:\n`pk` UInt64\n" +
        TYPES.map { |name, type| "`#{name}` #{type}\n" }.join
      actual_columns_text = File.binread(File.join(part, 'columns.txt')).force_encoding(Encoding::UTF_8)
      require_true(actual_columns_text.valid_encoding? && actual_columns_text == expected_columns_text,
                   'stock output columns.txt differs from independent schema')
      expected_stream_files = logical_streams.flat_map do |logical|
        stem = W241::Auditor.stream_hash(logical)
        ["#{stem}.bin", "#{stem}.mrk2"]
      end
      require_true(expected_stream_files.uniq.size == expected_stream_files.size, 'stock output logical stream hashes collide')
      actual_stream_files = names.grep(/\A[0-9a-f]{32}\.(?:bin|mrk2|cmrk2|mrk3)\z/)
      require_true(actual_stream_files.sort == expected_stream_files.sort, 'stock output physical stream roster is not exact plain-bin/mrk2')
      require_true(profile.is_a?(Hash), 'helper physical_profile is not an object')
      require_true(profile.keys.sort == %w[
        codec columns_substreams_txt columns_txt physical_stream_files propagate_types_serialization_versions_to_nested_types
        serialization_json_present serialization_version string_serialization_version variant_discriminators
      ].sort, 'helper physical_profile field set differs')
      require_true(profile.fetch('codec') == codec.strip &&
                   profile.fetch('columns_txt') == actual_columns_text &&
                   profile.fetch('columns_substreams_txt') == substreams_text,
                   'helper physical metadata text differs from actual files')
      require_true(profile.fetch('serialization_json_present') == true &&
                   profile.fetch('serialization_version') == serialization['version'] &&
                   profile.fetch('string_serialization_version') == versions['string'] &&
                   profile.fetch('propagate_types_serialization_versions_to_nested_types') == serialization['propagate_types_serialization_versions_to_nested_types'],
                   'helper serialization identity differs from actual serialization.json')
      streams_profile = profile.fetch('physical_stream_files')
      require_true(streams_profile.is_a?(Array), 'helper physical stream file roster is not an array')
      variant_report = profile.fetch('variant_discriminators')
      require_true(variant_report.is_a?(Array), 'helper Variant discriminator profile is not an array')
      require_true(variant_report.size == 3 && variant_report.map { |entry| entry.fetch('column') }.sort == expected_variant_sites.keys.sort,
                   'helper does not enumerate exactly the three declared Variant sites')
      variant_report.each do |entry|
        column = entry.fetch('column')
        expected_site = expected_variant_sites.fetch(column)
        require_true(entry.keys.sort == %w[column decoded_bytes decoded_prefix_hex decoded_sha256 file logical_stream mode mode_word role type].sort,
                     "helper Variant profile fields differ for #{column}")
        require_true(entry.fetch('type') == expected_site.fetch('type') &&
                     entry.fetch('role') == expected_site.fetch('role') &&
                     entry.fetch('logical_stream') == expected_site.fetch('logical_stream') &&
                     entry.fetch('mode_word') == 0 && entry.fetch('mode') == 'BASIC',
                     "helper Variant site identity or BASIC mode differs for #{column}")
      end
      require_true(variant_report.map { |entry| entry.fetch('logical_stream') }.uniq.size == 3,
                   'helper Variant logical stream sites alias')
      decompressed = variant_report.map do |variant_entry|
        logical = variant_entry.fetch('logical_stream')
        filename = "#{W241::Auditor.stream_hash(logical)}.bin"
        require_true(variant_entry.fetch('file') == filename && names.include?(filename),
                     "#{role} part is missing or misidentifies Variant discriminator stream #{logical}")
        compressed = File.binread(File.join(part, filename))
        label = "decompress_#{role}_#{W241::Auditor.stream_hash(logical)}"
        result = @runner.send(:run_process, label, [@binary, 'compressor', '--decompress', '--threads=1'], compressed,
                              'clickhouse-compressor', expected_sha: W241::BINARY_SHA256, binary_path: @binary)
        record = result.fetch(:record)
        require_true(result[:classification] == 'success' && result[:status]&.success? && result[:status]&.termsig.nil? &&
                     result.fetch(:stderr).empty? && result.fetch(:stdout).bytesize >= 8 &&
                     record[:max_threads] == 1 && record[:binary_sha_after] == W241::BINARY_SHA256,
                     "stock Variant discriminator stream decompression failed for #{logical}")
        raw = result.fetch(:stdout)
        mode = raw.unpack1('Q<')
        require_true(mode == 0 && variant_entry.fetch('mode_word') == 0 &&
                     variant_entry.fetch('decoded_bytes') == raw.bytesize &&
                     variant_entry.fetch('decoded_sha256') == sha_bytes(raw) &&
                     variant_entry.fetch('decoded_prefix_hex') == raw.byteslice(0, 8).unpack1('H*'),
                     "#{role} Variant discriminator mode/raw bytes differ for #{logical}")
        {'column' => variant_entry.fetch('column'), 'type' => variant_entry.fetch('type'),
         'role' => variant_entry.fetch('role'), 'logical_stream' => logical, 'physical_file' => filename,
         'physical_sha256' => sha(File.join(part, filename)),
         'decoded_bytes' => raw.bytesize, 'decoded_sha256' => sha_bytes(raw), 'mode_word' => mode,
         'mode_word_le_hex' => raw.byteslice(0, 8).unpack1('H*'), 'invocation_label' => label}
      end
      mark_profiles = names.grep(/\.mrk2\z/).sort.map do |name|
        bytes = File.binread(File.join(part, name))
        require_true(bytes.bytesize.positive? && (bytes.bytesize % 24).zero?, "stock mark file is not plain mrk2: #{name}")
        tuples = bytes.unpack('Q<*').each_slice(3).to_a
        require_true(tuples.map { |tuple| tuple[2] } == MARKS_WITH_EOF, "stock mark row grid differs for #{name}")
        {'name' => name, 'records' => tuples.size, 'rows' => tuples.map { |tuple| tuple[2] }, 'sha256' => sha_bytes(bytes)}
      end
      require_true(mark_profiles.size == logical_streams.size, 'stock mark roster differs from logical substreams')
      expected_profile_streams = actual_stream_files.sort
      reported_profile_streams = streams_profile.map do |entry|
        require_true(entry.is_a?(Hash) && entry.keys.sort == %w[bytes path plain_mark_records].sort,
                     'helper physical stream file entry is malformed')
        {'path' => entry.fetch('path'), 'bytes' => entry.fetch('bytes'),
         'plain_mark_records' => entry.fetch('plain_mark_records')}
      end
      expected_reported_streams = expected_profile_streams.map do |name|
        entry = mark_profiles.find { |mark| mark.fetch('name') == name }
        {'path' => name, 'bytes' => File.size(File.join(part, name)),
         'plain_mark_records' => entry && entry.fetch('records')}
      end
      require_true(reported_profile_streams.sort_by { |entry| entry.fetch('path') } ==
                   expected_reported_streams.sort_by { |entry| entry.fetch('path') },
                   'helper physical stream metadata differs from actual stream/mark files')
      expected_base = %w[checksums.txt columns.txt columns_substreams.txt count.txt default_compression_codec.txt metadata_version.txt primary.idx serialization.json]
      require_true(names.sort == (expected_base + expected_stream_files).sort, 'stock output has an unexpected physical file roster')
      require_true(File.binread(File.join(part, 'count.txt')).strip == '5' &&
                   File.binread(File.join(part, 'metadata_version.txt')).strip == '0',
                   'stock output count/metadata version differ')
      expected_columns_text = "columns format version: 1\n6 columns:\n`pk` UInt64\n" +
        TYPES.map { |name, type| "`#{name}` #{type}\n" }.join
      actual_columns_text = File.binread(File.join(part, 'columns.txt')).force_encoding(Encoding::UTF_8)
      require_true(actual_columns_text.valid_encoding? && actual_columns_text == expected_columns_text,
                   'stock output columns.txt differs from independent schema')
      {'part_type' => role == 'reemit' ? 'Wide' : 'fixture-generated-Wide',
       'codec' => codec.strip, 'mark_extension' => 'mrk2',
       'sparse' => false, 'serialization_json_sha256' => sha_bytes(serialization_bytes),
       'serialization' => serialization, 'string_version' => string_version,
       'columns_text' => actual_columns_text,
       'columns_substreams_text' => substreams_text, 'logical_substreams' => logical_streams,
       'stream_files' => expected_profile_streams, 'mark_profiles' => mark_profiles,
       'variant_modes' => decompressed}
    rescue JSON::ParserError, KeyError => error
      raise Failure, "W247: malformed stock output profile metadata: #{error.message}"
    end

    def parse_stock_substreams!(text)
      lines = text.split("\n", -1)
      require_true(lines.pop == '' && lines.shift == 'columns substreams version: 1',
                   'stock columns_substreams.txt header/version is malformed')
      count_line = lines.shift
      expected_names = ['pk'] + TYPES.keys
      require_true(count_line == "#{expected_names.size} columns:", 'stock columns_substreams column count differs')
      sections = []
      until lines.empty?
        header = lines.shift
        match = /\A(0|[1-9][0-9]*) substreams for column `([a-z][a-z0-9_]*)`:\z/.match(header)
        require_true(match, 'stock columns_substreams section header is malformed')
        count = Integer(match[1], 10)
        require_true(count <= 256 && lines.size >= count, 'stock columns_substreams section exceeds limits')
        streams = Array.new(count) do
          item = lines.shift
          stream_match = /\A\t([A-Za-z0-9_.%]+)\z/.match(item)
          require_true(stream_match, 'stock columns_substreams logical stream line is malformed')
          stream_match[1]
        end
        sections << [match[2], streams]
      end
      require_true(sections.map(&:first) == expected_names, 'stock substream column order differs from literal schema')
      streams = sections.flat_map(&:last)
      require_true(streams.uniq == streams && !streams.empty?, 'stock logical substream roster has aliases or is empty')
      streams
    end

    def source_pin_inventory
      SOURCE_PINS.map do |pin|
        root = File.realpath(pin.fetch('root'))
        require_true(root == pin.fetch('root'), "ClickHouse source root differs: #{pin.fetch('tree')}")
        revision, error, status = Open3.capture3('git', '-C', root, 'rev-parse', 'HEAD')
        require_true(status.success? && error.empty? && revision.strip == pin.fetch('revision'),
                     "ClickHouse source revision differs: #{pin.fetch('tree')}")
        entries = pin.fetch('files').map do |file|
          path = File.join(root, file.fetch('path'))
          require_true(File.file?(path) && !File.symlink?(path) && sha(path) == file.fetch('sha256'),
                       "ClickHouse source pin differs: #{path}")
          {'path' => file.fetch('path'), 'sha256' => sha(path)}
        end
        {'tree' => pin.fetch('tree'), 'root' => root, 'revision' => revision.strip, 'files' => entries}
      end
    end

    def parse_helper_report!(stdout, action)
      text = stdout.dup.force_encoding(Encoding::UTF_8)
      require_true(text.valid_encoding? && text.lines.size == 1 && text.end_with?("\n"), "helper #{action} output is not one JSON line")
      JSON.parse(text)
    rescue JSON::ParserError => error
      raise Failure, "helper #{action} output is not JSON: #{error.message}"
    end

    def validate_report!(report, action, part, inventory)
      expected_signatures = ProbeStaticBinaryBulkTableW247.expected_signatures
      require_true(report.is_a?(Hash), 'helper report is not a JSON object')
      require_true(report.keys.sort == %w[
        action columns declarations files format keys mark_row_counts offline_values part projection_scan
        physical_profile public_typed_scan row_count strings
      ].sort, 'helper report field set differs')
      require_true(report['format'] == HELPER_FORMAT && report['action'] == action && report['part'] == PART_NAME,
                   'helper report identity differs')
      require_true(report['row_count'] == 5 && report['keys'] == KEYS && report['mark_row_counts'] == MARK_ROWS,
                   'helper report key/mark grid differs from the literal oracle')
      require_true(report['declarations'] == {'pk' => 'UInt64'}.merge(TYPES), 'helper declarations differ from independent literal schema')
      require_true(report['strings'] == {
        'string0' => ROWS.map { |row| row.fetch('string0') }, 'string1' => ROWS.map { |row| row.fetch('string1') },
      }, 'helper legacy String accessors differ from literal values')
      require_true(report['columns'].is_a?(Hash) && report['columns'].keys.sort == TARGET_COLUMNS.sort, 'helper recursive column roster differs')
      TARGET_COLUMNS.each do |name|
        column = report['columns'].fetch(name)
        type = TYPES.fetch(name)
        require_true(column.keys.sort == %w[mark_row_counts profile row_sha256 row_signatures type].sort,
                     "helper #{name} report fields differ")
        require_true(column['type'] == type && column['profile'] == @profile && column['mark_row_counts'] == MARK_ROWS,
                     "helper #{name} type/profile/mark contract differs")
        require_true(column['row_signatures'] == expected_signatures.fetch(name), "helper #{name} structural row signatures differ")
        require_true(column['row_sha256'] == expected_signatures.fetch(name).map { |signature| sha_bytes(signature) },
                     "helper #{name} row hashes differ from independently generated signatures")
      end
      require_true(report['public_typed_scan'] == expected_public_scan, 'helper public typed scan does not match the full/select/window oracle')
      require_true(report['offline_values'] == expected_offline_values, 'helper OfflineTable values differ from the literal oracle')
      require_true(report['projection_scan'] == {'status' => 'absent'}, 'projection report is not absent; no synthetic child is accepted')
      report_files = report['files'].map { |entry| [entry.fetch('path'), entry.fetch('size'), entry.fetch('sha256')] }
      require_true(report_files == inventory, 'helper file inventory differs from independently captured bytes')
      require_true(snapshot(part) == inventory, 'part files changed while helper reported them')
    end

    def expected_public_scan
      signatures = ProbeStaticBinaryBulkTableW247.expected_signatures
      {'status' => 'ok', 'row_count' => 5, 'keys' => KEYS,
       'column_signatures' => TARGET_COLUMNS.each_with_object({}) { |name, result| result[name] = signatures.fetch(name) },
       'late_window' => {'keys' => [5], 'column_signatures' => TARGET_COLUMNS.each_with_object({}) do |name, result|
         result[name] = [signatures.fetch(name).last]
       end}}
    end

    def expected_offline_values
      {'status' => 'ok', 'columns' => TARGET_COLUMNS.each_with_object({}) do |name, result|
        result[name] = ProbeStaticBinaryBulkTableW247.expected_signatures.fetch(name)
      end}
    end

    def verify_attached_files!(generated, attached)
      source = generated.each_with_object({}) { |(name, size, digest), memo| memo[name] = [size, digest] }
      target = attached.each_with_object({}) { |(name, size, digest), memo| memo[name] = [size, digest] }
      require_true((source.keys - target.keys).empty? && (target.keys - source.keys) == ['invalidated_system_columns.txt'],
                   'ATTACH changed the part inventory beyond expected invalidation metadata')
      source.each { |name, identity| require_true(target[name] == identity, "ATTACH altered part file #{name}") }
      require_true(File.binread(File.join(@input_active_path, 'invalidated_system_columns.txt')) == "_block_offset\n_block_number\n".b,
                   'ATTACH invalidation metadata differs')
    end

    def stable!
      require_true(snapshot(@part) == @generated && snapshot(@pre_attach) == @pre_attach_snapshot &&
                   snapshot(@input_active_path) == @attached_snapshot && snapshot(@reemit_part_path) == @reemit_snapshot,
                   'one or more part trees changed during capture')
      require_true(!File.exist?(@detached) && !File.symlink?(@detached), 'stock ATTACH left the detached copy behind')
      require_true(sha(@binary) == W241::BINARY_SHA256 && sha(@helper) == @helper_sha, 'runtime/helper changed during capture')
      stable_sources!
      require_true(source_pin_inventory == @clickhouse_source_pins,
                   'pinned ClickHouse source trees changed during capture')
      @runtime_sha_after = sha(@binary)
      @helper_sha_after = sha(@helper)
      @ruby_sha_after = source_entries(@ruby_sources)
      @crystal_sha_after = source_entries(@crystal_sources)
      @store_inventory = store_snapshot
    end

    def build_summary
      {'format' => FORMAT, 'status' => 'stock_read_and_reemit_observed', 'fatal_error' => nil,
       'evidence_root' => @root, 'string_profile' => @profile, 'frame_bytes' => FRAME,
       'schema' => ([KEY] + TYPES.map { |name, type| {'name' => name, 'type' => type} }).map do |column|
         {'name' => column.fetch('name'), 'type' => column.fetch('type')}
       end,
       'keys' => KEYS, 'mark_row_counts' => MARK_ROWS,
       'rows' => ROWS, 'expected_signatures' => ProbeStaticBinaryBulkTableW247.expected_signatures,
       'runtime' => {'path' => @binary, 'sha256_before' => @runtime_sha, 'sha256_after' => @runtime_sha_after,
                     'version' => W241::VERSION, 'build' => W241::BUILD},
       'helper' => {'path' => @helper, 'sha256_before' => @helper_sha, 'sha256_after' => @helper_sha_after},
       'source_pins' => {'ruby_before' => @ruby_sha, 'ruby_after' => @ruby_sha_after,
                         'crystal_before' => @crystal_sha, 'crystal_after' => @crystal_sha_after,
                         'clickhouse_source_before' => @clickhouse_source_pins,
                         'clickhouse_source_after' => source_pin_inventory},
       'limits' => {'timeout_seconds' => W241::TIMEOUT, 'termination_grace_seconds' => W241::GRACE,
                    'max_threads' => 1, 'max_memory_usage_bytes' => W241::MEMORY,
                    'outer_run_safe_memory_limit_bytes' => W241::OUTER_RUN_SAFE_LIMIT,
                    'store_file_limit' => MAX_STORE_FILES, 'store_bytes_limit' => MAX_STORE_BYTES},
       'helper_reports' => {'write' => @write_report, 'reemit_inspect' => @inspect_report},
       'physical_profiles' => {'generated' => @generated_physical_profile,
                               'stock_reemit' => @reemit_physical_profile},
       'parts' => {'generated' => @generated, 'pre_attach' => @pre_attach_snapshot, 'detached' => @detached_snapshot,
                   'attached' => @attached_snapshot, 'reemit' => @reemit_snapshot,
                   'marks' => @marks, 'input_check' => @input_check, 'reemit_check' => @reemit_check,
                   'input_schema' => @input_schema, 'reemit_schema' => @reemit_schema,
                   'input_part' => @input_part_row, 'reemit_part' => @reemit_part_row},
       'native_rows' => {'attached' => @input_rows, 'reemit' => @reemit_rows},
       'invocations' => @invocations,
       'paths' => {'generated' => @part, 'pre_attach' => @pre_attach, 'detached' => @detached,
                   'input_data_path' => @input_data_path, 'attached' => @input_active_path,
                   'reemit_data_path' => @reemit_data_path, 'reemit' => @reemit_part_path},
       'store_inventory' => @store_inventory,
       'interpretation' => 'Crystal wrote the attached parent Wide part; stock ClickHouse ATTACH/CHECK/read is observed. Stock then re-emitted the rows into a stock-written Wide part with the observed LZ4/Default/plain-mrk2/String/BASIC Variant profile, which the helper inspected through WidePartTable public typed scan and OfflineTable.values. Projection interoperability was not tested.'}
    end

  end
end

def main
  options = {}
  parser = OptionParser.new do |opts|
    opts.banner = 'Usage: probe_static_binary_bulk_table_w247.rb --binary PATH --helper PATH --evidence-root EMPTY_DIR --string-profile single|sized'
    opts.on('--binary PATH') { |value| options[:binary] = value }
    opts.on('--helper PATH') { |value| options[:helper] = value }
    opts.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
    opts.on('--string-profile VALUE', %w[single sized]) { |value| options[:string_profile] = value }
  end
  parser.parse!
  abort(parser.to_s) unless ARGV.empty? && %i[binary helper evidence_root string_profile].all? { |key| options.key?(key) }
  begin
    exit(ProbeStaticBinaryBulkTableW247::Probe.new(**options).run ? 0 : 1)
  rescue ProbeStaticBinaryBulkTableW247::Failure, ArgumentError, TypeError => error
    warn "W247 probe: #{error.class}: #{error.message}"
    exit 1
  end
end

main if $PROGRAM_NAME == __FILE__
