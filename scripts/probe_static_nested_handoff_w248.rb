#!/usr/bin/env ruby
# Bounded paired Nested handoff capture. This script only orchestrates the
# prebuilt helper and pinned clickhouse-local executable; it builds nothing.
#
# Usage:
#   ruby scripts/probe_static_nested_handoff_w248.rb \
#     --binary PINNED_CLICKHOUSE --helper PREBUILT_W248_HELPER \
#     --evidence-root EMPTY_DIRECT_CHILD_OF_PRIVATE_TMP \
#     --string-profile single|sized --helper-mode debug|release

require 'digest'
require 'fileutils'
require 'json'
require 'optparse'
require_relative 'probe_object_shared_json_interop_w241'

module ProbeStaticNestedHandoffW248
  W241 = ProbeObjectSharedJSONInteropW241
  FORMAT = 'static_nested_handoff_w248_native_capture_v1'.freeze
  HELPER_FORMAT = 'static_nested_handoff_w248_fixture_v1'.freeze
  HELPER_SOURCE = File.expand_path('check_static_nested_handoff_w248.cr', __dir__).freeze
  FIXTURE_SOURCE = File.expand_path('support/static_nested_handoff_w248_fixture.cr', __dir__).freeze
  PART_NAME = 'all_1_1_0'.freeze
  ATTACH_METADATA_FILE = 'invalidated_system_columns.txt'.freeze
  ATTACH_METADATA_BYTES = "_block_offset\n_block_number\n".b.freeze
  FRAME = 32
  KEYS = [1, 2, 3, 4, 5].freeze
  MARK_ROWS = [2, 2, 1].freeze
  MARK_ROWS_WITH_EOF = [2, 2, 1, 0].freeze
  KEY = {'name' => 'pk', 'type' => 'UInt64'}.freeze
  ROOT_TYPE = 'Nested(label LowCardinality(Nullable(String)), choice Variant(String, UInt64), note String)'.freeze
  ARRAY_PARENT_TYPE = "Tuple(id UInt64, batches Array(#{ROOT_TYPE}))".freeze
  CHILD_TYPE = 'Nested(note String, tags Array(String))'.freeze
  RECURSIVE_TYPE = "Nested(label LowCardinality(Nullable(String)), choice Variant(String, UInt64), note String, child #{CHILD_TYPE})".freeze
  TYPES = {
    'root_nested' => ROOT_TYPE,
    'array_parent' => ARRAY_PARENT_TYPE,
    'recursive_nested' => RECURSIVE_TYPE,
    'string0' => 'String',
    'string1' => 'String',
  }.freeze
  TYPE_TAGS = {
    'root_nested' => 0x2f,
    'array_parent' => 0x20,
    'recursive_nested' => 0x2f,
  }.freeze
  TARGET_COLUMNS = %w[root_nested array_parent recursive_nested].freeze
  STRING_COLUMNS = %w[string0 string1].freeze
  BASE_PART_FILES = %w[
    checksums.txt columns.txt columns_substreams.txt count.txt default_compression_codec.txt
    metadata_version.txt primary.idx serialization.json
  ].freeze
  TAGS = {
    path: '__W248_PATH__', check_begin: '__W248_CHECK_BEGIN__', check_end: '__W248_CHECK_END__',
    schema: '__W248_SCHEMA__', part: '__W248_PART__', rows: '__W248_ROWS__',
  }.freeze
  PROCESS_KEYS = %w[
    label process_kind argv argv_file argv_sha256 stdin_file stdin_bytes stdin_sha256 stdout_file
    stdout_bytes stdout_sha256 stderr_file stderr_bytes stderr_sha256 exit signal timed_out
    timeout_seconds termination_grace_seconds max_threads max_memory_usage_bytes max_memory_usage_applicable
    required_outer_run_safe_memory_limit_bytes binary_path expected_binary_sha256 binary_sha_before
    binary_sha_after spawn_error stdin_write_error stdout_read_error stderr_read_error process_classification store_path
  ].freeze
  MAX_PART_BYTES = 64 * 1024 * 1024
  MAX_FILES = 4096
  MAX_FILE_BYTES = W241::MAX_PART_FILE_BYTES

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
       {'path' => 'src/Storages/MergeTree/MergeTreeData.cpp', 'sha256' => '0e64e089bf72997ea98d0c0ee8a9213c636f1faedd0fdc092e4881877d2b3714'},
       {'path' => 'src/Storages/MergeTree/IMergeTreeDataPart.cpp', 'sha256' => '5dd7c249ac1a79532a0d7d24016a692d5194abd80b904f206f5f7bc9737de935'},
       {'path' => 'src/Storages/MergeTree/IMergeTreeDataPart.h', 'sha256' => '5f6efa47dcece1a1506b87f10d0370eecc1f3665be031702bec92d3e8d82e0ad'},
       {'path' => 'src/Storages/MergeTree/MergeTreeReaderWide.cpp', 'sha256' => '3c1a14d7c401c2ec3028fe2c945b4b2d27bb3f1a4ed6cfd7b3ac9130de6df612'},
     ]},
    {'tree' => 'clickhouse-w238-serializer-snapshot',
     'root' => '/private/tmp/crystal-click-w238.4nQqSo/clickhouse',
     'revision' => 'f25eb93a0b890a3b87df05eb34e2af1f933b4089',
     'files' => [
       {'path' => 'src/DataTypes/Serializations/SerializationVariant.cpp', 'sha256' => '9e91cc5a2aa9498841aa7524193247d55a30c77682c65a0991c77a2968b9e022'},
       {'path' => 'src/DataTypes/Serializations/SerializationVariant.h', 'sha256' => '075e43b8c2ab6f69ad0a5954d08e233568c32905ef145841fa3fb6ab9f03f748'},
       {'path' => 'src/DataTypes/Serializations/SerializationArray.cpp', 'sha256' => '825295e177ae7f406c1a1c155e0c9e17b4cc39f4747cb1f3fb327b54db043791'},
       {'path' => 'src/DataTypes/Serializations/SerializationTuple.cpp', 'sha256' => '12e38b357204e005fc4780bac7e2e358b0a14357e0e246137414166062a1a884'},
       {'path' => 'src/DataTypes/Serializations/SerializationLowCardinality.cpp', 'sha256' => '86fdddb8a6cd30ff440c6230aae884e978738885c916130310ba0413eff7f02a'},
       {'path' => 'src/DataTypes/Serializations/SerializationString.cpp', 'sha256' => '630253117d3b9f2a67ef68f25b3c06286fa38cf85583ddba56f727e331588f03'},
       {'path' => 'src/DataTypes/Serializations/SerializationNullable.cpp', 'sha256' => '7f8f0f97725f21d196beabae47fefcc3bcb32e250f4a1f9a87b37f73eae7c43f'},
       {'path' => 'src/DataTypes/DataTypeNested.cpp', 'sha256' => 'bb0cd02e0c94e0bd8520f6c8a83f64c7089fc47e5dc09f9d72e15f81367f16e4'},
       {'path' => 'src/DataTypes/DataTypeFactory.cpp', 'sha256' => 'a1062d44f84afe86082f7a6fbe3110cabf9a050be7cd108e26171fc0eaa5e478'},
     ]},
  ].freeze

  V = ->(arm, value) { {'arm' => arm, 'value' => value} }
  NESTED = lambda do |*records|
    records.map { |record| record }
  end
  REC = lambda do |label, choice, note|
    {'label' => label, 'choice' => choice, 'note' => note}
  end
  CHILD = lambda do |note, tags|
    {'note' => note, 'tags' => tags}
  end
  ROOT_ROWS = [
    NESTED.call,
    NESTED.call(REC.call('red', V.call('String', 'arm-red'), 'first'),
                REC.call(nil, V.call('UInt64', 42), 'second'),
                REC.call('', V.call('NULL', nil), 'default-null-variant')),
    NESTED.call,
    NESTED.call(REC.call('blue', V.call('UInt64', 0), 'later')),
    NESTED.call(REC.call('red', V.call('String', 'arm-tail'), 'tail'),
                REC.call(nil, V.call('UInt64', 18_446_744_073_709_551_615), 'final')),
  ].freeze
  ARRAY_PARENT_ROWS = [
    {'id' => 1, 'batches' => []},
    {'id' => 2, 'batches' => [ROOT_ROWS[1], ROOT_ROWS[0]]},
    {'id' => 3, 'batches' => []},
    {'id' => 4, 'batches' => [ROOT_ROWS[3]]},
    {'id' => 5, 'batches' => [ROOT_ROWS[4], ROOT_ROWS[2]]},
  ].freeze
  RECURSIVE_ROWS = [
    NESTED.call,
    NESTED.call,
    NESTED.call(
      {'label' => 'red', 'choice' => V.call('String', 'outer-arm'), 'note' => 'outer-first',
       'child' => NESTED.call(CHILD.call('child-empty-tags', []), CHILD.call('child-ragged', %w[r s]))},
      {'label' => nil, 'choice' => V.call('UInt64', 77), 'note' => 'outer-second', 'child' => NESTED.call},
    ),
    NESTED.call(
      {'label' => '', 'choice' => V.call('NULL', nil), 'note' => 'outer-later',
       'child' => NESTED.call(CHILD.call('child-later', ['x']))},
    ),
    NESTED.call(
      {'label' => 'red', 'choice' => V.call('UInt64', 0), 'note' => 'outer-tail', 'child' => NESTED.call},
      {'label' => nil, 'choice' => V.call('String', 'outer-final-arm'), 'note' => 'outer-final',
       'child' => NESTED.call(CHILD.call('child-final', []))},
    ),
  ].freeze
  STRING0 = ['plain-first', 'plain-second', 'plain-middle', "nul\0byte", 'plain-final'].freeze
  STRING1 = ['', 'repeat', 'repeat', "tail\0byte", 'last'].freeze
  ROWS = KEYS.each_index.map do |index|
    {'pk' => KEYS[index], 'root_nested' => ROOT_ROWS[index], 'array_parent' => ARRAY_PARENT_ROWS[index],
     'recursive_nested' => RECURSIVE_ROWS[index], 'string0' => STRING0[index], 'string1' => STRING1[index]}
  end.freeze

  class Failure < StandardError; end

  def self.require_true(value, message)
    raise Failure, "W248: #{message}" unless value
  end

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

  def self.sig(type, null = false, arm = nil, bytes = ''.b, children = [])
    out = ''.b
    out << type.b << "\0".b << (null ? '1' : '0').b << "\0".b
    out << arm.to_s.b << "\0".b unless arm.nil?
    bytes.each_byte { |byte| out << byte.to_s(16).rjust(2, '0').b }
    out << '['.b
    children.each { |child| out << child << ';'.b }
    out << ']'.b
    out
  end

  def self.uint64(value)
    bytes = (0...8).map { |index| (value >> (index * 8)) & 0xff }.pack('C*')
    sig('UInt64', false, nil, bytes)
  end

  def self.string_sig(value)
    sig('String', false, nil, value.b)
  end

  def self.nullable_string(value)
    value.nil? ? sig('Nullable(String)', true) : sig('Nullable(String)', false, nil, ''.b, [string_sig(value)])
  end

  def self.label_sig(value)
    sig('LowCardinality(Nullable(String))', false, nil, ''.b, [nullable_string(value)])
  end

  def self.variant_sig(value)
    type = 'Variant(String, UInt64)'
    case value.fetch('arm')
    when 'NULL' then sig(type, true)
    when 'String' then sig(type, false, 0, ''.b, [string_sig(value.fetch('value'))])
    when 'UInt64' then sig(type, false, 1, ''.b, [uint64(value.fetch('value'))])
    else raise Failure, 'unknown Variant literal arm'
    end
  end

  def self.child_rows_sig(rows)
    rows.map do |row|
      tags = row.fetch('tags').map { |value| string_sig(value) }
      sig('Tuple(note String, tags Array(String))', false, nil, ''.b,
          [string_sig(row.fetch('note')), sig('Array(String)', false, nil, ''.b, tags)])
    end
  end

  def self.nested_sig(type, records)
    children = if type == ROOT_TYPE
      records.map do |record|
        sig('Tuple(label LowCardinality(Nullable(String)), choice Variant(String, UInt64), note String)', false, nil, ''.b,
            [label_sig(record.fetch('label')), variant_sig(record.fetch('choice')), string_sig(record.fetch('note'))])
      end
    elsif type == RECURSIVE_TYPE
      records.map do |record|
        child_type = "Nested(#{CHILD_TYPE.delete_prefix('Nested(').delete_suffix(')')})"
        children = child_rows_sig(record.fetch('child'))
        child = sig(child_type, false, nil, ''.b, children)
        sig("Tuple(label LowCardinality(Nullable(String)), choice Variant(String, UInt64), note String, child #{child_type})",
            false, nil, ''.b,
            [label_sig(record.fetch('label')), variant_sig(record.fetch('choice')), string_sig(record.fetch('note')), child])
      end
    else
      raise Failure, "unknown Nested literal type #{type}"
    end
    sig(type, false, nil, ''.b, children)
  end

  def self.expected_signatures
    {
      'root_nested' => ROOT_ROWS.map { |rows| nested_sig(ROOT_TYPE, rows) },
      'array_parent' => ARRAY_PARENT_ROWS.map do |row|
        batches = row.fetch('batches').map { |nested| nested_sig(ROOT_TYPE, nested) }
        array_type = "Array(#{ROOT_TYPE})"
        sig(ARRAY_PARENT_TYPE, false, nil, ''.b,
            [uint64(row.fetch('id')), sig(array_type, false, nil, ''.b, batches)])
      end,
      'recursive_nested' => RECURSIVE_ROWS.map { |rows| nested_sig(RECURSIVE_TYPE, rows) },
      'string0' => STRING0.map { |value| string_sig(value) },
      'string1' => STRING1.map { |value| string_sig(value) },
    }
  end

  def self.json_rows
    ROWS.map do |row|
      {'pk' => row.fetch('pk'), 'root_nested' => row.fetch('root_nested'),
       'array_parent' => row.fetch('array_parent'), 'recursive_nested' => row.fetch('recursive_nested'),
       'string0' => row.fetch('string0'), 'string1' => row.fetch('string1')}
    end
  end

  def self.source_pin_inventory
    SOURCE_PINS.map do |pin|
      files = pin.fetch('files').map do |entry|
        path = File.join(pin.fetch('root'), entry.fetch('path'))
        require_true(File.file?(path) && !File.symlink?(path), "pinned ClickHouse source file is absent: #{path}")
        observed = Digest::SHA256.file(path).hexdigest
        require_true(observed == entry.fetch('sha256'), "pinned ClickHouse source hash differs: #{path}")
        {'path' => entry.fetch('path'), 'sha256' => observed}
      end
      {'tree' => pin.fetch('tree'), 'root' => pin.fetch('root'), 'revision' => pin.fetch('revision'), 'files' => files}
    end
  end

  class Probe
    def initialize(binary:, helper:, evidence_root:, string_profile:, helper_mode:)
      @binary = File.expand_path(binary)
      @helper = File.expand_path(helper)
      @root = File.expand_path(evidence_root)
      @profile = string_profile
      @helper_mode = helper_mode
      require_true(%w[single sized].include?(@profile), 'String profile must be single or sized')
      require_true(%w[debug release].include?(@helper_mode), 'helper mode must be debug or release')
      require_true(File.file?(@binary) && File.executable?(@binary) && !File.symlink?(@binary), 'ClickHouse executable is invalid')
      require_true(File.file?(@helper) && File.executable?(@helper) && !File.symlink?(@helper), 'helper executable is invalid')
      require_true(File.directory?(@root) && !File.symlink?(@root) && File.realpath(@root) == @root &&
                   File.dirname(@root) == File.realpath('/private/tmp') && Dir.children(@root).empty?,
                   'evidence root must be an empty canonical direct child of /private/tmp')
      @repo = File.realpath(File.expand_path('..', __dir__))
      @probe_source = File.realpath(__FILE__)
      @ruby_sources = ProbeStaticNestedHandoffW248.ruby_closure(@probe_source)
      @crystal_sources = ProbeStaticNestedHandoffW248.crystal_closure([HELPER_SOURCE, FIXTURE_SOURCE], @repo)
      @runner = W241::Probe.new(@binary, @helper, @root, FRAME)
      @invocations = @runner.instance_variable_get(:@invocations)
      @token = Digest::SHA256.hexdigest(@root)[0, 8]
      @input_table = "w248_#{@token}_#{@profile}_input"
      @write_table = "w248_#{@token}_#{@profile}_stockwrite"
    end

    def run
      prepare!
      make_crystal_part!
      create_input_table!
      attach_check_and_read!
      create_stock_write_table!
      stock_write_check_and_read!
      inspect_stock_part!
      stable!
      summary = build_summary
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      puts "W248 status=paired_static_nested_handoff_observed profile=#{@profile} helper_mode=#{@helper_mode} evidence=#{@root}"
      true
    rescue StandardError => error
      warn "W248 inconclusive: #{error.class}: #{error.message}"
      false
    end

    private

    def require_true(value, message)
      ProbeStaticNestedHandoffW248.require_true(value, message)
    end

    def sha(path)
      Digest::SHA256.file(path).hexdigest
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
      @runtime_sha = sha(@binary)
      require_true(@runtime_sha == W241::BINARY_SHA256, 'ClickHouse runtime does not match the pinned W241 executable')
      @helper_sha = sha(@helper)
      @ruby_sha = source_entries(@ruby_sources)
      @crystal_sha = source_entries(@crystal_sources)
      @source_pins = ProbeStaticNestedHandoffW248.source_pin_inventory
    end

    def stable!
      require_true(sha(@binary) == W241::BINARY_SHA256, 'ClickHouse executable changed during capture')
      require_true(sha(@helper) == @helper_sha, 'helper executable changed during capture')
      require_true(source_entries(@ruby_sources) == @ruby_sha, 'Ruby source closure changed during capture')
      require_true(source_entries(@crystal_sources) == @crystal_sha, 'Crystal source closure changed during capture')
      require_true(ProbeStaticNestedHandoffW248.source_pin_inventory == @source_pins, 'pinned ClickHouse source contents changed during capture')
    end

    def assert_helper!(result, label)
      record = result.fetch(:record)
      require_true(result[:classification] == 'success' && result[:status]&.success? && result[:status]&.termsig.nil? &&
                   result.fetch(:stderr).empty? && !record[:timed_out] && record[:binary_sha_after] == @helper_sha,
                   "#{label} helper process did not complete cleanly")
    end

    def invoke_helper(label, action, part)
      argv = [@helper, action, part, @profile]
      result = @runner.send(:run_process, label, argv, ''.b, 'crystal-helper',
                            expected_sha: @helper_sha, binary_path: @helper)
      assert_helper!(result, label)
      lines = result.fetch(:stdout).dup.force_encoding(Encoding::UTF_8).lines.map(&:chomp).reject(&:empty?)
      require_true(lines.size == 1, "#{label} helper must emit one JSON report")
      report = JSON.parse(lines.first)
      require_true(report.fetch('format') == HELPER_FORMAT && report.fetch('action') == action,
                   "#{label} helper report format/action differs")
      [result, report]
    end

    def part_snapshot(path)
      require_true(File.directory?(path) && !File.symlink?(path) && File.realpath(path) == path,
                   "PART tree is absent, symlinked, or noncanonical: #{path}")
      names = Dir.children(path).sort
      require_true(!names.empty? && names.size <= MAX_FILES, 'PART entry count is empty or exceeds its bound')
      total = 0
      names.map do |name|
        file = File.join(path, name)
        stat = File.lstat(file)
        require_true(!stat.symlink? && stat.file?, "PART must be flat and link-free: #{name}")
        total += stat.size
        require_true(stat.size <= MAX_FILE_BYTES && total <= MAX_PART_BYTES, 'PART exceeds file or total byte bound')
        {'path' => name, 'size' => stat.size, 'sha256' => sha(file)}
      end
    end

    def expected_part_names(part, inventory)
      text = File.binread(File.join(part, 'columns_substreams.txt')).force_encoding(Encoding::UTF_8)
      require_true(text.valid_encoding?, 'columns_substreams.txt is not UTF-8')
      streams = text.lines.map { |line| line.start_with?("\t") ? line.chomp.delete_prefix("\t") : nil }.compact
      require_true(!streams.empty? && streams.uniq == streams, 'logical stream roster is empty or duplicated')
      names = BASE_PART_FILES + streams.flat_map do |logical|
        stem = W241::Auditor.stream_hash(logical)
        ["#{stem}.bin", "#{stem}.mrk2"]
      end
      require_true(names.uniq.size == names.size, 'logical stream hashes collide in PART roster')
      names.sort
    end

    def validate_part_roster!(part, inventory, label)
      expected_names = expected_part_names(part, inventory)
      observed_names = inventory.map { |entry| entry.fetch('path') }.sort
      require_true(observed_names == expected_names, "#{label} PART file roster differs from the complete flat Wide roster")
      inventory
    end

    def validate_attached_part!(part, generated_inventory)
      inventory = part_snapshot(part)
      expected_names = expected_part_names(part, inventory) + [ATTACH_METADATA_FILE]
      observed_names = inventory.map { |entry| entry.fetch('path') }.sort
      require_true(observed_names == expected_names.uniq.sort,
                   'attached Crystal PART file roster differs beyond the exact invalidation metadata')
      metadata = File.binread(File.join(part, ATTACH_METADATA_FILE), ATTACH_METADATA_BYTES.bytesize + 1)
      verify_attached_file_identity!(generated_inventory, inventory, metadata)
      inventory
    end

    def verify_attached_file_identity!(generated, attached, metadata)
      source = generated.each_with_object({}) do |entry, map|
        map[entry.fetch('path')] = [entry.fetch('size'), entry.fetch('sha256')]
      end
      target = attached.each_with_object({}) do |entry, map|
        map[entry.fetch('path')] = [entry.fetch('size'), entry.fetch('sha256')]
      end
      require_true(target.keys.sort == (source.keys + [ATTACH_METADATA_FILE]).uniq.sort,
                   'ATTACH changed the part inventory beyond expected invalidation metadata')
      source.each do |name, identity|
        require_true(target[name] == identity, "ATTACH altered generated part file #{name}")
      end
      metadata_identity = [metadata.bytesize, Digest::SHA256.hexdigest(metadata)]
      require_true(metadata == ATTACH_METADATA_BYTES && target[ATTACH_METADATA_FILE] == metadata_identity,
                   'ATTACH invalidation metadata differs from the exact pinned marker bytes')
      true
    end

    def make_crystal_part!
      @crystal_part = File.join(@root, 'generated', PART_NAME)
      result, @write_report = invoke_helper('helper_write', 'write', @crystal_part)
      @generated_inventory = validate_part_roster!(@crystal_part, part_snapshot(@crystal_part), 'Crystal-generated')
      require_true(@write_report.fetch('files') == @generated_inventory, 'helper write report differs from complete generated PART inventory')
      validate_helper_read!(@write_report, 'write', @generated_inventory)
      @helper_write_invocation = result.fetch(:record)
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
        'propagate_types_serialization_versions_to_nested_types=true', "string_serialization_version='#{string_setting}'",
      ].join(', ')
      "SET flatten_nested=0;\nSET allow_suspicious_low_cardinality_types=1;\n" \
        "CREATE TABLE default.#{table} (#{declarations}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings};\n" \
        "SELECT '#{TAGS[:path]}', database, name, arrayElement(data_paths, 1) " \
        "FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw;"
    end

    def native(label, sql)
      input = [@runner.send(:pin_sql), 'SET print_pretty_type_names=0;',
               'SET output_format_json_quote_64bit_integers=0;', sql].join("\n") + "\n"
      result = @runner.send(:native, label, File.join(@root, 'stores', 'native'), input)
      @runner.send(:assert_native_success!, result, label)
      @runner.send(:assert_pin!, result.fetch(:stdout), label)
      result
    end

    def native_lines(stdout, label)
      text = stdout.dup.force_encoding(Encoding::UTF_8)
      require_true(text.valid_encoding? && text.end_with?("\n"), "#{label} stdout is not valid UTF-8 with final newline")
      text.lines.map(&:chomp)
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
      require_true(!active, 'unterminated CHECK marker')
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
      expressions = [
        'toString(pk)', 'hex(toJSONString(root_nested))',
        "hex(toJSONString(arrayMap(x -> if(isNull(x), 'NULL', variantType(x)), root_nested.choice)))",
        'hex(toJSONString(array_parent))',
        "hex(toJSONString(arrayMap(batch -> arrayMap(x -> if(isNull(x), 'NULL', variantType(x)), batch.choice), array_parent.batches)))",
        'hex(toJSONString(recursive_nested))',
        "hex(toJSONString(arrayMap(x -> if(isNull(x), 'NULL', variantType(x)), recursive_nested.choice)))",
        'hex(string0)', 'hex(string1)',
      ]
      "SELECT '#{TAGS[:rows]}', #{expressions.join(', ')} FROM default.#{table} ORDER BY pk FORMAT TSVRaw;"
    end

    def create_input_table!
      result = native('native_create_input', create_table_sql(@input_table))
      paths = tagged(native_lines(result.fetch(:stdout), 'input table create'), TAGS[:path], 4)
      require_true(paths.size == 1 && paths[0].values_at(1, 2) == ['default', @input_table], 'stock input table path binding is not unique')
      @input_data_path = @runner.send(:validate_store_path!, paths[0][3])
      @create_input_invocation = result.fetch(:record)
    end

    def attach_check_and_read!
      @runner.send(:attach_part!, @crystal_part, @input_data_path)
      result = native('native_attach_check_rows', [
        "ALTER TABLE default.#{@input_table} ATTACH PART '#{PART_NAME}';",
        "SELECT '#{TAGS[:check_begin]}' FORMAT TSVRaw;",
        "CHECK TABLE default.#{@input_table} FORMAT TSV;",
        "SELECT '#{TAGS[:check_end]}' FORMAT TSVRaw;",
        schema_query(@input_table), parts_query(@input_table), rows_query(@input_table),
      ].join("\n"))
      lines = native_lines(result.fetch(:stdout), 'stock ATTACH/CHECK/rows')
      @input_check = check_lines(lines)
      require_true(@input_check == ["#{PART_NAME}\t1\t"], 'stock ATTACH CHECK is not exactly CHECK=1')
      @input_schema = tagged(lines, TAGS[:schema], 3).map { |row| row.drop(1) }
      expected_schema = ([KEY] + TYPES.map { |name, type| {'name' => name, 'type' => type} }).map { |column| [column.fetch('name'), column.fetch('type')] }
      require_true(@input_schema == expected_schema, 'stock attached nominal schema/order differs from independent declaration')
      part_rows = tagged(lines, TAGS[:part], 7)
      require_true(part_rows.size == 1 && part_rows[0].values_at(1, 2, 4, 5, 6) ==
                   [@input_table, PART_NAME, 'Wide', '5', '4'], 'attached source is not one five-row Wide part')
      @input_part_path = File.expand_path(part_rows[0][3])
      require_true(@input_part_path == File.join(@input_data_path, PART_NAME), 'attached part path differs from input data directory')
      @attached_inventory = validate_attached_part!(@input_part_path, @generated_inventory)
      @input_native_rows = parse_rows(tagged(lines, TAGS[:rows], 10), 'stock attached')
      require_true(@input_native_rows == expected_native_rows, 'stock attached values differ from independent literal witness')
      @attach_invocation = result.fetch(:record)
    end

    def create_stock_write_table!
      result = native('native_create_stock_write', create_table_sql(@write_table))
      paths = tagged(native_lines(result.fetch(:stdout), 'stock-write table create'), TAGS[:path], 4)
      require_true(paths.size == 1 && paths[0].values_at(1, 2) == ['default', @write_table], 'stock-write table path binding is not unique')
      @write_data_path = @runner.send(:validate_store_path!, paths[0][3])
      @create_write_invocation = result.fetch(:record)
    end

    def sql_string(value)
      "unhex('#{value.b.unpack1('H*')}')"
    end

    def nullable_sql(value)
      value.nil? ? "CAST(NULL, 'Nullable(String)')" : sql_string(value)
    end

    def variant_sql(value)
      case value.fetch('arm')
      when 'NULL' then "CAST(NULL, 'Variant(String, UInt64)')"
      when 'String' then "CAST(#{sql_string(value.fetch('value'))}, 'Variant(String, UInt64)')"
      when 'UInt64' then "CAST(toUInt64(#{value.fetch('value')}), 'Variant(String, UInt64)')"
      else raise Failure, 'unknown stock literal Variant arm'
      end
    end

    def tuple_sql(record)
      "tuple(#{nullable_sql(record.fetch('label'))}, #{variant_sql(record.fetch('choice'))}, #{sql_string(record.fetch('note'))})"
    end

    def nested_sql(type, records)
      contents = records.map { |record| tuple_sql(record) }.join(', ')
      "CAST([#{contents}], '#{type}')"
    end

    def parent_sql(row)
      batches = row.fetch('batches').map { |records| nested_sql(ROOT_TYPE, records) }.join(', ')
      "CAST(tuple(toUInt64(#{row.fetch('id')}), CAST([#{batches}], 'Array(#{ROOT_TYPE})')), '#{ARRAY_PARENT_TYPE}')"
    end

    def child_nested_sql(records)
      children = records.map do |record|
        "tuple(#{sql_string(record.fetch('note'))}, [#{record.fetch('tags').map { |tag| sql_string(tag) }.join(', ')}])"
      end.join(', ')
      "CAST([#{children}], '#{CHILD_TYPE}')"
    end

    def recursive_nested_sql(records)
      contents = records.map do |record|
        "tuple(#{nullable_sql(record.fetch('label'))}, #{variant_sql(record.fetch('choice'))}, " \
          "#{sql_string(record.fetch('note'))}, #{child_nested_sql(record.fetch('child'))})"
      end.join(', ')
      "CAST([#{contents}], '#{RECURSIVE_TYPE}')"
    end

    def stock_insert_sql
      tuples = ROWS.map do |row|
        "(toUInt64(#{row.fetch('pk')}), #{nested_sql(ROOT_TYPE, row.fetch('root_nested'))}, " \
          "#{parent_sql(row.fetch('array_parent'))}, #{recursive_nested_sql(row.fetch('recursive_nested'))}, " \
          "#{sql_string(row.fetch('string0'))}, #{sql_string(row.fetch('string1'))})"
      end
      "SET flatten_nested=0;\nSET allow_suspicious_low_cardinality_types=1;\n" \
        "INSERT INTO default.#{@write_table} VALUES #{tuples.join(",\n")};"
    end

    def stock_write_check_and_read!
      result = native('native_stock_write_check_rows', [
        'SET materialize_statistics_on_insert=0;', stock_insert_sql,
        "SELECT '#{TAGS[:check_begin]}' FORMAT TSVRaw;",
        "CHECK TABLE default.#{@write_table} FORMAT TSV;",
        "SELECT '#{TAGS[:check_end]}' FORMAT TSVRaw;",
        schema_query(@write_table), parts_query(@write_table), rows_query(@write_table),
      ].join("\n"))
      lines = native_lines(result.fetch(:stdout), 'stock write/CHECK/rows')
      @write_check = check_lines(lines)
      require_true(@write_check == ["#{PART_NAME}\t1\t"], 'stock-written CHECK is not exactly CHECK=1')
      @write_schema = tagged(lines, TAGS[:schema], 3).map { |row| row.drop(1) }
      require_true(@write_schema == @input_schema, 'stock-written nominal schema/order differs from attached schema')
      part_rows = tagged(lines, TAGS[:part], 7)
      require_true(part_rows.size == 1 && part_rows[0].values_at(1, 2, 4, 5, 6) ==
                   [@write_table, PART_NAME, 'Wide', '5', '4'], 'stock output is not one five-row Wide part')
      @stock_part_path = File.expand_path(part_rows[0][3])
      require_true(@stock_part_path == File.join(@write_data_path, PART_NAME), 'stock output part path differs from data directory')
      @stock_inventory = validate_part_roster!(@stock_part_path, part_snapshot(@stock_part_path), 'stock-written')
      @stock_native_rows = parse_rows(tagged(lines, TAGS[:rows], 10), 'stock-written')
      require_true(@stock_native_rows == expected_native_rows, 'stock-written values differ from independent literal witness')
      @stock_write_invocation = result.fetch(:record)
    end

    def parse_hex_json(hex, label)
      require_true(hex.is_a?(String) && /\A(?:[0-9a-fA-F]{2})*\z/.match?(hex), "#{label} is not even-length hex")
      JSON.parse([hex].pack('H*'))
    rescue JSON::ParserError => error
      raise Failure, "W248: #{label} is invalid JSON: #{error.message}"
    end

    def parse_hex_string(hex, label)
      require_true(hex.is_a?(String) && /\A(?:[0-9a-fA-F]{2})*\z/.match?(hex), "#{label} is not even-length hex")
      value = [hex].pack('H*').force_encoding(Encoding::UTF_8)
      require_true(value.valid_encoding?, "#{label} is invalid UTF-8")
      value
    end

    def parse_rows(rows, label)
      require_true(rows.size == ROWS.size, "#{label} row count differs")
      rows.map do |fields|
        {'tag' => fields[0], 'pk' => Integer(fields[1], 10),
         'root_nested' => parse_hex_json(fields[2], 'root Nested JSON'),
         'root_variant_types' => parse_hex_json(fields[3], 'root Variant type JSON'),
         'array_parent' => parse_hex_json(fields[4], 'Array parent JSON'),
         'array_parent_variant_types' => parse_hex_json(fields[5], 'Array parent Variant type JSON'),
         'recursive_nested' => parse_hex_json(fields[6], 'recursive Nested JSON'),
         'recursive_variant_types' => parse_hex_json(fields[7], 'recursive Variant type JSON'),
         'string0' => parse_hex_string(fields[8], 'String0'),
         'string1' => parse_hex_string(fields[9], 'String1')}
      end
    end

    def variant_types(records)
      records.map { |record| record.fetch('choice').fetch('arm') }
    end

    def native_variant_value(variant)
      variant.fetch('arm') == 'NULL' ? nil : variant.fetch('value')
    end

    def native_root_nested(records)
      records.map do |record|
        {'label' => record.fetch('label'), 'choice' => native_variant_value(record.fetch('choice')),
         'note' => record.fetch('note')}
      end
    end

    def native_recursive_nested(records)
      records.map do |record|
        children = record.fetch('child').map do |child|
          {'note' => child.fetch('note'), 'tags' => child.fetch('tags')}
        end
        {'label' => record.fetch('label'), 'choice' => native_variant_value(record.fetch('choice')),
         'note' => record.fetch('note'), 'child' => children}
      end
    end

    def expected_native_rows
      ROWS.map do |row|
        {'tag' => TAGS[:rows], 'pk' => row.fetch('pk'),
         'root_nested' => native_root_nested(row.fetch('root_nested')),
         'root_variant_types' => variant_types(row.fetch('root_nested')),
         'array_parent' => {'id' => row.fetch('array_parent').fetch('id'),
                            'batches' => row.fetch('array_parent').fetch('batches').map { |batch| native_root_nested(batch) }},
         'array_parent_variant_types' => row.fetch('array_parent').fetch('batches').map { |batch| variant_types(batch) },
         'recursive_nested' => native_recursive_nested(row.fetch('recursive_nested')),
         'recursive_variant_types' => variant_types(row.fetch('recursive_nested')),
         'string0' => row.fetch('string0'), 'string1' => row.fetch('string1')}
      end
    end

    def validate_helper_read!(report, action, inventory)
      require_true(report.fetch('profile') == @profile && report.fetch('frame_bytes') == FRAME &&
                   report.fetch('row_count') == KEYS.size && report.fetch('keys') == KEYS,
                   "helper #{action} key/profile/frame witness differs")
      require_true(report.fetch('parent_mark_row_counts') == MARK_ROWS, "helper #{action} parent mark grid differs")
      nominal = report.fetch('nominal_binary_columns')
      TARGET_COLUMNS.each do |name|
        entry = nominal.fetch(name)
        require_true(entry.fetch('type') == TYPES.fetch(name) && entry.fetch('tag') == TYPE_TAGS.fetch(name),
                     "helper #{action} nominal descriptor/tag differs for #{name}")
      end
      expected = ProbeStaticNestedHandoffW248.expected_signatures.transform_values do |values|
        values.map { |value| value.force_encoding(Encoding::UTF_8) }
      end
      direct = report.fetch('nominal_binary_columns').transform_values { |entry| entry.fetch('row_signatures') }
      consumers = report.fetch('consumer_signatures')
      table = consumers.fetch('public_typed_table').fetch('columns')
      offline = consumers.fetch('offline_table')
      require_true(direct == expected && table == expected && offline == expected,
                   "helper #{action} direct/table/offline signatures differ from independent literal encoder")
      prefixes = report.fetch('variant_discriminator_prefixes')
      require_true(prefixes.size == TARGET_COLUMNS.size && prefixes.all? do |entry|
        column = entry.fetch('column')
        entry.fetch('nominal_type') == TYPES.fetch(column) && entry.fetch('nominal_tag') == TYPE_TAGS.fetch(column) &&
          entry.fetch('site_type') == 'Variant(String, UInt64)' && entry.fetch('mode') == 'BASIC' &&
          entry.fetch('mode_word') == 0 && entry.fetch('prefix_hex') == '0000000000000000' &&
          entry.fetch('site_tag') == 42 && entry.fetch('arms') == ['String', 'UInt64']
      end, "helper #{action} nominal/inner Variant BASIC prefix witnesses differ")
      nested_marks = report.fetch('recursive_nested_site_marks')
      require_true(nested_marks.size == 2 && nested_marks.all? do |entry|
        entry.fetch('nominal_type') == RECURSIVE_TYPE && entry.fetch('nominal_tag') == 47 &&
          entry.fetch('marks').map(&:last) == MARK_ROWS_WITH_EOF && entry.fetch('first_mark_zero') &&
          entry.fetch('first_populated_mark_advances')
      end, "helper #{action} recursive Nested LC/Variant first-empty-mark evidence differs")
      helper_marks = report.fetch('physical_mark_files')
      require_true(helper_marks.all? { |entry| entry.fetch('records') == 4 } && helper_marks.size > 0,
                   "helper #{action} physical mark file records differ")
      require_true(report.fetch('files') == inventory, "helper #{action} complete flat PART inventory differs")
    end

    def inspect_stock_part!
      result, @inspect_report = invoke_helper('helper_inspect_stock_part', 'inspect', @stock_part_path)
      validate_helper_read!(@inspect_report, 'inspect', @stock_inventory)
      @inspect_invocation = result.fetch(:record)
    end

    def build_summary
      {
        'format' => FORMAT, 'status' => 'paired_static_nested_handoff_observed', 'fatal_error' => nil,
        'evidence_root' => @root, 'string_profile' => @profile, 'helper_mode' => @helper_mode,
        'frame_bytes' => FRAME, 'keys' => KEYS, 'mark_row_counts' => MARK_ROWS,
        'schema' => ([KEY] + TYPES.map { |name, type| {'name' => name, 'type' => type} }),
        'literal_rows' => ROWS, 'expected_signatures' => ProbeStaticNestedHandoffW248.expected_signatures.transform_values { |values| values.map { |value| value.force_encoding(Encoding::UTF_8) } },
        'runtime' => {'path' => @binary, 'sha256' => W241::BINARY_SHA256, 'version' => W241::VERSION,
                      'build' => W241::BUILD, 'source_pins' => @source_pins},
        'helper' => {'path' => @helper, 'sha256' => @helper_sha, 'mode' => @helper_mode},
        'source_closures' => {'ruby' => source_entries(@ruby_sources), 'crystal' => source_entries(@crystal_sources)},
        'helper_reports' => {'write' => @write_report, 'stock_inspect' => @inspect_report},
        'parts' => {'crystal_generated' => {'path' => @crystal_part, 'files' => @generated_inventory},
                    'native_attached' => {'path' => @input_part_path, 'files' => @attached_inventory},
                    'stock_written' => {'path' => @stock_part_path, 'files' => @stock_inventory}},
        'native' => {'input_schema' => @input_schema, 'stock_schema' => @write_schema,
                     'attached_check' => @input_check, 'stock_check' => @write_check,
                     'attached_rows' => @input_native_rows, 'stock_rows' => @stock_native_rows},
        'invocations' => @invocations,
        'limits' => {'native_max_threads' => 1, 'native_max_memory_usage_bytes' => W241::MEMORY,
                     'outer_run_safe_memory_limit_bytes' => W241::OUTER_RUN_SAFE_LIMIT,
                     'timeout_seconds' => W241::TIMEOUT, 'termination_grace_seconds' => W241::GRACE},
        'interpretation' => {
          'crystal_to_stock' => 'The helper writes the complete five-column Wide PART; pinned stock attaches and CHECKs it, verifies exact declared nominal schema/order, and compares independent literal values.',
          'stock_to_crystal' => 'Pinned stock writes the independent literal values into a Wide PART; helper direct BinaryBulkColumnReader, public typed table scan, and OfflineTable materialization match the independent typed-signature encoder.',
          'nominality' => 'The helper reports outer BinaryDataType tags separately from inner Variant site type/path/tag, arm roster, and decoded BASIC prefixes. Native literal witnesses record Variant arm names independently for root Nested, the Array/Nested parent, and recursive Nested; JSON values are value evidence, not nominal identity evidence.',
          'first_mark' => 'The recursive Nested label LC index and Variant discriminator .mrk2 coordinate pairs prove mark zero empty, then mark one-to-two advances after the row3 population; Variant starts after its eight-byte BASIC prefix.',
          'attach_metadata' => 'For the pinned runtime/source only, stock ATTACH adds exactly invalidated_system_columns.txt with bytes _block_offset newline _block_number newline; all generated file identities remain unchanged. This is not a generic virtual-system-column compatibility claim.',
          'scope' => 'Only the generated, native-attached, and stock-written complete link-free PART trees and the named typed consumers are captured. No native-store snapshot, projection interoperability, full-suite, RSS, or performance claim is made.',
          'failure_policy' => 'Any failed or malformed process, exact schema, CHECK, literal value/signature, source closure, profile, prefix, mark, or flat PART roster makes this capture inconclusive.',
        },
      }
    end
  end

  def self.parse_options
    options = {}
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: probe_static_nested_handoff_w248.rb --binary PATH --helper PATH --evidence-root DIR --string-profile single|sized --helper-mode debug|release'
      opts.on('--binary PATH') { |value| options[:binary] = value }
      opts.on('--helper PATH') { |value| options[:helper] = value }
      opts.on('--evidence-root DIR') { |value| options[:evidence_root] = value }
      opts.on('--string-profile NAME') { |value| options[:string_profile] = value }
      opts.on('--helper-mode MODE') { |value| options[:helper_mode] = value }
    end
    parser.parse!
    required = %i[binary helper evidence_root string_profile helper_mode]
    raise OptionParser::MissingArgument, required.find { |key| !options[key] }.to_s unless required.all? { |key| options[key] }
    options
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    options = ProbeStaticNestedHandoffW248.parse_options
    success = ProbeStaticNestedHandoffW248::Probe.new(**options).run
    exit(success ? 0 : 1)
  rescue StandardError => error
    warn "W248 inconclusive: #{error.class}: #{error.message}"
    exit 1
  end
end
