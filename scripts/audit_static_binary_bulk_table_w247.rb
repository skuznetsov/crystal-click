#!/usr/bin/env ruby
# Offline W247 evidence auditor. It never launches Crystal or ClickHouse.
# It independently validates raw process captures, both Wide-part trees,
# literal stock rows, consumer scans, and actual physical metadata/bytes.
#
# Usage:
#   ruby scripts/audit_static_binary_bulk_table_w247.rb \
#     --summary ROOT/summary.json --summary-sha256 SHA \
#     --clickhouse PINNED_CLICKHOUSE --helper PREBUILT_HELPER --helper-sha256 SHA \
#     --probe-source scripts/probe_static_binary_bulk_table_w247.rb --probe-source-sha256 SHA \
#     --helper-source scripts/check_static_binary_bulk_table_w247.cr --helper-source-sha256 SHA \
#     --fixture-source scripts/support/static_binary_bulk_table_w247_fixture.cr --fixture-source-sha256 SHA \
#     --auditor-source scripts/audit_static_binary_bulk_table_w247.rb --auditor-source-sha256 SHA \
#     --self-test

require 'digest'
require 'find'
require 'json'
require 'open3'
require 'optparse'
require_relative 'probe_object_shared_json_interop_w241'

module AuditStaticBinaryBulkTableW247
  W241 = ProbeObjectSharedJSONInteropW241
  FORMAT = 'static_binary_bulk_table_w247_native_capture_v1'.freeze
  HELPER_FORMAT = 'static_binary_bulk_table_w247_fixture_v1'.freeze
  PART_NAME = 'all_1_1_0'.freeze
  FRAME = 32
  MARK_ROWS = [2, 2, 1].freeze
  MARKS_WITH_EOF = [2, 2, 1, 0].freeze
  KEYS = [1, 2, 3, 4, 5].freeze
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
  ROW_TAG = '__W247_ROWS__'.freeze
  CHECK_BEGIN = '__W247_CHECK_BEGIN__'.freeze
  CHECK_END = '__W247_CHECK_END__'.freeze
  SCHEMA_TAG = '__W247_SCHEMA__'.freeze
  PART_TAG = '__W247_PART__'.freeze
  PATH_TAG = '__W247_PATH__'.freeze
  PROCESS_KEYS = %w[
    label process_kind argv argv_file argv_sha256 stdin_file stdin_bytes stdin_sha256 stdout_file
    stdout_bytes stdout_sha256 stderr_file stderr_bytes stderr_sha256 exit signal timed_out
    timeout_seconds termination_grace_seconds max_threads max_memory_usage_bytes max_memory_usage_applicable
    required_outer_run_safe_memory_limit_bytes binary_path expected_binary_sha256 binary_sha_before
    binary_sha_after spawn_error stdin_write_error stdout_read_error stderr_read_error process_classification store_path
  ].freeze
  SUMMARY_KEYS = %w[
    format status fatal_error evidence_root string_profile frame_bytes schema keys mark_row_counts rows
    expected_signatures runtime helper source_pins limits helper_reports physical_profiles parts native_rows
    invocations paths store_inventory interpretation
  ].freeze
  MAX_ARTIFACT_BYTES = 64 * 1024 * 1024
  MAX_PART_BYTES = 64 * 1024 * 1024
  MAX_STORE_BYTES = 256 * 1024 * 1024
  MAX_STORE_FILES = 20_000
  MAX_FILE_BYTES = W241::MAX_PART_FILE_BYTES
  BASE_PART_FILES = %w[
    checksums.txt columns.txt columns_substreams.txt count.txt default_compression_codec.txt
    metadata_version.txt primary.idx serialization.json
  ].freeze
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

  # Independent semantic fixtures; neither the probe nor helper is loaded as
  # an oracle. Every expected stock row below is derived from these literals.
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
     'named_recursive' => {'arr' => [nil], 'labels' => 'alpha',
                           'choice' => {'type' => 'NULL', 'value' => nil}},
     'string0' => 'plain-3', 'string1' => 'repeat'},
    {'pk' => 4, 'root_variant' => {'type' => 'NULL', 'value' => nil},
     'array_variant' => [V.call('UInt64', 0)],
     'named_recursive' => {'arr' => [99], 'labels' => 'β',
                           'choice' => V.call('Array(UInt16)', [])},
     'string0' => 'plain-4', 'string1' => "nul\0byte"},
    {'pk' => 5, 'root_variant' => V.call('String', 'root-tail'),
     'array_variant' => [V.call('LowCardinality(String)', 'tail'),
                         V.call('UInt64', 18_446_744_073_709_551_615)],
     'named_recursive' => {'arr' => [0, -2_147_483_648], 'labels' => nil,
                           'choice' => V.call('String', 'tuple-tail')},
     'string0' => 'plain-5', 'string1' => 'last'},
  ].freeze

  class Failure < StandardError; end

  class UniqueKeyHash < Hash
    def []=(key, value)
      raise JSON::ParserError, "duplicate JSON key #{key.inspect}" if key?(key)
      super
    end
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

  def self.unsigned(type, value, width)
    bits = (0...width).map { |index| (value >> (index * 8)) & 0xff }.pack('C*')
    sig(type, false, nil, bits)
  end

  def self.signed(type, value, width)
    unsigned(type, value & ((1 << (width * 8)) - 1), width)
  end

  def self.value_sig(type, value)
    case type
    when 'String' then sig(type, false, nil, value.b)
    when 'UInt16' then unsigned(type, value, 2)
    when 'UInt64' then unsigned(type, value, 8)
    when 'Int32' then signed(type, value, 4)
    else raise Failure, "unknown literal value type #{type}"
    end
  end

  def self.array_sig(type, children)
    sig(type, false, nil, ''.b, children)
  end

  def self.nullable_sig(type, child = nil)
    child.nil? ? sig(type, true) : sig(type, false, nil, ''.b, [child])
  end

  def self.lc_sig(type, child)
    sig(type, false, nil, ''.b, [child])
  end

  def self.variant_sig(type, arm, child)
    sig(type, false, arm, ''.b, [child])
  end

  def self.root_variant_sig(value)
    type = TYPES.fetch('root_variant')
    case value.fetch('type')
    when 'NULL' then sig(type, true)
    when 'Array(UInt16)'
      child = array_sig('Array(UInt16)', value.fetch('value').map { |item| value_sig('UInt16', item) })
      variant_sig(type, 0, child)
    when 'String' then variant_sig(type, 1, value_sig('String', value.fetch('value')))
    else raise Failure, 'unknown root Variant literal arm'
    end
  end

  def self.array_variant_sig(values)
    type = 'Variant(LowCardinality(String), UInt64)'
    array_sig(TYPES.fetch('array_variant'), values.map do |value|
      case value.fetch('type')
      when 'LowCardinality(String)'
        variant_sig(type, 0, lc_sig('LowCardinality(String)', value_sig('String', value.fetch('value'))))
      when 'UInt64' then variant_sig(type, 1, value_sig('UInt64', value.fetch('value')))
      else raise Failure, 'unknown Array Variant literal arm'
      end
    end)
  end

  def self.tuple_variant_sig(value)
    type = 'Variant(Array(UInt16), String)'
    case value.fetch('type')
    when 'NULL' then sig(type, true)
    when 'Array(UInt16)'
      child = array_sig('Array(UInt16)', value.fetch('value').map { |item| value_sig('UInt16', item) })
      variant_sig(type, 0, child)
    when 'String' then variant_sig(type, 1, value_sig('String', value.fetch('value')))
    else raise Failure, 'unknown Tuple Variant literal arm'
    end
  end

  def self.named_recursive_sig(value)
    arr = array_sig('Array(Nullable(Int32))', value.fetch('arr').map do |item|
      nullable_sig('Nullable(Int32)', item.nil? ? nil : value_sig('Int32', item))
    end)
    labels = lc_sig('LowCardinality(Nullable(String))',
                    nullable_sig('Nullable(String)', value.fetch('labels').nil? ? nil : value_sig('String', value.fetch('labels'))))
    sig(TYPES.fetch('named_recursive'), false, nil, ''.b, [arr, labels, tuple_variant_sig(value.fetch('choice'))])
  end

  def self.expected_signatures
    TARGET_COLUMNS.each_with_object({}) do |name, output|
      output[name] = ROWS.map do |row|
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
      recursive = row.fetch('named_recursive')
      choice = recursive.fetch('choice')
      labels = recursive.fetch('labels')
      {'tag' => ROW_TAG, 'pk' => row.fetch('pk'),
       'root_variant_type' => root.fetch('type'), 'root_variant' => root.fetch('value'),
       'array_variant_types' => row.fetch('array_variant').map { |item| item.fetch('type') },
       'array_variant' => row.fetch('array_variant').map { |item| item.fetch('value') },
       'named_recursive_arr' => recursive.fetch('arr'),
       'named_recursive_labels_null' => labels.nil? ? 'NULL' : 'VALUE',
       'named_recursive_labels' => labels,
       'named_recursive_choice_type' => choice.fetch('type'), 'named_recursive_choice' => choice.fetch('value'),
       'string0' => row.fetch('string0'), 'string1' => row.fetch('string1')}
    end
  end

  class Auditor
    def initialize(summary_path:, summary_sha256:, clickhouse:, helper_path:, helper_sha256:,
                   probe_source:, probe_source_sha256:, helper_source:, helper_source_sha256:,
                   fixture_source:, fixture_source_sha256:, auditor_source:, auditor_source_sha256:,
                   self_test:)
      @summary_path = canonical_file(summary_path, 'summary')
      @root = File.dirname(@summary_path)
      @summary_sha = checked_sha(summary_sha256, 'summary')
      @clickhouse = canonical_executable(clickhouse, 'ClickHouse')
      @helper = canonical_executable(helper_path, 'helper')
      @helper_sha = checked_sha(helper_sha256, 'helper')
      @probe_source = canonical_file(probe_source, 'probe source')
      @probe_source_sha = checked_sha(probe_source_sha256, 'probe source')
      @helper_source = canonical_file(helper_source, 'helper source')
      @helper_source_sha = checked_sha(helper_source_sha256, 'helper source')
      @fixture_source = canonical_file(fixture_source, 'fixture source')
      @fixture_source_sha = checked_sha(fixture_source_sha256, 'fixture source')
      @auditor_source = canonical_file(auditor_source, 'auditor source')
      @auditor_source_sha = checked_sha(auditor_source_sha256, 'auditor source')
      fail!('--self-test is required for evidence audit') unless self_test
      fail!('summary must be in an exclusive canonical direct child of /private/tmp') unless
        File.basename(@summary_path) == 'summary.json' && File.directory?(@root) && !File.symlink?(@root) &&
        File.realpath(@root) == @root && File.dirname(@root) == File.realpath('/private/tmp')
      scripts = File.realpath(__dir__)
      same!(@probe_source, File.join(scripts, 'probe_static_binary_bulk_table_w247.rb'), 'probe source path')
      same!(@helper_source, File.join(scripts, 'check_static_binary_bulk_table_w247.cr'), 'helper source path')
      same!(@fixture_source, File.join(scripts, 'support', 'static_binary_bulk_table_w247_fixture.cr'), 'fixture source path')
      same!(@auditor_source, File.join(scripts, 'audit_static_binary_bulk_table_w247.rb'), 'auditor source path')
    end

    def run
      @summary = parse_json!(read_file(@summary_path, MAX_ARTIFACT_BYTES, 'summary'), 'summary')
      same!(sha_file(@summary_path), @summary_sha, 'external summary SHA-256')
      authenticate_layout!
      authenticate_contract!
      authenticate_sources!
      authenticate_parts!
      authenticate_invocations!
      authenticate_helper_reports!
      authenticate_native_outputs!
      authenticate_physical_profiles!
      controls = self_test!
      {status: 'raw_capture_authenticated', summary_sha256: @summary_sha,
       runtime_sha256: W241::BINARY_SHA256, helper_sha256: @helper_sha,
       string_profile: @profile, physical_profiles: %w[generated stock_reemit],
       columns: TARGET_COLUMNS, rows: KEYS.size, mark_row_counts: MARK_ROWS,
       controls: controls,
       interpretation: 'Stock ATTACH/CHECK/read and stock Wide re-emission are independently captured; the helper re-reads the stock-written part through public typed and OfflineTable paths. Projection interoperability was not tested.'}
    end

    private

    def fail!(message)
      raise Failure, "W247 audit: #{message}"
    end

    def same!(actual, expected, label)
      fail!("#{label} differs; observed #{actual.inspect}") unless actual == expected
    end

    def checked_sha(value, label)
      fail!("#{label} SHA-256 is malformed") unless value.is_a?(String) && /\A[0-9a-f]{64}\z/i.match?(value)
      value.downcase
    end

    def sha_file(path)
      Digest::SHA256.file(path).hexdigest
    end

    def sha_bytes(bytes)
      Digest::SHA256.hexdigest(bytes)
    end

    def canonical_file(path, label)
      expanded = File.expand_path(path)
      fail!("#{label} is absent, symlinked, or noncanonical") unless File.file?(expanded) && !File.symlink?(expanded) && File.realpath(expanded) == expanded
      expanded
    rescue Errno::ENOENT, Errno::EACCES => error
      fail!("#{label} is inaccessible: #{error.message}")
    end

    def canonical_executable(path, label)
      expanded = canonical_file(path, label)
      fail!("#{label} is not executable") unless File.executable?(expanded)
      expanded
    end

    def read_file(path, limit, label)
      fail!("#{label} is symlinked or not regular") unless File.file?(path) && !File.symlink?(path)
      size = File.size(path)
      fail!("#{label} exceeds its byte bound") unless size <= limit
      bytes = File.binread(path)
      fail!("#{label} changed while read") unless bytes.bytesize == size
      bytes
    end

    def parse_json!(bytes, label)
      JSON.parse(bytes, object_class: UniqueKeyHash)
    rescue JSON::ParserError => error
      fail!("#{label} is malformed or contains duplicate keys: #{error.message}")
    end

    def exact_keys!(value, keys, label)
      fail!("#{label} key set differs") unless value.is_a?(Hash) && value.keys.sort == keys.sort
    end

    def root_path(*parts)
      File.join(@root, *parts)
    end

    def authenticate_layout!
      same!(Dir.children(@root).sort, %w[generated invocations parts stores summary.json], 'exclusive evidence-root children')
      %w[generated invocations parts stores].each do |name|
        path = root_path(name)
        fail!("#{name} is absent, symlinked, or noncanonical") unless File.directory?(path) && !File.symlink?(path) && File.realpath(path) == path
      end
      %w[pre_attach].each do |name|
        path = root_path('parts', name)
        fail!("parts/#{name} is absent, symlinked, or noncanonical") unless File.directory?(path) && !File.symlink?(path) && File.realpath(path) == path
      end
      native = root_path('stores', 'native')
      fail!('native store is absent, symlinked, or noncanonical') unless File.directory?(native) && !File.symlink?(native) && File.realpath(native) == native
      same!(Dir.children(root_path('generated')).sort, [PART_NAME], 'generated part directory roster')
      same!(Dir.children(root_path('parts', 'pre_attach')).sort, [PART_NAME], 'pre-attach part directory roster')
    end

    def authenticate_contract!
      exact_keys!(@summary, SUMMARY_KEYS, 'summary')
      same!([@summary['format'], @summary['status'], @summary['fatal_error'], @summary['evidence_root']],
            [FORMAT, 'stock_read_and_reemit_observed', nil, @root], 'capture identity/status')
      @profile = @summary.fetch('string_profile')
      fail!('String profile is not single or sized') unless %w[single sized].include?(@profile)
      same!(@summary['frame_bytes'], FRAME, 'bounded frame size')
      same!(@summary['schema'], ([KEY] + TYPES.map { |name, type| {'name' => name, 'type' => type} }), 'literal schema/order')
      same!(@summary['keys'], KEYS, 'literal sorted keys')
      same!(@summary['mark_row_counts'], MARK_ROWS, 'parent mark row counts')
      same!(@summary['rows'], ROWS, 'semantic fixture rows')
      same!(@summary['expected_signatures'], AuditStaticBinaryBulkTableW247.expected_signatures, 'independent structural-signature oracle')
      same!(@summary['limits'], expected_limits, 'process limits')
      authenticate_runtime_and_helper!
    end

    def expected_limits
      {'timeout_seconds' => W241::TIMEOUT, 'termination_grace_seconds' => W241::GRACE,
       'max_threads' => 1, 'max_memory_usage_bytes' => W241::MEMORY,
       'outer_run_safe_memory_limit_bytes' => W241::OUTER_RUN_SAFE_LIMIT,
       'store_file_limit' => MAX_STORE_FILES, 'store_bytes_limit' => MAX_STORE_BYTES}
    end

    def authenticate_runtime_and_helper!
      runtime = @summary.fetch('runtime')
      exact_keys!(runtime, %w[path sha256_before sha256_after version build], 'runtime identity')
      same!([runtime['path'], runtime['sha256_before'], runtime['sha256_after'], runtime['version'], runtime['build']],
            ['/private/tmp/crystal-click-w216-runtime-recovery.DmL9Kw/clickhouse-stripped',
             W241::BINARY_SHA256, W241::BINARY_SHA256, W241::VERSION, W241::BUILD], 'pinned stock runtime identity')
      same!(@clickhouse, runtime['path'], 'audited runtime path')
      same!(sha_file(@clickhouse), W241::BINARY_SHA256, 'current pinned runtime bytes')
      helper = @summary.fetch('helper')
      exact_keys!(helper, %w[path sha256_before sha256_after], 'helper identity')
      same!([helper['path'], helper['sha256_before'], helper['sha256_after']], [@helper, @helper_sha, @helper_sha], 'helper path/digest')
      same!(sha_file(@helper), @helper_sha, 'current helper bytes')
      @token = Digest::SHA256.hexdigest(@root)[0, 8]
      @input_table = "w247_#{@token}_#{@profile}_input"
      @reemit_table = "w247_#{@token}_#{@profile}_reemit"
    end

    def closure(roots, boundary, pattern, suffix)
      root = File.realpath(boundary)
      pending = roots.map { |path| File.expand_path(path) }
      seen = {}
      until pending.empty?
        path = pending.pop
        canonical = File.realpath(path)
        unless canonical.start_with?(root + File::SEPARATOR) && File.file?(canonical) && !File.symlink?(path)
          fail!("source closure escapes its tree or is not a regular file: #{path}")
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
      fail!("source dependency missing: #{error.message}")
    end

    def authenticate_sources!
      pins = @summary.fetch('source_pins')
      exact_keys!(pins, %w[ruby_before ruby_after crystal_before crystal_after clickhouse_source_before clickhouse_source_after], 'source identity sets')
      scripts = File.realpath(__dir__)
      repo = File.realpath(File.expand_path('..', scripts))
      ruby_paths = closure([@probe_source], scripts, /^\s*require_relative\s+['"]([^'"]+)['"]/, '.rb')
      crystal_paths = closure([@helper_source, @fixture_source], repo, /^\s*require\s+['"]((?:\.\/|\.\.\/)[^'"]+)['"]/, '.cr')
      ruby_inventory = source_entries(ruby_paths)
      crystal_inventory = source_entries(crystal_paths)
      %w[ruby_before ruby_after].each { |key| same!(pins.fetch(key), ruby_inventory, key) }
      %w[crystal_before crystal_after].each { |key| same!(pins.fetch(key), crystal_inventory, key) }
      same!(sha_file(@probe_source), @probe_source_sha, 'external probe source SHA')
      same!(sha_file(@helper_source), @helper_source_sha, 'external helper source SHA')
      same!(sha_file(@fixture_source), @fixture_source_sha, 'external fixture source SHA')
      same!(sha_file(@auditor_source), @auditor_source_sha, 'external auditor source SHA')
      ruby_map = ruby_inventory.each_with_object({}) { |entry, output| output[entry.fetch('path')] = entry.fetch('sha256') }
      audit_paths = closure([@auditor_source], scripts, /^\s*require_relative\s+['"]([^'"]+)['"]/, '.rb')
      audit_paths.reject { |path| path == @auditor_source }.each do |path|
        same!(ruby_map[path], sha_file(path), "auditor dependency captured by probe: #{path}")
      end
      expected_source_pins = source_pin_inventory
      same!(pins.fetch('clickhouse_source_before'), expected_source_pins, 'source tree pins before capture')
      same!(pins.fetch('clickhouse_source_after'), expected_source_pins, 'source tree pins after capture')
    end

    def source_entries(paths)
      paths.map { |path| {'path' => path, 'sha256' => sha_file(path)} }
    end

    def source_pin_inventory
      SOURCE_PINS.map do |pin|
        root = File.realpath(pin.fetch('root'))
        same!(root, pin.fetch('root'), "source tree path #{pin.fetch('tree')}")
        revision, error, status = Open3.capture3('git', '-C', root, 'rev-parse', 'HEAD')
        fail!("source tree revision check failed for #{pin.fetch('tree')}") unless status.success? && error.empty?
        same!(revision.strip, pin.fetch('revision'), "source tree revision #{pin.fetch('tree')}")
        files = pin.fetch('files').map do |file|
          path = File.join(root, file.fetch('path'))
          fail!("source pin file is missing or symlinked: #{path}") unless File.file?(path) && !File.symlink?(path)
          same!(sha_file(path), file.fetch('sha256'), "source pin file #{path}")
          {'path' => file.fetch('path'), 'sha256' => sha_file(path)}
        end
        {'tree' => pin.fetch('tree'), 'root' => root, 'revision' => revision.strip, 'files' => files}
      end
    rescue Errno::ENOENT, Errno::EACCES => error
      fail!("pinned source tree is inaccessible: #{error.message}")
    end

    def snapshot(path, direct: true)
      fail!("part/tree is absent, symlinked, or noncanonical: #{path}") unless File.directory?(path) && !File.symlink?(path) && File.realpath(path) == path
      entries = []
      total = 0
      Find.find(path) do |item|
        stat = File.lstat(item)
        fail!("tree contains symlink or special entry: #{item}") if stat.symlink? || !(stat.directory? || stat.file?)
        next if stat.directory?
        relative = item.delete_prefix(path + File::SEPARATOR)
        fail!("part has nested files: #{relative}") if direct && relative.include?(File::SEPARATOR)
        total += stat.size
        max_files = direct ? 4096 : MAX_STORE_FILES
        max_total = direct ? MAX_PART_BYTES : MAX_STORE_BYTES
        max_file = direct ? MAX_FILE_BYTES : MAX_PART_BYTES
        fail!('tree exceeds inventory bounds') if entries.size >= max_files || stat.size > max_file || total > max_total
        entries << [relative, stat.size, sha_file(item)]
      end
      entries.sort
    end

    def canonical_store_target!(path, store_root, label)
      relative = path.delete_prefix(store_root + File::SEPARATOR)
      pieces = relative.split(File::SEPARATOR)
      uuid = pieces[2]
      fail!("#{label} is not a direct store/<prefix>/<UUID> path") unless
        pieces.size == 3 && pieces[0] == 'store' && uuid &&
        /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/.match?(uuid) && pieces[1] == uuid[0, 3]
      current = store_root
      pieces.each do |piece|
        current = File.join(current, piece)
        fail!("#{label} crosses a symlink") if File.symlink?(current)
      end
      fail!("#{label} is absent or noncanonical") unless File.directory?(path) && File.realpath(path) == path
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

    def store_snapshot
      root = root_path('stores', 'native')
      [@input_data_path, @reemit_data_path].each_with_index do |path, index|
        canonical_store_target!(path, root, index.zero? ? 'input table data path' : 're-emission table data path')
      end
      fail!('input/re-emission data paths are not distinct') if @input_data_path == @reemit_data_path
      input_uuid = File.basename(@input_data_path)
      reemit_uuid = File.basename(@reemit_data_path)
      aliases = {}
      [["data/default/#{@input_table}", @input_data_path, input_uuid],
       ["data/default/#{@reemit_table}", @reemit_data_path, reemit_uuid]].each do |relative, target, uuid|
        link = File.join(root, relative)
        fail!("expected Atomic table alias is absent: #{relative}") unless File.symlink?(link)
        raw = File.readlink(link)
        expected = "../../store/#{uuid[0, 3]}/#{uuid}"
        fail!("Atomic table alias target differs: #{relative}") unless
          raw == expected && File.expand_path(raw, File.dirname(link)) == target && File.realpath(link) == target
        aliases[relative] = raw
      end

      metadata_relative = 'metadata/default'
      metadata_link = File.join(root, metadata_relative)
      fail!('expected Atomic metadata alias is absent') unless File.symlink?(metadata_link)
      metadata_raw = File.readlink(metadata_link)
      match = /\A\.\.\/store\/([0-9a-f]{3})\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\z/.match(metadata_raw)
      fail!('Atomic metadata alias text is not the expected relative UUID path') unless match && match[1] == match[2][0, 3]
      metadata_target = File.expand_path(metadata_raw, File.dirname(metadata_link))
      canonical_store_target!(metadata_target, root, 'Atomic metadata directory')
      fail!('Atomic metadata alias resolves to a table data directory') if
        metadata_target == @input_data_path || metadata_target == @reemit_data_path
      fail!('Atomic metadata alias resolves differently from its literal target') unless File.realpath(metadata_link) == metadata_target
      expected_files = {
        "#{@input_table}.sql" => metadata_sql(input_uuid),
        "#{@reemit_table}.sql" => metadata_sql(reemit_uuid),
      }
      fail!('Atomic metadata directory has unexpected SQL children') unless Dir.children(metadata_target).sort == expected_files.keys.sort
      expected_files.each do |name, expected_bytes|
        path = File.join(metadata_target, name)
        fail!("Atomic metadata SQL identity differs: #{name}") unless
          File.file?(path) && !File.symlink?(path) && File.realpath(path) == path &&
          File.size(path) <= MAX_PART_BYTES && File.binread(path) == expected_bytes
      end
      aliases[metadata_relative] = metadata_raw

      seen_aliases = []
      entries = []
      total = 0
      Find.find(root) do |item|
        stat = File.lstat(item)
        relative = item.delete_prefix(root + File::SEPARATOR)
        if stat.symlink?
          raw = aliases[relative]
          fail!("native store has an unexpected symlink or alias target: #{item}") unless raw && File.readlink(item) == raw
          seen_aliases << relative
          total += raw.bytesize
          fail!('native store exceeds bounded inventory') if entries.size >= MAX_STORE_FILES || total > MAX_STORE_BYTES
          entries << [relative, 'symlink', raw]
          next
        end
        fail!("native store has a special entry: #{item}") unless stat.directory? || stat.file?
        next if stat.directory?
        total += stat.size
        fail!('native store exceeds bounded inventory') if
          entries.size >= MAX_STORE_FILES || stat.size > MAX_PART_BYTES || total > MAX_STORE_BYTES
        entries << [relative, 'file', stat.size, sha_file(item)]
      end
      fail!('native store Atomic alias closure differs') unless seen_aliases.sort == aliases.keys.sort
      entries.sort
    end

    def authenticate_parts!
      @part = root_path('generated', PART_NAME)
      @pre_attach = root_path('parts', 'pre_attach', PART_NAME)
      paths = @summary.fetch('paths')
      exact_keys!(paths, %w[generated pre_attach detached input_data_path attached reemit_data_path reemit], 'part path map')
      same!([paths['generated'], paths['pre_attach']], [@part, @pre_attach], 'generated and pre-attach absolute paths')
      @generated = snapshot(@part)
      @pre_attach_snapshot = snapshot(@pre_attach)
      same!(@pre_attach_snapshot, @generated, 'pre-attach raw file closure')
      @reemit_part = canonical_store_path(paths.fetch('reemit'), 'stock re-emitted part')
      @reemit_data_path = canonical_store_path(paths.fetch('reemit_data_path'), 're-emission table data path')
      @input_data_path = canonical_store_path(paths.fetch('input_data_path'), 'input table data path')
      @attached_part = canonical_store_path(paths.fetch('attached'), 'attached source part')
      same!(@attached_part, File.join(@input_data_path, PART_NAME), 'attached part path binding')
      same!(@reemit_part, File.join(@reemit_data_path, PART_NAME), 'stock re-emitted part path binding')
      same!(paths['detached'], File.join(@input_data_path, 'detached', PART_NAME), 'detached path binding')
      fail!('detached source remains after ATTACH') if File.exist?(paths['detached']) || File.symlink?(paths['detached'])
      same!(paths['attached'], @attached_part, 'attached path map')
      same!(paths['reemit'], @reemit_part, 're-emitted path map')
      @attached_snapshot = snapshot(@attached_part)
      @reemit_snapshot = snapshot(@reemit_part)
      @store_inventory = store_snapshot
      parts = @summary.fetch('parts')
      exact_keys!(parts, %w[generated pre_attach detached attached reemit marks input_check reemit_check input_schema reemit_schema input_part reemit_part], 'part evidence')
      same!(parts['generated'], @generated, 'generated files/digests')
      same!(parts['pre_attach'], @pre_attach_snapshot, 'pre-attach files/digests')
      same!(parts['detached'], @generated, 'captured detached snapshot')
      same!(parts['attached'], @attached_snapshot, 'actual attached files/digests')
      same!(parts['reemit'], @reemit_snapshot, 'actual stock re-emitted files/digests')
      same!(@summary.fetch('store_inventory'), @store_inventory, 'native store byte inventory')
      verify_attached_file_identity!
      fail!('generated parent part unexpectedly has projection or nested child') if @generated.any? { |entry| entry[0].include?(File::SEPARATOR) || entry[0] == 'by_shape.proj' }
      true
    end

    def canonical_store_path(path, label)
      fail!("#{label} is not a canonical absolute path") unless path.is_a?(String) && path.start_with?(File::SEPARATOR) && !path.include?("\0")
      fail!("#{label} escaped the exclusive native store") unless path.start_with?(root_path('stores', 'native') + File::SEPARATOR)
      fail!("#{label} contains traversal") if path.split(File::SEPARATOR).any? { |piece| piece == '.' || piece == '..' }
      current = root_path('stores', 'native')
      path.delete_prefix(current + File::SEPARATOR).split(File::SEPARATOR).each do |piece|
        fail!("#{label} has an empty path component") if piece.empty?
        current = File.join(current, piece)
        fail!("#{label} crosses a symlink") if File.symlink?(current)
      end
      fail!("#{label} is absent or noncanonical") unless File.directory?(path) && File.realpath(path) == path
      path
    end

    def verify_attached_file_identity!
      generated = @generated.each_with_object({}) { |(name, size, digest), map| map[name] = [size, digest] }
      attached = @attached_snapshot.each_with_object({}) { |(name, size, digest), map| map[name] = [size, digest] }
      same!(attached.keys.sort, (generated.keys + ['invalidated_system_columns.txt']).sort, 'ATTACH physical file roster')
      generated.each { |name, identity| same!(attached[name], identity, "ATTACH preserves #{name}") }
      same!(read_file(File.join(@attached_part, 'invalidated_system_columns.txt'), 1024, 'ATTACH invalidation metadata'),
            "_block_offset\n_block_number\n".b, 'ATTACH invalidation bytes')
    end

    def parse_substreams(part)
      bytes = read_file(File.join(part, 'columns_substreams.txt'), 4 * 1024 * 1024, 'columns_substreams.txt')
      text = bytes.dup.force_encoding(Encoding::UTF_8)
      fail!('columns_substreams.txt is invalid UTF-8') unless text.valid_encoding?
      lines = text.split("\n", -1)
      fail!('columns_substreams envelope differs') unless lines.pop == '' && lines.shift == 'columns substreams version: 1'
      names = ['pk'] + TYPES.keys
      same!(lines.shift, "#{names.size} columns:", 'columns_substreams column count')
      sections = []
      until lines.empty?
        match = /\A(0|[1-9][0-9]*) substreams for column `([a-z][a-z0-9_]*)`:\z/.match(lines.shift.to_s)
        fail!('malformed substream section') unless match
        amount = Integer(match[1], 10)
        fail!('substream list exceeds bounds') unless amount <= 4096 && lines.size >= amount
        streams = amount.times.map do
          row = /\A\t([A-Za-z0-9_.%]+)\z/.match(lines.shift.to_s)
          fail!('malformed logical stream name') unless row
          row[1]
        end
        sections << [match[2], streams]
      end
      same!(sections.map(&:first), names, 'logical column order')
      logical = sections.flat_map(&:last)
      fail!('logical substreams are empty or aliased') if logical.empty? || logical.uniq != logical
      [text, sections, logical]
    end

    def actual_variant_sites(sections)
      sites = []
      sections.each do |column, streams|
        streams.each do |stream|
          next unless stream.downcase.include?('variant_discr')
          expected = variant_site_for(column)
          same!(stream, expected.fetch('logical_stream'), "physical #{column} Variant logical stream")
          sites << {'column' => column, 'logical_stream' => stream, 'type' => expected.fetch('type'),
                    'role' => expected.fetch('role')}
        end
      end
      same!(sites.map { |entry| entry.fetch('column') }.sort, TARGET_COLUMNS.sort, 'physical Variant discriminator columns')
      same!(sites.map { |entry| entry.fetch('logical_stream') }.uniq.size, sites.size, 'physical Variant discriminator streams')
      sites
    end

    def variant_site_for(column)
      case column
      when 'root_variant'
        {'type' => TYPES.fetch('root_variant'), 'role' => 'root.discriminators',
         'logical_stream' => 'root_variant.variant_discr'}
      when 'array_variant'
        {'type' => TYPES.fetch('array_variant'), 'role' => 'root.elements.discriminators',
         'logical_stream' => 'array_variant.variant_discr'}
      when 'named_recursive'
        {'type' => TYPES.fetch('named_recursive'), 'role' => 'root.field.2.discriminators',
         'logical_stream' => 'named_recursive%2Echoice.variant_discr'}
      else fail!("unexpected Variant discriminator column #{column}")
      end
    end

    def physical_base(part, role)
      inventory = snapshot(part)
      names = inventory.map(&:first)
      required = %w[checksums.txt columns.txt columns_substreams.txt count.txt default_compression_codec.txt metadata_version.txt primary.idx serialization.json]
      fail!("#{role} part lacks base metadata") unless (required - names).empty?
      codec = read_file(File.join(part, 'default_compression_codec.txt'), 1024, 'codec').force_encoding(Encoding::UTF_8)
      fail!("#{role} codec is not LZ4") unless codec.valid_encoding? && codec.strip == 'CODEC(LZ4)'
      count = read_file(File.join(part, 'count.txt'), 1024, 'count').strip
      metadata_version = read_file(File.join(part, 'metadata_version.txt'), 1024, 'metadata_version').strip
      same!(count, '5', "#{role} count.txt")
      same!(metadata_version, '0', "#{role} metadata version")
      serialization_bytes = read_file(File.join(part, 'serialization.json'), 4 * 1024 * 1024, 'serialization.json')
      serialization = parse_json!(serialization_bytes, "#{role} serialization.json")
      fail!("#{role} serialization metadata is not an object") unless serialization.is_a?(Hash)
      expected_string = @profile == 'single' ? 0 : 1
      same!(serialization['version'], 1, "#{role} serialization metadata version")
      same!(serialization['propagate_types_serialization_versions_to_nested_types'], true, "#{role} nested version propagation")
      versions = serialization['types_serialization_versions']
      fail!("#{role} serialization versions are not an object") unless versions.is_a?(Hash)
      same!(versions['string'], expected_string, "#{role} actual String serialization version")
      records = serialization['columns']
      fail!("#{role} serialization columns are not an array") unless records.is_a?(Array)
      records.each do |entry|
        fail!("#{role} serialization record is malformed") unless entry.is_a?(Hash)
        same!(entry['kind'], 'Default', "#{role} serialization kind")
        if entry.key?('name')
          fail!("#{role} serialization record names undeclared column #{entry['name'].inspect}") unless entry['name'] == 'pk' || TYPES.key?(entry['name'])
        end
        same!(entry['num_rows'], 5, "#{role} recorded row count") if entry.key?('num_rows')
      end
      columns_expected = "columns format version: 1\n6 columns:\n`pk` UInt64\n" + TYPES.map { |name, type| "`#{name}` #{type}\n" }.join
      columns = read_file(File.join(part, 'columns.txt'), 1024 * 1024, 'columns.txt').force_encoding(Encoding::UTF_8)
      fail!("#{role} columns.txt differs from literal declaration") unless columns.valid_encoding? && columns == columns_expected
      substreams_text, sections, logical = parse_substreams(part)
      marks = logical.map do |stream|
        stem = W241::Auditor.stream_hash(stream)
        name = "#{stem}.mrk2"
        bytes = read_file(File.join(part, name), MAX_FILE_BYTES, "mark file #{name}")
        fail!("#{role} mark file #{name} is not plain complete mrk2") if bytes.empty? || (bytes.bytesize % 24) != 0
        tuples = bytes.unpack('Q<*').each_slice(3).map(&:dup)
        same!(tuples.map { |tuple| tuple.fetch(2) }, MARKS_WITH_EOF, "#{role} mark row grid #{stream}")
        {'name' => name, 'records' => tuples.size, 'rows' => tuples.map { |tuple| tuple.fetch(2) }, 'sha256' => sha_bytes(bytes)}
      end.sort_by { |entry| entry.fetch('name') }
      expected_stream_files = logical.flat_map do |stream|
        stem = W241::Auditor.stream_hash(stream)
        ["#{stem}.bin", "#{stem}.mrk2"]
      end.sort
      actual_stream_files = names.grep(/\A[0-9a-f]{32}\.(?:bin|mrk2|cmrk2|mrk3)\z/).sort
      same!(actual_stream_files, expected_stream_files, "#{role} exact Wide stream file roster")
      same!(names.sort, (BASE_PART_FILES + expected_stream_files).sort, "#{role} exact file closure")
      {'inventory' => inventory, 'codec' => codec.strip, 'serialization_bytes' => serialization_bytes,
       'serialization' => serialization, 'string_version' => expected_string,
       'columns_text' => columns, 'columns_substreams_text' => substreams_text,
       'sections' => sections, 'logical_substreams' => logical,
       'stream_files' => actual_stream_files, 'marks' => marks}
    end

    def expected_public_scan
      signatures = AuditStaticBinaryBulkTableW247.expected_signatures
      {'status' => 'ok', 'row_count' => 5, 'keys' => KEYS,
       'column_signatures' => TARGET_COLUMNS.each_with_object({}) { |column, out| out[column] = signatures.fetch(column) },
       'late_window' => {'keys' => [5], 'column_signatures' => TARGET_COLUMNS.each_with_object({}) do |column, out|
         out[column] = [signatures.fetch(column).last]
       end}}
    end

    def expected_offline_values
      {'status' => 'ok', 'columns' => TARGET_COLUMNS.each_with_object({}) do |column, out|
        out[column] = AuditStaticBinaryBulkTableW247.expected_signatures.fetch(column)
      end}
    end

    def authenticate_helper_reports!
      reports = @summary.fetch('helper_reports')
      exact_keys!(reports, %w[write reemit_inspect], 'helper report map')
      @write_report = parse_helper_stdout!(@details.fetch('helper_write').fetch(:stdout), 'write')
      @inspect_report = parse_helper_stdout!(@details.fetch('helper_inspect_reemit').fetch(:stdout), 'inspect')
      same!(reports['write'], @write_report, 'write report/raw stdout binding')
      same!(reports['reemit_inspect'], @inspect_report, 'inspect report/raw stdout binding')
      validate_helper_report!(@write_report, 'write', @part, @generated)
      validate_helper_report!(@inspect_report, 'inspect', @reemit_part, @reemit_snapshot)
    end

    def parse_helper_stdout!(bytes, action)
      text = bytes.dup.force_encoding(Encoding::UTF_8)
      fail!("helper #{action} stdout is not one UTF-8 JSON line") unless text.valid_encoding? && text.lines.size == 1 && text.end_with?("\n")
      parse_json!(text, "helper #{action} stdout")
    end

    def validate_helper_report!(report, action, part, inventory)
      exact_keys!(report, %w[
        action columns declarations files format keys mark_row_counts offline_values part physical_profile
        projection_scan public_typed_scan row_count strings
      ], "helper #{action} report")
      same!([report['format'], report['action'], report['part']], [HELPER_FORMAT, action, PART_NAME], "helper #{action} identity")
      same!([report['row_count'], report['keys'], report['mark_row_counts']], [5, KEYS, MARK_ROWS], "helper #{action} row/mark grid")
      same!(report['declarations'], {'pk' => 'UInt64'}.merge(TYPES), "helper #{action} literal declaration")
      same!(report['strings'], {
        'string0' => ROWS.map { |row| row.fetch('string0') }, 'string1' => ROWS.map { |row| row.fetch('string1') },
      }, "helper #{action} String0/String1 legacy scans")
      signatures = AuditStaticBinaryBulkTableW247.expected_signatures
      same!(report['columns'].keys.sort, TARGET_COLUMNS.sort, "helper #{action} recursive columns")
      TARGET_COLUMNS.each do |column_name|
        column = report.fetch('columns').fetch(column_name)
        exact_keys!(column, %w[mark_row_counts profile row_sha256 row_signatures type], "helper #{action} #{column_name}")
        expected = signatures.fetch(column_name)
        same!([column['type'], column['profile'], column['mark_row_counts'], column['row_signatures'], column['row_sha256']],
              [TYPES.fetch(column_name), @profile, MARK_ROWS, expected, expected.map { |signature| sha_bytes(signature) }],
              "helper #{action} #{column_name} typed rows")
      end
      same!(report['public_typed_scan'], expected_public_scan, "helper #{action} public WidePartTable scan")
      same!(report['offline_values'], expected_offline_values, "helper #{action} OfflineTable.values")
      same!(report['projection_scan'], {'status' => 'absent'}, "helper #{action} projection absence")
      files = report.fetch('files').map do |entry|
        exact_keys!(entry, %w[path size sha256], "helper #{action} file row")
        [entry.fetch('path'), entry.fetch('size'), checked_sha(entry.fetch('sha256'), "helper #{action} file")]
      end
      same!(files, inventory, "helper #{action} complete current file inventory")
      physical = physical_base(part, action == 'write' ? 'generated' : 'stock re-emitted')
      validate_helper_physical_profile!(report.fetch('physical_profile'), physical, action)
    end

    def validate_helper_physical_profile!(profile, physical, action)
      exact_keys!(profile, %w[
        codec columns_substreams_txt columns_txt physical_stream_files propagate_types_serialization_versions_to_nested_types
        serialization_json_present serialization_version string_serialization_version variant_discriminators
      ], "helper #{action} physical profile")
      same!([profile['codec'], profile['serialization_json_present'], profile['serialization_version'],
             profile['string_serialization_version'], profile['propagate_types_serialization_versions_to_nested_types'],
             profile['columns_txt'], profile['columns_substreams_txt']],
            [physical['codec'], true, physical['serialization']['version'], physical['string_version'],
             physical['serialization']['propagate_types_serialization_versions_to_nested_types'],
             physical['columns_text'], physical['columns_substreams_text']], "helper #{action} physical metadata")
      entries = profile.fetch('physical_stream_files')
      fail!("helper #{action} physical file list is malformed") unless entries.is_a?(Array)
      expected = physical.fetch('stream_files').map do |name|
        mark = physical.fetch('marks').find { |item| item.fetch('name') == name }
        {'path' => name, 'bytes' => File.size(File.join(action == 'write' ? @part : @reemit_part, name)),
         'plain_mark_records' => mark && mark.fetch('records')}
      end
      entries.each { |entry| exact_keys!(entry, %w[path bytes plain_mark_records], "helper #{action} physical stream entry") }
      same!(entries, expected, "helper #{action} physical stream files")
      variants = profile.fetch('variant_discriminators')
      sites = actual_variant_sites(physical.fetch('sections'))
      same!(variants.size, sites.size, "helper #{action} Variant discriminator count")
      variants.zip(sites).each do |entry, site|
        exact_keys!(entry, %w[column decoded_bytes decoded_prefix_hex decoded_sha256 file logical_stream mode mode_word role type],
                    "helper #{action} Variant site")
        same!([entry['column'], entry['type'], entry['logical_stream'], entry['file']],
              [site.fetch('column'), site.fetch('type'), site.fetch('logical_stream'), "#{W241::Auditor.stream_hash(site.fetch('logical_stream'))}.bin"],
              "helper #{action} Variant column/site identity")
        same!(entry['role'], site.fetch('role'), "helper #{action} Variant physical role")
        same!([entry['mode_word'], entry['mode']], [0, 'BASIC'], "helper #{action} actual Variant BASIC mode")
        file = File.join(action == 'write' ? @part : @reemit_part, entry.fetch('file'))
        same!(File.basename(file), entry['file'], "helper #{action} Variant stream file")
      end
    end

    def authenticate_invocations!
      records = @summary.fetch('invocations')
      fail!('invocation list is malformed') unless records.is_a?(Array)
      @records = {}
      @details = {}
      records.each do |record|
        exact_keys!(record, PROCESS_KEYS, 'process record')
        label = record.fetch('label')
        fail!("duplicate invocation label #{label}") if @records.key?(label)
        @records[label] = record
      end
      generated_sites = actual_variant_sites(physical_base(@part, 'generated').fetch('sections'))
      reemit_sites = actual_variant_sites(physical_base(@reemit_part, 'stock re-emitted').fetch('sections'))
      labels = ['helper_write'] + generated_sites.map { |site| "decompress_generated_#{W241::Auditor.stream_hash(site.fetch('logical_stream'))}" } +
        %w[native_create_input native_attach_check_rows native_create_reemit native_reemit_check_rows helper_inspect_reemit] +
        reemit_sites.map { |site| "decompress_reemit_#{W241::Auditor.stream_hash(site.fetch('logical_stream'))}" }
      same!(records.map { |record| record.fetch('label') }, labels, 'raw process order/labels')
      files = records.flat_map do |record|
        %w[argv_file stdin_file stdout_file stderr_file].map { |field| record.fetch(field) } + ["#{record.fetch('label')}.json"]
      end
      fail!('invocation artifact names are duplicated') unless files.uniq == files
      same!(Dir.children(root_path('invocations')).sort, files.sort, 'invocation artifact closure')
      records.each do |record|
        label = record.fetch('label')
        if %w[helper_write helper_inspect_reemit].include?(label)
          @details[label] = authenticate_helper_invocation!(record, label)
        elsif label.start_with?('decompress_')
          @details[label] = W241::Auditor.authenticate_w241_invocation!(@root, record, "W247 #{label}")
          authenticate_compressor_record!(record, label)
        else
          @details[label] = W241::Auditor.authenticate_w241_invocation!(@root, record, "W247 #{label}")
          authenticate_native_record!(record, label)
        end
      end
      true
    rescue KeyError, TypeError, ArgumentError, JSON::ParserError => error
      fail!("raw invocation authentication failed: #{error.class}: #{error.message}")
    end

    def safe_artifact_name(name, label)
      fail!("#{label} artifact name is unsafe") unless name.is_a?(String) && File.basename(name) == name && /\A[A-Za-z0-9_.-]+\z/.match?(name)
      name
    end

    def invocation_bytes(record, field, size_field = nil)
      file_field = "#{field}_file"
      hash_field = "#{field}_sha256"
      name = safe_artifact_name(record.fetch(file_field), field)
      bytes = read_file(root_path('invocations', name), MAX_ARTIFACT_BYTES, name)
      same!(sha_bytes(bytes), checked_sha(record.fetch(hash_field), name), "#{name} digest")
      same!(bytes.bytesize, record.fetch(size_field), "#{name} byte count") if size_field
      bytes
    end

    def authenticate_helper_invocation!(record, label)
      same!([record['process_kind'], record['process_classification'], record['exit'], record['signal'], record['timed_out']],
            ['crystal-helper', 'success', 0, nil, false], "#{label} outcome")
      same!([record['timeout_seconds'], record['termination_grace_seconds'], record['required_outer_run_safe_memory_limit_bytes']],
            [W241::TIMEOUT, W241::GRACE, W241::OUTER_RUN_SAFE_LIMIT], "#{label} process limits")
      same!([record['binary_path'], record['expected_binary_sha256'], record['binary_sha_before'], record['binary_sha_after'],
             record['max_threads'], record['max_memory_usage_bytes'], record['max_memory_usage_applicable'], record['store_path']],
            [@helper, @helper_sha, @helper_sha, @helper_sha, nil, nil, false, nil], "#{label} executable identity")
      same!(%w[spawn_error stdin_write_error stdout_read_error stderr_read_error].map { |key| record[key]},
            [nil, nil, nil, nil], "#{label} process errors")
      same!([record['argv_file'], record['stdin_file'], record['stdout_file'], record['stderr_file']],
            ["#{label}.argv.json", "#{label}.stdin.bin", "#{label}.stdout", "#{label}.stderr"], "#{label} raw artifact names")
      expected_argv = label == 'helper_write' ? [@helper, 'write', @part, @profile] : [@helper, 'inspect', @reemit_part]
      same!(record['argv'], expected_argv, "#{label} exact CLI")
      same!(record['binary_path'], @helper, "#{label} helper path")
      argv = invocation_bytes(record, 'argv')
      input = invocation_bytes(record, 'stdin', 'stdin_bytes')
      stdout = invocation_bytes(record, 'stdout', 'stdout_bytes')
      stderr = invocation_bytes(record, 'stderr', 'stderr_bytes')
      same!(input, ''.b, "#{label} stdin")
      same!(stderr, ''.b, "#{label} stderr")
      same!(parse_json!(argv, "#{label} argv artifact"), expected_argv, "#{label} argv artifact contents")
      same!(parse_json!(read_file(root_path('invocations', "#{label}.json"), 1024 * 1024, "#{label} record artifact"), "#{label} record artifact"),
            record, "#{label} record artifact binding")
      {input: input, stdout: stdout, stderr: stderr}
    end

    def authenticate_native_record!(record, label)
      same!(record['label'], label, "#{label} raw label")
      same!(record['argv'], [@clickhouse, 'local', '--path', root_path('stores', 'native'), '--session_timezone=UTC',
        '--max_threads=1', "--max_memory_usage=#{W241::MEMORY}", '--multiquery'], "#{label} bounded local argv")
      same!(record['required_outer_run_safe_memory_limit_bytes'], W241::OUTER_RUN_SAFE_LIMIT, "#{label} outer memory guard")
      same!(record['store_path'], root_path('stores', 'native'), "#{label} isolated store")
      same!(@details.fetch(label).fetch(:input).b, native_input(label).b, "#{label} literal SQL")
      true
    end

    def authenticate_compressor_record!(record, label)
      same!(record['argv'], [@clickhouse, 'compressor', '--decompress', '--threads=1'], "#{label} decompressor argv")
      same!([record['max_threads'], record['max_memory_usage_applicable'], record['store_path'], record['required_outer_run_safe_memory_limit_bytes']],
            [1, false, nil, W241::OUTER_RUN_SAFE_LIMIT], "#{label} decompressor bounds")
      true
    end

    def native_sql(label)
      case label
      when 'native_create_input' then create_sql(@input_table, PATH_TAG)
      when 'native_create_reemit' then create_sql(@reemit_table, PATH_TAG)
      when 'native_attach_check_rows'
        ["ALTER TABLE default.#{@input_table} ATTACH PART '#{PART_NAME}';",
         "SELECT '#{CHECK_BEGIN}' FORMAT TSVRaw;", "CHECK TABLE default.#{@input_table} FORMAT TSV;",
         "SELECT '#{CHECK_END}' FORMAT TSVRaw;", schema_sql(@input_table), parts_sql(@input_table), rows_sql(@input_table)].join("\n")
      when 'native_reemit_check_rows'
        ['SET materialize_statistics_on_insert=0;',
         "INSERT INTO default.#{@reemit_table} SELECT pk, root_variant, array_variant, named_recursive, string0, string1 FROM default.#{@input_table} ORDER BY pk;",
         "SELECT '#{CHECK_BEGIN}' FORMAT TSVRaw;", "CHECK TABLE default.#{@reemit_table} FORMAT TSV;",
         "SELECT '#{CHECK_END}' FORMAT TSVRaw;", schema_sql(@reemit_table), parts_sql(@reemit_table), rows_sql(@reemit_table)].join("\n")
      else fail!("unexpected native label #{label}")
      end
    end

    def create_sql(table, tag)
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
      "CREATE TABLE default.#{table} (#{declarations}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings};\n" \
        "SELECT '#{tag}', database, name, arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw;"
    end

    def schema_sql(table)
      "SELECT '#{SCHEMA_TAG}', name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw;"
    end

    def parts_sql(table)
      "SELECT '#{PART_TAG}', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw;"
    end

    def rows_sql(table)
      expressions = [
        'toString(pk)', "if(isNull(root_variant), 'NULL', variantType(root_variant))",
        "if(isNull(root_variant), hex('null'), hex(toJSONString(root_variant)))",
        "hex(toJSONString(arrayMap(x -> variantType(x), array_variant)))", 'hex(toJSONString(array_variant))',
        'hex(toJSONString(named_recursive.arr))', "if(isNull(named_recursive.labels), 'NULL', 'VALUE')",
        "if(isNull(named_recursive.labels), '', hex(named_recursive.labels))",
        "if(isNull(named_recursive.choice), 'NULL', variantType(named_recursive.choice))",
        "if(isNull(named_recursive.choice), hex('null'), hex(toJSONString(named_recursive.choice)))",
        'hex(string0)', 'hex(string1)',
      ]
      "SELECT '#{ROW_TAG}', #{expressions.join(', ')} FROM default.#{table} ORDER BY pk FORMAT TSVRaw;"
    end

    def native_input(label)
      pin = W241::Probe.allocate.send(:pin_sql)
      [pin, 'SET print_pretty_type_names=0;', native_sql(label)].join("\n") + "\n"
    end

    def authenticate_native_outputs!
      @input_path_raw = validate_create_stdout!('native_create_input', @input_table, @input_data_path)
      @reemit_path_raw = validate_create_stdout!('native_create_reemit', @reemit_table, @reemit_data_path)
      validate_check_stdout!('native_attach_check_rows', @input_table, @input_data_path, 'input')
      validate_check_stdout!('native_reemit_check_rows', @reemit_table, @reemit_data_path, 'reemit')
    end

    def lines(stdout, label)
      text = stdout.dup.force_encoding(Encoding::UTF_8)
      fail!("#{label} stdout is invalid UTF-8 or lacks final newline") unless text.valid_encoding? && text.end_with?("\n")
      text.lines.map(&:chomp)
    end

    def tagged(lines, tag, width)
      lines.select { |line| line.start_with?(tag + "\t") }.map do |line|
        fields = line.split("\t", -1)
        same!(fields.size, width, "#{tag} TSV width")
        fields
      end
    end

    def verify_pin(lines, label)
      same!(lines.first, "__W241_PIN__\t#{W241::VERSION}\t#{W241::BUILD}", "#{label} runtime stdout pin")
    end

    def canonical_native_path(path, label)
      fail!("#{label} is not a string") unless path.is_a?(String)
      normalized = path.end_with?(File::SEPARATOR) ? path[0...-1] : path
      canonical_store_path(normalized, label)
    end

    def validate_create_stdout!(label, table, expected_data_path)
      output_lines = lines(@details.fetch(label).fetch(:stdout), label)
      verify_pin(output_lines, label)
      rows = tagged(output_lines, PATH_TAG, 4)
      same!(rows.size, 1, "#{label} unique system.tables result")
      same!(rows.first.values_at(1, 2), ['default', table], "#{label} stock table identity")
      data_path = canonical_native_path(rows.first[3], "#{label} data path")
      same!(data_path, expected_data_path, "#{label} actual table path")
      same!(output_lines, [output_lines.first, rows.first.join("\t")], "#{label} exact stdout closure")
      rows.first[3]
    end

    def check_lines(output_lines)
      active = false
      values = []
      output_lines.each do |line|
        if line == CHECK_BEGIN
          fail!('nested CHECK begin marker') if active
          active = true
        elsif line == CHECK_END
          fail!('unmatched CHECK end marker') unless active
          active = false
        elsif active
          values << line
        end
      end
      fail!('unterminated CHECK markers') if active
      values
    end

    def parse_native_rows(rows, label)
      same!(rows.size, ROWS.size, "#{label} row count")
      rows.map do |fields|
        {'tag' => fields[0], 'pk' => Integer(fields[1], 10),
         'root_variant_type' => fields[2], 'root_variant' => parse_json_hex(fields[3], 'root Variant JSON'),
         'array_variant_types' => parse_json_hex(fields[4], 'Array Variant type JSON'),
         'array_variant' => parse_json_hex(fields[5], 'Array Variant JSON'),
         'named_recursive_arr' => parse_json_hex(fields[6], 'Tuple array JSON'),
         'named_recursive_labels_null' => fields[7],
         'named_recursive_labels' => fields[7] == 'NULL' ? nil : parse_string_hex(fields[8], 'Tuple label'),
         'named_recursive_choice_type' => fields[9], 'named_recursive_choice' => parse_json_hex(fields[10], 'Tuple Variant JSON'),
         'string0' => parse_string_hex(fields[11], 'String0'), 'string1' => parse_string_hex(fields[12], 'String1')}
      end
    end

    def parse_json_hex(hex, label)
      fail!("#{label} is not even-length hexadecimal") unless hex.is_a?(String) && /\A(?:[0-9a-fA-F]{2})*\z/.match?(hex)
      parse_json!([hex].pack('H*'), label)
    end

    def parse_string_hex(hex, label)
      fail!("#{label} is not even-length hexadecimal") unless hex.is_a?(String) && /\A(?:[0-9a-fA-F]{2})*\z/.match?(hex)
      value = [hex].pack('H*').force_encoding(Encoding::UTF_8)
      fail!("#{label} is not UTF-8") unless value.valid_encoding?
      value
    end

    def validate_check_stdout!(label, table, data_path, role)
      output_lines = lines(@details.fetch(label).fetch(:stdout), label)
      verify_pin(output_lines, label)
      check = check_lines(output_lines)
      same!(check, ["#{PART_NAME}\t1\t"], "#{role} CHECK TABLE = 1")
      schemas = tagged(output_lines, SCHEMA_TAG, 3).map { |row| row.drop(1) }
      expected_schema = ([KEY] + TYPES.map { |name, type| {'name' => name, 'type' => type} }).map do |column|
        [column.fetch('name'), column.fetch('type')]
      end
      same!(schemas, expected_schema, "#{role} system.columns schema")
      schema_lines = tagged(output_lines, SCHEMA_TAG, 3).map { |row| row.join("\t") }
      part_rows = tagged(output_lines, PART_TAG, 7)
      same!(part_rows.size, 1, "#{role} single active system.parts row")
      part = part_rows.first
      same!(part.values_at(1, 2, 4, 5, 6), [table, PART_NAME, 'Wide', '5', '4'], "#{role} actual Wide part rows/marks")
      part_path = canonical_native_path(part[3], "#{role} active part path")
      same!(part_path, File.join(data_path, PART_NAME), "#{role} active part binding")
      row_lines = tagged(output_lines, ROW_TAG, 13).map { |row| row.join("\t") }
      semantic_rows = parse_native_rows(tagged(output_lines, ROW_TAG, 13), role)
      same!(semantic_rows, AuditStaticBinaryBulkTableW247.expected_native_rows, "#{role} exact literal stock rows")
      @observed_rows ||= {}
      @observed_rows[role] = semantic_rows
      parts = @summary.fetch('parts')
      parts_key = role == 'input' ? 'input_part' : 'reemit_part'
      check_key = role == 'input' ? 'input_check' : 'reemit_check'
      schema_key = role == 'input' ? 'input_schema' : 'reemit_schema'
      same!(parts.fetch(parts_key), part.drop(1), "#{role} part summary/raw stdout")
      same!(parts.fetch(check_key), check, "#{role} CHECK summary/raw stdout")
      same!(parts.fetch(schema_key), schemas, "#{role} schema summary/raw stdout")
      native_rows_key = role == 'input' ? 'attached' : 'reemit'
      same!(@summary.fetch('native_rows').fetch(native_rows_key), semantic_rows, "#{role} semantic row summary/raw stdout")
      part_lines = part_rows.map { |row| row.join("\t") }
      expected_lines = [output_lines.first, CHECK_BEGIN] + check + [CHECK_END] + schema_lines + part_lines + row_lines
      same!(output_lines, expected_lines, "#{label} exact stdout line/order closure")
      true
    end

    def authenticate_physical_profiles!
      profiles = @summary.fetch('physical_profiles')
      exact_keys!(profiles, %w[generated stock_reemit], 'physical profile map')
      generated = physical_summary(@part, 'generated', 'generated')
      reemit = physical_summary(@reemit_part, 'reemit', 'stock_reemit')
      same!(profiles['generated'], generated, 'generated physical profile recomputation')
      same!(profiles['stock_reemit'], reemit, 'stock re-emitted physical profile recomputation')
      true
    end

    def physical_summary(part, role, summary_key)
      base = physical_base(part, role)
      sites = actual_variant_sites(base.fetch('sections'))
      decompressed = sites.map do |site|
        logical = site.fetch('logical_stream')
        file = "#{W241::Auditor.stream_hash(logical)}.bin"
        compressed = read_file(File.join(part, file), MAX_FILE_BYTES, "#{role} compressed Variant stream")
        label = "decompress_#{role}_#{W241::Auditor.stream_hash(logical)}"
        details = @details.fetch(label)
        same!(details.fetch(:input).b, compressed, "#{role} compressor captured compressed bytes")
        raw = details.fetch(:stdout).b
        fail!("#{role} discriminator stream is shorter than its mode word") unless raw.bytesize >= 8
        mode_word = raw.unpack1('Q<')
        same!(mode_word, 0, "#{role} BASIC Variant discriminator mode word")
        helper_report = summary_key == 'generated' ? @write_report : @inspect_report
        helper_entry = helper_report.fetch('physical_profile').fetch('variant_discriminators').find do |entry|
          entry['column'] == site.fetch('column') && entry['logical_stream'] == logical
        end
        fail!("#{role} helper Variant site is absent") unless helper_entry
        same!([helper_entry['decoded_bytes'], helper_entry['decoded_sha256'], helper_entry['decoded_prefix_hex'], helper_entry['mode_word'], helper_entry['mode']],
              [raw.bytesize, sha_bytes(raw), raw.byteslice(0, 8).unpack1('H*'), 0, 'BASIC'], "#{role} helper/raw decoded Variant bytes")
        {'column' => site.fetch('column'), 'type' => site.fetch('type'), 'role' => helper_entry.fetch('role'),
         'logical_stream' => logical, 'physical_file' => file, 'physical_sha256' => sha_file(File.join(part, file)),
         'decoded_bytes' => raw.bytesize, 'decoded_sha256' => sha_bytes(raw), 'mode_word' => mode_word,
         'mode_word_le_hex' => raw.byteslice(0, 8).unpack1('H*'), 'invocation_label' => label}
      end
      part_type = summary_key == 'stock_reemit' ? 'Wide' : 'fixture-generated-Wide'
      {'part_type' => part_type, 'codec' => base.fetch('codec'), 'mark_extension' => 'mrk2', 'sparse' => false,
       'serialization_json_sha256' => sha_bytes(base.fetch('serialization_bytes')),
       'serialization' => base.fetch('serialization'), 'string_version' => base.fetch('string_version'),
       'columns_text' => base.fetch('columns_text'), 'columns_substreams_text' => base.fetch('columns_substreams_text'),
       'logical_substreams' => base.fetch('logical_substreams'), 'stream_files' => base.fetch('stream_files'),
       'mark_profiles' => base.fetch('marks'), 'variant_modes' => decompressed}
    end

    def verify_files(rows, label)
      rows.each do |entry|
        fail!("#{label} inventory entry is malformed") unless entry.is_a?(Array) && entry.size == 3
        name, size, digest = entry
        safe_artifact_name(name, label)
        checked_sha(digest, label)
        fail!("#{label} entry size is malformed") unless size.is_a?(Integer) && size >= 0
      end
    end

    def native_rows_json(rows)
      rows
    end

    def self_test!
      controls = {}
      controls['literal_rows_exact'] = expected_rows_valid?(AuditStaticBinaryBulkTableW247.expected_native_rows)
      mutated_rows = AuditStaticBinaryBulkTableW247.expected_native_rows.map(&:dup)
      mutated_rows[0]['string1'] = 'mutated'
      controls['stock_row_mutation_rejected'] = !expected_rows_valid?(mutated_rows)
      controls['check_one_accepted'] = check_valid?("#{PART_NAME}\t1\t")
      controls['check_zero_rejected'] = !check_valid?("#{PART_NAME}\t0\t")
      controls['default_empty_columns_accepted'] = serialization_columns_valid?([])
      controls['default_records_accepted'] = serialization_columns_valid?([{'kind' => 'Default', 'name' => 'pk', 'num_rows' => 5}])
      controls['sparse_kind_rejected'] = !serialization_columns_valid?([{'kind' => 'Sparse', 'name' => 'pk', 'num_rows' => 5}])
      controls['wrong_serialization_rows_rejected'] = !serialization_columns_valid?([{'kind' => 'Default', 'name' => 'pk', 'num_rows' => 4}])
      controls['basic_variant_mode_accepted'] = mode_valid?(0)
      controls['compact_variant_mode_rejected'] = !mode_valid?(1)
      controls['path_escape_rejected'] = !contained_store_path?('/private/tmp/evidence/stores/native/../outside', '/private/tmp/evidence/stores/native')
      controls['duplicate_json_keys_rejected'] = duplicate_json_rejected?
      fail!('one or more adversary controls admitted a mutation') unless controls.values.all?
      controls
    end

    def expected_rows_valid?(rows)
      rows == AuditStaticBinaryBulkTableW247.expected_native_rows
    end

    def check_valid?(line)
      line == "#{PART_NAME}\t1\t"
    end

    def mode_valid?(word)
      word == 0
    end

    def serialization_columns_valid?(columns)
      return false unless columns.is_a?(Array)
      columns.all? do |entry|
        entry.is_a?(Hash) && entry['kind'] == 'Default' &&
          (!entry.key?('name') || entry['name'] == 'pk' || TYPES.key?(entry['name'])) &&
          (!entry.key?('num_rows') || entry['num_rows'] == 5)
      end
    end

    def contained_store_path?(path, root)
      path.is_a?(String) && root.is_a?(String) && path.start_with?(root + File::SEPARATOR) &&
        !path.split(File::SEPARATOR).any? { |piece| piece == '.' || piece == '..' }
    end

    def duplicate_json_rejected?
      parse_json!('{"x":1,"x":2}', 'self-test duplicate JSON')
      false
    rescue Failure
      true
    end
  end
