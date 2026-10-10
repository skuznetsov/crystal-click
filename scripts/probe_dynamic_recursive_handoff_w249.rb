#!/usr/bin/env ruby
# Bounded reciprocal Dynamic-bearing Nested handoff capture. This script only
# orchestrates a prebuilt helper and the pinned clickhouse-local executable.
# It performs no build and keeps the stock SQL/value oracle independent from
# the Crystal fixture's expected-value report.
#
# Usage:
#   ruby scripts/probe_dynamic_recursive_handoff_w249.rb \
#     --binary PINNED_CLICKHOUSE --helper PREBUILT_W249_HELPER \
#     --evidence-root EMPTY_DIRECT_CHILD_OF_PRIVATE_TMP \
#     --string-profile single|sized --helper-mode debug|release

require 'digest'
require 'fileutils'
require 'json'
require 'optparse'
require_relative 'probe_object_shared_json_interop_w241'
require_relative 'probe_static_nested_handoff_w248'

module ProbeDynamicRecursiveHandoffW249
  W241 = ProbeObjectSharedJSONInteropW241
  W248 = ProbeStaticNestedHandoffW248
  FORMAT = 'dynamic_recursive_handoff_w249_native_capture_v1'.freeze
  HELPER_FORMAT = 'dynamic_recursive_handoff_w249_helper_v1'.freeze
  HELPER_SOURCE = File.expand_path('check_dynamic_recursive_handoff_w249.cr', __dir__).freeze
  FIXTURE_SOURCE = File.expand_path('support/dynamic_recursive_handoff_w249_fixture.cr', __dir__).freeze
  PART_NAME = 'all_1_1_0'.freeze
  ATTACH_METADATA_FILE = 'invalidated_system_columns.txt'.freeze
  ATTACH_METADATA_BYTES = "_block_offset\n_block_number\n".b.freeze
  FRAME_BYTES = 32
  KEYS = [1, 2, 3, 4, 5].freeze
  MARK_ROWS = [2, 2, 1].freeze
  MARK_ROWS_WITH_EOF = [2, 2, 1, 0].freeze
  KEY_COLUMN = {'name' => 'pk', 'type' => 'UInt64'}.freeze
  COLUMN_TYPES = {
    'root_nested' => 'Nested(d Dynamic(max_types=1), label LowCardinality(Nullable(String)))',
    'array_nested' => 'Array(Nested(d Dynamic(max_types=1), label String))',
    'tuple_parent' => 'Tuple(id UInt64, records Array(Nested(d Dynamic(max_types=1), label String)))',
    'recursive_nested' => 'Nested(d Dynamic(max_types=1), child Nested(d Dynamic(max_types=1), tags Array(String)))',
    'map_parent' => 'Map(UInt64, Nested(d Dynamic(max_types=1), label String))',
  }.freeze
  COLUMNS = COLUMN_TYPES.keys.freeze
  DYNAMIC_SITE_PATHS = {
    'root_nested' => ['root.elements.field.0'],
    'array_nested' => ['root.elements.elements.field.0'],
    'tuple_parent' => ['root.field.1.elements.elements.field.0'],
    'recursive_nested' => ['root.elements.field.0', 'root.elements.field.1.elements.field.0'],
    'map_parent' => ['root.elements.field.1.elements.field.0'],
  }.freeze
  TAGS = {
    path: '__W249_PATH__', check_begin: '__W249_CHECK_BEGIN__', check_end: '__W249_CHECK_END__',
    schema: '__W249_SCHEMA__', part: '__W249_PART__', rows: '__W249_ROWS__',
  }.freeze
  BASE_PART_FILES = %w[
    checksums.txt columns.txt columns_substreams.txt count.txt default_compression_codec.txt
    metadata_version.txt primary.idx serialization.json
  ].freeze
  MAX_FILES = 4096
  MAX_PART_BYTES = 64 * 1024 * 1024

  # This is a source comparison pin, independent from the runtime executable
  # pin in W241 and from the older serializer snapshots in W248.
  CURRENT_SOURCE = {
    'tree' => 'clickhouse-2026-10-10-depth1',
    'root' => '/private/tmp/clickhouse-w249-upstream-P7bxRQ',
    'revision' => 'fe0f91b6c3de9e1efa33a1bce4ca9bcbfb4c509d',
    'commit_time_utc' => '2026-10-10T09:01:51Z',
    'files' => [
      {'path' => 'src/DataTypes/DataTypeNested.cpp', 'sha256' => 'bb0cd02e0c94e0bd8520f6c8a83f64c7089fc47e5dc09f9d72e15f81367f16e4'},
      {'path' => 'src/DataTypes/DataTypeNested.h', 'sha256' => '13b83105c8ea7c8c808533fd8a408f7d79a4856a5c8183686a9eb6c05bd1e928'},
      {'path' => 'src/DataTypes/DataTypeArray.cpp', 'sha256' => 'a830a6d44d7bc6424be8053ae6505f3121b4c668a497aa5b1309fadc6bdb3a51'},
      {'path' => 'src/DataTypes/DataTypeArray.h', 'sha256' => '660e6f37210922c200a7cbba5f25a0f01d579f79a51611768de72d1a3002be37'},
      {'path' => 'src/DataTypes/DataTypeTuple.cpp', 'sha256' => '350d50a6d0c5cefbf8b31bad1106f7e2200cc69ada1bac50704723d66edde2a0'},
      {'path' => 'src/DataTypes/DataTypeTuple.h', 'sha256' => '9ebb2d555efa56456e4d57d873dcdbf231e48c96fcf87fa41d067f8073e9953b'},
      {'path' => 'src/DataTypes/DataTypeMap.cpp', 'sha256' => 'dfc839fd14ad6f0b726d65cdc266622cc62912cc48adfb60e61bdb0b49752c73'},
      {'path' => 'src/DataTypes/DataTypeDynamic.cpp', 'sha256' => 'fec7e50ab5abee89ce79a953448ca7d7dca0aa9f9430c94a4deb2346dd74d4cc'},
      {'path' => 'src/DataTypes/DataTypeDynamic.h', 'sha256' => '25136ab2047032e8e86b382f3864f92144ee600b150d4e95cb8827a8dbfff2fd'},
      {'path' => 'src/DataTypes/IDataType.cpp', 'sha256' => 'b4535a47d35b79fb142db828ae202d610b97055a06f5a782f4adcf7d66c593b0'},
      {'path' => 'src/DataTypes/Serializations/SerializationArray.cpp', 'sha256' => '825295e177ae7f406c1a1c155e0c9e17b4cc39f4747cb1f3fb327b54db043791'},
      {'path' => 'src/DataTypes/Serializations/SerializationTuple.cpp', 'sha256' => '12e38b357204e005fc4780bac7e2e358b0a14357e0e246137414166062a1a884'},
      {'path' => 'src/DataTypes/Serializations/SerializationMap.cpp', 'sha256' => '6bcc6c110c23ca0b0e77aa753aab6757fcfd7050960824b547c71744bc0fd3e1'},
      {'path' => 'src/DataTypes/Serializations/SerializationDynamic.cpp', 'sha256' => '691029f31451f9e7f431922f8764764125ef434c3bd9ddf3868efc7742ba890a'},
      {'path' => 'src/DataTypes/Serializations/SerializationInfoTuple.cpp', 'sha256' => 'dc68ad9f29feacab323d5c6f1d42340d721e3b619fca1465821f63f5898e1fb8'},
    ],
  }.freeze

  # The stock oracle is deliberately written here rather than imported from
  # the Crystal fixture. Each Dynamic literal has its expected actual type.
  D = ->(type, value) { {'type' => type, 'value' => value} }
  ROOT = lambda do |*pairs|
    pairs.map { |pair, label| {'d' => pair, 'label' => label} }
  end
  CHILD = lambda do |*pairs|
    pairs.map { |pair, tags| {'d' => pair, 'tags' => tags} }
  end
  ROWS = [
    {'pk' => 1, 'root_nested' => ROOT.call, 'array_nested' => [],
     'tuple_parent' => {'id' => 1, 'records' => []}, 'recursive_nested' => ROOT.call,
     'map_parent' => []},
    {'pk' => 2, 'root_nested' => ROOT.call, 'array_nested' => [],
     'tuple_parent' => {'id' => 2, 'records' => []}, 'recursive_nested' => ROOT.call,
     'map_parent' => []},
    {'pk' => 3,
     'root_nested' => ROOT.call([D.call('Int64', 7), 'root-a'], [D.call('NULL', nil), nil],
                                [D.call('String', 'root-shared'), 'root-b']),
     'array_nested' => [[{'d' => D.call('Int64', 9), 'label' => 'array-a'},
                         {'d' => D.call('String', 'array-shared'), 'label' => 'array-b'}]],
     'tuple_parent' => {'id' => 3, 'records' => [[
       {'d' => D.call('Int64', 11), 'label' => 'tuple-a'},
       {'d' => D.call('NULL', nil), 'label' => 'tuple-null'},
     ]]},
     'recursive_nested' => [
       {'d' => D.call('Int64', 13), 'child' => CHILD.call([D.call('NULL', nil), ['x']],
                                                          [D.call('String', 'child-shared'), []])},
     ],
     'map_parent' => [[17, [{'d' => D.call('Int64', 19), 'label' => 'map-a'},
                            {'d' => D.call('String', 'map-shared'), 'label' => 'map-b'}]]]},
    {'pk' => 4, 'root_nested' => ROOT.call, 'array_nested' => [[]],
     'tuple_parent' => {'id' => 4, 'records' => []}, 'recursive_nested' => ROOT.call,
     'map_parent' => []},
    {'pk' => 5,
     'root_nested' => ROOT.call([D.call('String', 'root-tail'), 'tail'], [D.call('Int64', 23), nil]),
     'array_nested' => [[{'d' => D.call('NULL', nil), 'label' => 'array-null'}], [],
                        [{'d' => D.call('Int64', 29), 'label' => 'array-tail'}]],
     'tuple_parent' => {'id' => 5, 'records' => [[
       {'d' => D.call('Int64', 31), 'label' => 'tuple-tail'},
       {'d' => D.call('String', 'tuple-shared-tail'), 'label' => 'tuple-spill'},
     ]]},
     'recursive_nested' => [
       {'d' => D.call('NULL', nil), 'child' => CHILD.call},
       {'d' => D.call('String', 'parent-shared'),
        'child' => CHILD.call([D.call('Int64', 37), []], [D.call('NULL', nil), %w[tail tags]])},
     ],
     'map_parent' => [[41, [{'d' => D.call('NULL', nil), 'label' => 'map-null'}]], [43, []]]},
  ].freeze

  class Failure < StandardError; end

  def self.require_true(value, message)
    raise Failure, "W249: #{message}" unless value
  end

  def self.source_pin_inventory
    older = W248.source_pin_inventory
    current_files = CURRENT_SOURCE.fetch('files').map do |entry|
      path = File.join(CURRENT_SOURCE.fetch('root'), entry.fetch('path'))
      require_true(File.file?(path) && !File.symlink?(path), "current upstream source file is absent: #{path}")
      observed = Digest::SHA256.file(path).hexdigest
      require_true(observed == entry.fetch('sha256'), "current upstream source hash differs: #{path}")
      {'path' => entry.fetch('path'), 'sha256' => observed}
    end
    older + [{'tree' => CURRENT_SOURCE.fetch('tree'), 'root' => CURRENT_SOURCE.fetch('root'),
              'revision' => CURRENT_SOURCE.fetch('revision'), 'commit_time_utc' => CURRENT_SOURCE.fetch('commit_time_utc'),
              'files' => current_files}]
  end

  def self.expected_type_rows
    ROWS.map do |row|
      {
        'pk' => row.fetch('pk'),
        'root_nested' => row.fetch('root_nested').map { |record| record.fetch('d').fetch('type') },
        'array_nested' => row.fetch('array_nested').map { |records| records.map { |record| record.fetch('d').fetch('type') } },
        'tuple_parent' => row.fetch('tuple_parent').fetch('records').map do |records|
          records.map { |record| record.fetch('d').fetch('type') }
        end,
        'recursive_nested' => row.fetch('recursive_nested').map { |record| record.fetch('d').fetch('type') },
        'recursive_child' => row.fetch('recursive_nested').map do |record|
          record.fetch('child').map { |child| child.fetch('d').fetch('type') }
        end,
        'map_parent' => row.fetch('map_parent').map do |_key, records|
          records.map { |record| record.fetch('d').fetch('type') }
        end,
      }
    end
  end

  def self.expected_value_rows
    ROWS.map do |row|
      {
        'pk' => row.fetch('pk'),
        'root_nested' => row.fetch('root_nested').map { |record| json_record(record) },
        'array_nested' => row.fetch('array_nested').map { |records| records.map { |record| json_record(record) } },
        'tuple_parent' => {
          'id' => row.fetch('tuple_parent').fetch('id'),
          'records' => row.fetch('tuple_parent').fetch('records').map do |records|
            records.map { |record| json_record(record) }
          end,
        },
        'recursive_nested' => row.fetch('recursive_nested').map do |record|
          {'d' => record.fetch('d').fetch('value'),
           'child' => record.fetch('child').map { |child| json_record(child) }}
        end,
        'map_keys' => row.fetch('map_parent').map(&:first),
        'map_values' => row.fetch('map_parent').map do |_key, records|
          records.map { |record| json_record(record) }
        end,
      }
    end
  end

  def self.json_record(record)
    {'d' => record.fetch('d').fetch('value')}.merge(record.reject { |key, _| key == 'd' })
  end

  def self.helper_dynamic_pair(value)
    [value.fetch('type'), value.fetch('value')]
  end

  def self.helper_nested_records(records, child: false)
    records.map do |record|
      tail = if child
               record.fetch('tags')
             else
               record.fetch('label')
             end
      [helper_dynamic_pair(record.fetch('d')), tail]
    end
  end

  def self.expected_helper_rows
    ROWS.map do |row|
      {
        'pk' => row.fetch('pk'),
        'root_nested' => helper_nested_records(row.fetch('root_nested')),
        'array_nested' => row.fetch('array_nested').map { |records| helper_nested_records(records) },
        'tuple_parent' => [row.fetch('tuple_parent').fetch('id'),
                           row.fetch('tuple_parent').fetch('records').map { |records| helper_nested_records(records) }],
        'recursive_nested' => row.fetch('recursive_nested').map do |record|
          [helper_dynamic_pair(record.fetch('d')), helper_nested_records(record.fetch('child'), child: true)]
        end,
        'map_parent' => row.fetch('map_parent').map do |key, records|
          [key, helper_nested_records(records)]
        end,
      }
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
      @ruby_sources = W248.ruby_closure(File.realpath(__FILE__))
      @crystal_sources = W248.crystal_closure([HELPER_SOURCE, FIXTURE_SOURCE], @repo)
      @runner = W241::Probe.new(@binary, @helper, @root, FRAME_BYTES)
      @invocations = @runner.instance_variable_get(:@invocations)
      @token = Digest::SHA256.hexdigest(@root)[0, 8]
      @input_table = "w249_#{@token}_#{@profile}_input"
      @write_table = "w249_#{@token}_#{@profile}_stockwrite"
    end

    def run
      prepare!
      make_library_part!
      create_input_table!
      attach_check_and_read!
      create_stock_write_table!
      stock_write_check_and_read!
      inspect_stock_part!
      stable!
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(build_summary) + "\n")
      puts "W249 status=paired_dynamic_recursive_handoff_observed profile=#{@profile} helper_mode=#{@helper_mode} evidence=#{@root}"
      true
    rescue StandardError => error
      warn "W249 inconclusive: #{error.class}: #{error.message}"
      false
    end

    private

    def require_true(value, message)
      ProbeDynamicRecursiveHandoffW249.require_true(value, message)
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
      @source_pins = ProbeDynamicRecursiveHandoffW249.source_pin_inventory
    end

    def stable!
      require_true(sha(@binary) == W241::BINARY_SHA256, 'ClickHouse executable changed during capture')
      require_true(sha(@helper) == @helper_sha, 'helper executable changed during capture')
      require_true(source_entries(@ruby_sources) == @ruby_sha, 'Ruby source closure changed during capture')
      require_true(source_entries(@crystal_sources) == @crystal_sha, 'Crystal source closure changed during capture')
      require_true(ProbeDynamicRecursiveHandoffW249.source_pin_inventory == @source_pins,
                   'pinned ClickHouse source contents changed during capture')
    end

    def assert_process_success!(result, label, binary_sha)
      record = result.fetch(:record)
      require_true(result[:classification] == 'success' && result[:status]&.success? && result[:status]&.termsig.nil? &&
                   result.fetch(:stderr).empty? && !record[:timed_out] && record[:binary_sha_after] == binary_sha,
                   "#{label} process did not complete cleanly")
    end

    def invoke_helper(label, *arguments)
      result = @runner.send(:run_process, label, [@helper, *arguments], ''.b, 'crystal-helper',
                            expected_sha: @helper_sha, binary_path: @helper)
      assert_process_success!(result, label, @helper_sha)
      lines = result.fetch(:stdout).dup.force_encoding(Encoding::UTF_8).lines.map(&:chomp).reject(&:empty?)
      require_true(lines.size == 1, "#{label} helper must emit one JSON report")
      report = JSON.parse(lines.first)
      require_true(report.fetch('format') == HELPER_FORMAT && report.fetch('action') == arguments.first,
                   "#{label} helper report format/action differs")
      [result, report]
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

    def stream_names(part)
      text = File.binread(File.join(part, 'columns_substreams.txt')).force_encoding(Encoding::UTF_8)
      require_true(text.valid_encoding?, 'columns_substreams.txt is not valid UTF-8')
      names = text.lines.each_with_object([]) do |line, found|
        found << line.chomp.delete_prefix("\t") if line.start_with?("\t")
      end
      require_true(!names.empty? && names.uniq == names, 'logical stream roster is empty or duplicated')
      names
    end

    def expected_part_names(part)
      streams = stream_names(part)
      names = BASE_PART_FILES + streams.flat_map do |logical|
        stem = W241::Auditor.stream_hash(logical)
        ["#{stem}.bin", "#{stem}.mrk2"]
      end
      require_true(names.uniq.size == names.size, 'logical stream hash collision in PART roster')
      names.sort
    end

    def part_snapshot(path, allow_attach_marker: false)
      require_true(File.directory?(path) && !File.symlink?(path) && File.realpath(path) == path,
                   "PART tree is absent, symlinked, or noncanonical: #{path}")
      names = Dir.children(path).sort
      require_true(!names.empty? && names.size <= MAX_FILES, 'PART entry count is empty or exceeds its bound')
      total = 0
      inventory = names.map do |name|
        file = File.join(path, name)
        stat = File.lstat(file)
        require_true(!stat.symlink? && stat.file?, "PART must be flat and link-free: #{name}")
        total += stat.size
        require_true(stat.size <= W241::MAX_PART_FILE_BYTES && total <= MAX_PART_BYTES,
                     'PART exceeds file or total byte bound')
        {'path' => name, 'size' => stat.size, 'sha256' => sha(file)}
      end
      expected_names = expected_part_names(path)
      expected_names += [ATTACH_METADATA_FILE] if allow_attach_marker
      require_true(inventory.map { |entry| entry.fetch('path') }.sort == expected_names.sort,
                   'PART file roster differs from the complete flat Wide roster')
      inventory
    end

    def validate_attached_part!(path, generated)
      attached = part_snapshot(path, allow_attach_marker: true)
      by_name = attached.to_h { |entry| [entry.fetch('path'), entry] }
      require_true(by_name.keys.sort == (generated.map { |entry| entry.fetch('path') } + [ATTACH_METADATA_FILE]).sort,
                   'ATTACH changed the PART roster beyond exact invalidation metadata')
      generated.each do |entry|
        require_true(by_name.fetch(entry.fetch('path')) == entry, "ATTACH altered file #{entry.fetch('path')}")
      end
      marker = File.binread(File.join(path, ATTACH_METADATA_FILE), ATTACH_METADATA_BYTES.bytesize + 1)
      require_true(marker == ATTACH_METADATA_BYTES &&
                   by_name.fetch(ATTACH_METADATA_FILE) == {'path' => ATTACH_METADATA_FILE,
                     'size' => marker.bytesize, 'sha256' => Digest::SHA256.hexdigest(marker)},
                   'ATTACH invalidation marker differs from exact pinned bytes')
      attached
    end

    def string_setting
      @profile == 'single' ? 'single_stream' : 'with_size_stream'
    end

    def create_table_sql(table)
      columns = ([KEY_COLUMN] + COLUMN_TYPES.map { |name, type| {'name' => name, 'type' => type} }).map do |column|
        "`#{column.fetch('name')}` #{column.fetch('type')}"
      end.join(', ')
      settings = [
        # Match W248's adaptive Wide target so the stock side writes .mrk2
        # marks, including its EOF sentinel, for the frozen [2, 2, 1] grid.
        'index_granularity=2', 'index_granularity_bytes=10485760', 'enable_mixed_granularity_parts=1',
        'min_rows_for_wide_part=0', 'min_bytes_for_wide_part=0', 'min_level_for_wide_part=0',
        'compress_marks=0', 'compress_primary_key=0', 'min_compress_block_size=0', 'max_compress_block_size=4096',
        'ratio_of_defaults_for_sparse_serialization=1.0', "default_compression_codec='LZ4'",
        "serialization_info_version='with_types'", 'use_compact_variant_discriminators_serialization=0',
        'propagate_types_serialization_versions_to_nested_types=true', "string_serialization_version='#{string_setting}'",
      ].join(', ')
      "SET flatten_nested=0;\nSET allow_suspicious_low_cardinality_types=1;\n" \
        "CREATE TABLE default.#{table} (#{columns}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings};\n" \
        "SELECT '#{TAGS[:path]}', database, name, arrayElement(data_paths, 1) " \
        "FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw;"
    end

    def create_table!(label, table)
      result = native(label, create_table_sql(table))
      paths = tagged(native_lines(result.fetch(:stdout), label), TAGS[:path], 4)
      require_true(paths.size == 1 && paths[0].values_at(1, 2) == ['default', table], "#{label} path binding is not unique")
      path = @runner.send(:validate_store_path!, paths[0][3])
      [path, result.fetch(:record)]
    end

    def make_library_part!
      @library_part = File.join(@root, 'generated', PART_NAME)
      result, @write_report = invoke_helper('helper_write_library_part', 'write', @library_part, @profile)
      @generated_inventory = part_snapshot(@library_part)
      validate_helper_report!(@write_report, 'write')
      @helper_write_invocation = result.fetch(:record)
    end

    def create_input_table!
      @input_data_path, @create_input_invocation = create_table!('native_create_input', @input_table)
    end

    def attach_check_and_read!
      @runner.send(:attach_part!, @library_part, @input_data_path)
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
      require_true(@input_schema == expected_schema, 'stock attached nominal schema/order differs from independent declaration')
      part_rows = tagged(lines, TAGS[:part], 7)
      require_true(part_rows.size == 1 && part_rows[0].values_at(1, 2, 4, 5, 6) ==
                   [@input_table, PART_NAME, 'Wide', '5', '4'], 'attached source is not one five-row Wide part')
      @input_part_path = File.expand_path(part_rows[0][3])
      require_true(@input_part_path == File.join(@input_data_path, PART_NAME), 'attached PART path differs from table data directory')
      @attached_inventory = validate_attached_part!(@input_part_path, @generated_inventory)
      @input_rows = parse_native_rows(tagged(lines, TAGS[:rows], 14), 'stock attached')
      require_true(@input_rows == expected_native_rows, 'stock attached typed values differ from independent literal witness')
      @attach_invocation = result.fetch(:record)
    end

    def create_stock_write_table!
      @write_data_path, @create_write_invocation = create_table!('native_create_stock_write', @write_table)
    end

    def sql_string(value)
      "unhex('#{value.b.unpack1('H*')}')"
    end

    def dynamic_sql(value)
      case value.fetch('type')
      when 'NULL' then 'NULL'
      when 'Int64' then "toInt64(#{value.fetch('value')})"
      when 'String' then sql_string(value.fetch('value'))
      else raise Failure, "unrostered Dynamic type #{value.fetch('type').inspect}"
      end
    end

    def records_sql(records, with_tags: false)
      records.map do |record|
        fields = [dynamic_sql(record.fetch('d'))]
        fields << "[#{record.fetch('tags').map { |tag| sql_string(tag) }.join(', ')}]" if with_tags
        if record.key?('label')
          label = record.fetch('label')
          fields << (label.nil? ? 'NULL' : sql_string(label))
        end
        "tuple(#{fields.join(', ')})"
      end.join(', ')
    end

    def nested_sql(records, with_tags: false)
      "[#{records_sql(records, with_tags: with_tags)}]"
    end

    def stock_insert_sql
      tuples = ROWS.map do |row|
        array_nested = "[#{row.fetch('array_nested').map { |records| nested_sql(records) }.join(', ')}]"
        tuple_records = "[#{row.fetch('tuple_parent').fetch('records').map { |records| nested_sql(records) }.join(', ')}]"
        recursive = row.fetch('recursive_nested').map do |record|
          "tuple(#{dynamic_sql(record.fetch('d'))}, #{nested_sql(record.fetch('child'), with_tags: true)})"
        end.join(', ')
        map_entries = row.fetch('map_parent').map do |key, records|
          "toUInt64(#{key}), #{nested_sql(records)}"
        end.join(', ')
        map_value = map_entries.empty? ? 'map()' : "map(#{map_entries})"
        "(toUInt64(#{row.fetch('pk')}), #{nested_sql(row.fetch('root_nested'))}, #{array_nested}, " \
          "tuple(toUInt64(#{row.fetch('tuple_parent').fetch('id')}), #{tuple_records}), " \
          "[#{recursive}], #{map_value})"
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
      require_true(@write_schema == expected_schema, 'stock-written nominal schema/order differs from independent declaration')
      part_rows = tagged(lines, TAGS[:part], 7)
      require_true(part_rows.size == 1 && part_rows[0].values_at(1, 2, 4, 5, 6) ==
                   [@write_table, PART_NAME, 'Wide', '5', '4'], 'stock output is not one five-row Wide part')
      @stock_part_path = File.expand_path(part_rows[0][3])
      require_true(@stock_part_path == File.join(@write_data_path, PART_NAME), 'stock output PART path differs from data directory')
      @stock_inventory = part_snapshot(@stock_part_path)
      @stock_rows = parse_native_rows(tagged(lines, TAGS[:rows], 14), 'stock-written')
      require_true(@stock_rows == expected_native_rows, 'stock-written typed values differ from independent literal witness')
      @stock_write_invocation = result.fetch(:record)
    end

    def inspect_stock_part!
      prepare_offline_catalog!
      result, @inspect_report = invoke_helper('helper_read_stock_part', 'read', @stock_part_path, @offline_catalog_root)
      validate_helper_report!(@inspect_report, 'read')
      @inspect_invocation = result.fetch(:record)
    end

    def prepare_offline_catalog!
      @offline_catalog_root = File.join(@root, 'offline_catalog')
      metadata_root = File.join(@offline_catalog_root, 'metadata')
      store_root = File.join(@offline_catalog_root, 'store')
      Dir.mkdir(@offline_catalog_root, 0o700)
      Dir.mkdir(metadata_root, 0o700)
      Dir.mkdir(store_root, 0o700)

      database_suffix = Digest::SHA256.hexdigest("#{@root}:w249-offline-database")[0, 12]
      table_suffix = Digest::SHA256.hexdigest("#{@root}:w249-offline-table")[0, 12]
      database_uuid = "24900000-0000-4000-8000-#{database_suffix}"
      table_uuid = "24910000-0000-4000-8000-#{table_suffix}"
      database_store = File.join(store_root, database_uuid[0, 3], database_uuid)
      table_store = File.join(store_root, table_uuid[0, 3], table_uuid)
      FileUtils.mkdir_p(database_store, mode: 0o700)
      FileUtils.mkdir_p(table_store, mode: 0o700)

      write_new(File.join(metadata_root, 'lab.sql'),
                "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n".b)
      declarations = ([KEY_COLUMN] + COLUMN_TYPES.map { |name, type| {'name' => name, 'type' => type} }).map do |column|
        "    `#{column.fetch('name')}` #{column.fetch('type')}"
      end.join(",\n")
      table_ddl = "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n#{declarations}\n)\nENGINE = MergeTree\nORDER BY pk\n"
      write_new(File.join(database_store, 'events.sql'), table_ddl.b)
      copied_part = File.join(table_store, PART_NAME)
      require_true(!File.exist?(copied_part) && !File.symlink?(copied_part),
                   'offline catalog destination PART already exists')
      FileUtils.cp_r(@stock_part_path, copied_part, preserve: true)
      require_true(File.directory?(copied_part) && !File.symlink?(copied_part) && File.realpath(copied_part) == copied_part,
                   'offline catalog PART copy is absent, linked, or noncanonical')
      @offline_part_inventory = part_snapshot(copied_part)
      require_true(@offline_part_inventory == @stock_inventory,
                   'offline catalog copy differs from native stock-written PART inventory')
    end

    def expected_schema
      ([KEY_COLUMN] + COLUMN_TYPES.map { |name, type| {'name' => name, 'type' => type} }).map do |column|
        [column.fetch('name'), column.fetch('type')]
      end
    end

    def rows_query(table)
      type = ->(value) { "if(isNull(#{value}), 'NULL', dynamicType(#{value}))" }
      dynamic_types = [
        "arrayMap(x -> #{type.call('x')}, root_nested.d)",
        "arrayMap(batch -> arrayMap(x -> #{type.call('x')}, batch), array_nested.d)",
        "arrayMap(batch -> arrayMap(x -> #{type.call('x')}, batch), tuple_parent.records.d)",
        "arrayMap(x -> #{type.call('x')}, recursive_nested.d)",
        "arrayMap(children -> arrayMap(x -> #{type.call('x')}, children), recursive_nested.child.d)",
        "arrayMap(records -> arrayMap(x -> #{type.call('x')}, records), mapValues(map_parent).d)",
      ]
      expressions = [
        'toString(pk)', 'hex(toJSONString(root_nested))', 'hex(toJSONString(array_nested))',
        'hex(toJSONString(tuple_parent))', 'hex(toJSONString(recursive_nested))',
        'hex(toJSONString(mapKeys(map_parent)))', 'hex(toJSONString(mapValues(map_parent)))',
      ] + dynamic_types.map { |expression| "hex(toJSONString(#{expression}))" }
      "SELECT '#{TAGS[:rows]}', #{expressions.join(', ')} FROM default.#{table} ORDER BY pk FORMAT TSVRaw;"
    end

    def parse_hex_json(value, label)
      require_true(value.is_a?(String) && /\A(?:[0-9a-fA-F]{2})*\z/.match?(value), "#{label} is not even-length hex")
      JSON.parse([value].pack('H*'))
    rescue JSON::ParserError => error
      raise Failure, "W249: #{label} is invalid JSON: #{error.message}"
    end

    def parse_native_rows(rows, label)
      require_true(rows.size == KEYS.size, "#{label} row count differs")
      rows.map do |fields|
        {
          'tag' => fields[0], 'pk' => Integer(fields[1], 10),
          'root_nested' => parse_hex_json(fields[2], 'root Nested JSON'),
          'array_nested' => parse_hex_json(fields[3], 'Array Nested JSON'),
          'tuple_parent' => parse_hex_json(fields[4], 'Tuple parent JSON'),
          'recursive_nested' => parse_hex_json(fields[5], 'recursive Nested JSON'),
          'map_keys' => parse_hex_json(fields[6], 'Map keys JSON'),
          'map_values' => parse_hex_json(fields[7], 'Map values JSON'),
          'root_types' => parse_hex_json(fields[8], 'root Dynamic types JSON'),
          'array_types' => parse_hex_json(fields[9], 'Array Dynamic types JSON'),
          'tuple_types' => parse_hex_json(fields[10], 'Tuple Dynamic types JSON'),
          'recursive_types' => parse_hex_json(fields[11], 'recursive parent Dynamic types JSON'),
          'recursive_child_types' => parse_hex_json(fields[12], 'recursive child Dynamic types JSON'),
          'map_types' => parse_hex_json(fields[13], 'Map Dynamic types JSON'),
        }
      end
    end

    def expected_native_rows
      values = ProbeDynamicRecursiveHandoffW249.expected_value_rows
      types = ProbeDynamicRecursiveHandoffW249.expected_type_rows
      values.zip(types).map do |value, type|
        {
          'tag' => TAGS[:rows], 'pk' => value.fetch('pk'),
          'root_nested' => value.fetch('root_nested'), 'array_nested' => value.fetch('array_nested'),
          'tuple_parent' => value.fetch('tuple_parent'), 'recursive_nested' => value.fetch('recursive_nested'),
          'map_keys' => value.fetch('map_keys'), 'map_values' => value.fetch('map_values'),
          'root_types' => type.fetch('root_nested'), 'array_types' => type.fetch('array_nested'),
          'tuple_types' => type.fetch('tuple_parent'), 'recursive_types' => type.fetch('recursive_nested'),
          'recursive_child_types' => type.fetch('recursive_child'), 'map_types' => type.fetch('map_parent'),
        }
      end
    end

    def expected_dynamic_types_for_site(name, site_index)
      values = ProbeDynamicRecursiveHandoffW249.expected_type_rows.flat_map do |row|
        case name
        when 'root_nested' then row.fetch('root_nested')
        when 'array_nested' then row.fetch('array_nested')
        when 'tuple_parent' then row.fetch('tuple_parent')
        when 'recursive_nested'
          site_index.zero? ? row.fetch('recursive_nested') : row.fetch('recursive_child')
        when 'map_parent' then row.fetch('map_parent')
        else raise Failure, "unrostered Dynamic column #{name.inspect}"
        end
      end.flatten
      values.reject { |type| type == 'NULL' }.uniq.sort
    end

    def validate_helper_report!(report, action)
      expected_part = File.expand_path(action == 'write' ? @library_part : @stock_part_path)
      require_true(report.fetch('part_path') == expected_part, "helper #{action} part path differs")
      expected_frame_bytes = action == 'write' ? FRAME_BYTES : nil
      require_true(report.fetch('profile') == @profile && report.fetch('frame_bytes') == expected_frame_bytes &&
                   report.fetch('rows_per_mark') == MARK_ROWS.first && report.fetch('keys') == KEYS &&
                   report.fetch('mark_row_counts') == MARK_ROWS && report.fetch('key_column') == KEY_COLUMN.fetch('name'),
                   "helper #{action} key/profile/frame/grid witness differs")

      expected_columns = COLUMNS.map do |name|
        {
          'name' => name,
          'type' => COLUMN_TYPES.fetch(name),
          'dynamic_sites' => DYNAMIC_SITE_PATHS.fetch(name).each_with_index.map do |path, index|
            observed_types = expected_dynamic_types_for_site(name, index)
            if action == 'write'
              {'path' => path, 'registered_actual_types' => ['Int64'],
               'observed_actual_types' => observed_types}
            else
              {'path' => path, 'registered_actual_types' => nil,
               'observed_actual_types' => observed_types}
            end
          end,
        }
      end
      require_true(report.fetch('columns') == expected_columns, "helper #{action} nominal schema/dynamic sites differ")

      expected_rows = ProbeDynamicRecursiveHandoffW249.expected_helper_rows
      require_true(report.fetch('expected_rows') == expected_rows,
                   "helper #{action} independently authored nominal rows differ")
      observed = report.fetch('observed')
      expected_consumers = %w[direct_reader table_full_scan table_window table_candidate_marks offline_values]
      require_true(observed.keys.sort == expected_consumers.sort, "helper #{action} consumer roster differs")
      require_true(observed.fetch('direct_reader') == expected_rows,
                   "helper #{action} direct BinaryBulkColumnReader rows differ")
      if action == 'write'
        require_true(expected_consumers.drop(1).all? { |name| observed.fetch(name).nil? },
                     'helper write unexpectedly claims public table/offline reads')
      else
        require_true(observed.fetch('table_full_scan') == expected_rows &&
                     observed.fetch('table_window') == expected_rows.select { |row| [3, 4].include?(row.fetch('pk')) } &&
                     observed.fetch('table_candidate_marks') == expected_rows.select { |row| [1, 2, 5].include?(row.fetch('pk')) } &&
                     observed.fetch('offline_values') == expected_rows,
                     'helper stock-part direct/table/window/candidate/offline typed rows differ')
      end

      # The script independently snapshots every part file and identity. The
      # helper report intentionally does not duplicate that inventory.
      require_true(report.fetch('action') == action, "helper #{action} action field differs")
    end

    def build_summary
      {
        'format' => FORMAT, 'status' => 'paired_dynamic_recursive_handoff_observed', 'fatal_error' => nil,
        'evidence_root' => @root, 'string_profile' => @profile, 'helper_mode' => @helper_mode,
        'frame_bytes' => FRAME_BYTES, 'keys' => KEYS, 'mark_row_counts' => MARK_ROWS,
        'schema' => ([KEY_COLUMN] + COLUMN_TYPES.map { |name, type| {'name' => name, 'type' => type} }),
        'literal_rows' => ROWS, 'native_expected_rows' => expected_native_rows,
        'runtime' => {'path' => @binary, 'sha256' => W241::BINARY_SHA256, 'version' => W241::VERSION,
                      'build' => W241::BUILD, 'source_pins' => @source_pins},
        'helper' => {'path' => @helper, 'sha256' => @helper_sha, 'mode' => @helper_mode},
        'source_closures' => {'ruby' => source_entries(@ruby_sources), 'crystal' => source_entries(@crystal_sources)},
        'helper_reports' => {'write' => @write_report, 'stock_read' => @inspect_report},
        'parts' => {'library_generated' => {'path' => @library_part, 'files' => @generated_inventory},
                    'native_attached' => {'path' => @input_part_path, 'files' => @attached_inventory},
                    'stock_written' => {'path' => @stock_part_path, 'files' => @stock_inventory},
                    'offline_catalog_copy' => {'root' => @offline_catalog_root, 'part_files' => @offline_part_inventory}},
        'native' => {'input_schema' => @input_schema, 'stock_schema' => @write_schema,
                     'attached_check' => @input_check, 'stock_check' => @write_check,
                     'attached_rows' => @input_rows, 'stock_rows' => @stock_rows},
        'invocations' => @invocations,
        'limits' => {'native_max_threads' => 1, 'native_max_memory_usage_bytes' => W241::MEMORY,
                     'outer_run_safe_memory_limit_bytes' => W241::OUTER_RUN_SAFE_LIMIT,
                     'timeout_seconds' => W241::TIMEOUT, 'termination_grace_seconds' => W241::GRACE},
        'interpretation' => {
          'library_to_stock' => 'The existing library writer emits the complete six-column Wide PART; pinned stock ATTACHes and CHECKs it, reports exact declared nominal schema/order, and matches independent literal values plus Dynamic type traces.',
          'stock_to_library' => 'Pinned stock writes independent literal values into a Wide PART; helper direct, public full/window/candidate scans, and OfflineTable values must match its independent typed fixture oracle.',
          'dynamic_types' => 'Native SQL explicitly queries dynamicType at each root, Array(Nested), Tuple(Array(Nested)), recursive parent/child Nested, and Map value occurrence. Map keys are captured as numeric arrays, not JSON object properties.',
          'attach_metadata' => 'For the pinned runtime/source only, stock ATTACH may add exactly invalidated_system_columns.txt with bytes _block_offset newline _block_number newline; generated file identities must remain unchanged. This is not a blanket extra-file allowance.',
          'scope' => 'Only the generated, native-attached, and stock-written complete link-free PART trees and named typed consumers are captured. No native projection, MV interoperability, partitions, heap/RSS, or performance claim is made.',
          'failure_policy' => 'Any malformed/failed process, exact schema, CHECK, literal value/type witness, source closure, profile, grid, or flat PART roster makes the capture inconclusive.',
        },
      }
    end
  end

  def self.parse_options
    options = {}
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: probe_dynamic_recursive_handoff_w249.rb --binary PATH --helper PATH --evidence-root DIR --string-profile single|sized --helper-mode debug|release'
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
    options = ProbeDynamicRecursiveHandoffW249.parse_options
    success = ProbeDynamicRecursiveHandoffW249::Probe.new(**options).run
    exit(success ? 0 : 1)
  rescue StandardError => error
    warn "W249 inconclusive: #{error.class}: #{error.message}"
    exit 1
  end
end