end

def main
  options = {}
  parser = OptionParser.new do |opts|
    opts.banner = 'Usage: audit_static_binary_bulk_table_w247.rb --summary PATH --summary-sha256 SHA --clickhouse PATH --helper PATH --helper-sha256 SHA --probe-source PATH --probe-source-sha256 SHA --helper-source PATH --helper-source-sha256 SHA --fixture-source PATH --fixture-source-sha256 SHA --auditor-source PATH --auditor-source-sha256 SHA --self-test'
    opts.on('--summary PATH') { |value| options[:summary_path] = value }
    opts.on('--summary-sha256 SHA') { |value| options[:summary_sha256] = value }
    opts.on('--clickhouse PATH') { |value| options[:clickhouse] = value }
    opts.on('--helper PATH') { |value| options[:helper_path] = value }
    opts.on('--helper-sha256 SHA') { |value| options[:helper_sha256] = value }
    opts.on('--probe-source PATH') { |value| options[:probe_source] = value }
    opts.on('--probe-source-sha256 SHA') { |value| options[:probe_source_sha256] = value }
    opts.on('--helper-source PATH') { |value| options[:helper_source] = value }
    opts.on('--helper-source-sha256 SHA') { |value| options[:helper_source_sha256] = value }
    opts.on('--fixture-source PATH') { |value| options[:fixture_source] = value }
    opts.on('--fixture-source-sha256 SHA') { |value| options[:fixture_source_sha256] = value }
    opts.on('--auditor-source PATH') { |value| options[:auditor_source] = value }
    opts.on('--auditor-source-sha256 SHA') { |value| options[:auditor_source_sha256] = value }
    opts.on('--self-test') { options[:self_test] = true }
    opts.on('--self-test-only') { options[:self_test_only] = true }
  end
  parser.parse!
  if options[:self_test_only]
    auditor = AuditStaticBinaryBulkTableW247::Auditor.allocate
    controls = auditor.send(:self_test!)
    puts JSON.generate(status: 'self_test_passed', controls: controls)
    return
  end
  required = %i[summary_path summary_sha256 clickhouse helper_path helper_sha256 probe_source probe_source_sha256
                helper_source helper_source_sha256 fixture_source fixture_source_sha256 auditor_source auditor_source_sha256]
  required.each { |key| raise ArgumentError, "--#{key.to_s.tr('_', '-')} is required" unless options[key] }
  puts JSON.generate(AuditStaticBinaryBulkTableW247::Auditor.new(**options).run)
rescue AuditStaticBinaryBulkTableW247::Failure, ArgumentError, KeyError, TypeError => error
  warn error.message
  exit 1
end

main if $PROGRAM_NAME == __FILE__
