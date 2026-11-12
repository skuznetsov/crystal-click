#!/usr/bin/env ruby
# Read-only W283 raw-capture auditor. It never starts ClickHouse, Crystal, or a build.

require 'digest'
require 'find'
require 'json'
require 'open3'
require 'optparse'
require_relative 'compact_variant_bulk_w283_paths'
require_relative 'probe_compact_variant_bulk_w283_matrix'
require_relative 'verify_compact_low_cardinality_bulk_w282_capture'

module VerifyCompactVariantBulkW283Capture
  M = ProbeCompactVariantBulkW283Matrix
  Base = VerifyCompactLowCardinalityBulkW282Capture::Auditor
  W = M::W280
  PATHS = CompactVariantBulkW283Paths
  W283_PROBE_SOURCE = File.expand_path('probe_compact_variant_bulk_w283_matrix.rb', __dir__).freeze
  W283_FIXTURE_SOURCE = File.expand_path('../spec/support/compact_part_writer_w283_fixture.cr', __dir__).freeze
  FORMAT = M::FORMAT.freeze
  STOCK_STATUS = 'stock_native_matrix_exact'.freeze
  FULL_STATUS = 'generated_native_interop_matrix_exact'.freeze
  FULL_BINARY_SHA256 = '5bb43958f4c0806cc363b84b9858e7206e56ac80263a24acc704271322e531ae'.freeze
  FULL_BINARY_BYTES = 919_123_095
  FULL_VERSION = '26.10.1.1201'.freeze
  FULL_BUILD = 'd9bcb5ab007f0f6299f7f973f2642245bab3d028'.freeze
  PIN_SQL = "SELECT '__W280_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;\n".b.freeze
  PIN_LINE = "__W280_PIN__\t#{FULL_VERSION}\t#{FULL_BUILD}".freeze
  COLUMN = 'recursive_variant_w283'.freeze
  JSON_DECLARATION = 'JSON(max_dynamic_types=0, max_dynamic_paths=0, id UInt64)'.freeze
  VARIANT_DECLARATION = 'Variant(Array(UInt8), String, UInt64)'.freeze
  TYPE = "Tuple(#{JSON_DECLARATION}, Array(Tuple(#{VARIANT_DECLARATION}, LowCardinality(String))), " \
         "#{JSON_DECLARATION}, Tuple(LowCardinality(String), #{VARIANT_DECLARATION}, " \
         "Map(String, #{VARIANT_DECLARATION}), Nested(choice #{VARIANT_DECLARATION}, " \
         'label LowCardinality(String))))'.freeze
  SCHEMA = [['pk', 'UInt64'], [COLUMN, TYPE]].map(&:freeze).freeze
  MARK_ROWS = [2, 2, 2, 2, 0].freeze
  PUBLIC_ROWS = [2, 2, 2, 2].freeze
  WINDOWS = {'full' => nil, 'middle' => 'pk BETWEEN 3 AND 6',
    'last' => 'pk BETWEEN 7 AND 8', 'eof' => 'pk > 8'}.freeze
  PHYSICAL_WINDOWS = {'full' => [0, 4], 'middle' => [1, 2], 'last' => [3, 1], 'eof' => [4, 0]}.freeze
  SIDECAR_PATH = 'invalidated_system_columns.txt'.freeze
  SIDECAR_BYTES = "_block_offset\n_block_number\n".b.freeze
  SIDECAR_ENTRY = {'path' => SIDECAR_PATH, 'size' => 28,
    'sha256' => '7409424ab45090c1261e622f7423393905102e7e8cba36a6db88eb513ce1e06c'}.freeze
  PREFIX_CLAIM = 'MRK4 callback slot names and order are observed physical metadata. No Variant payload decoder, discriminator-byte interpretation, or per-site DFS semantic ordering is claimed; independent native and public-reader value windows provide the value oracle.'.freeze
  EXECUTION_SCOPE = 'Stock-only captures the exact recursive JSON / Variant / LowCardinality declaration across BASIC/COMPACT × MRK3/MRK4 × S0/S1 before helper use. Full mode repeats all stock controls, reads their parts, then writes generated parts and checks native ATTACH/reopen. Ruby RowBinary and signatures are independent literals; no root-Variant substitute is used.'.freeze
  CLAIM_BOUNDARY = 'Finite eight-row, four-data-mark evidence for this exact recursive JSON/Tuple declaration only, under MAP0/BASIC/V3 and BASIC/COMPACT × MRK3/MRK4 × S0/S1. A stock schema rejection is a blocked native-compatibility probe, not permission to substitute a root Variant or easier wrapper. Generated success is limited to this composition and requires exact public-reader windows plus byte-preserving ATTACH, CHECK, native windows, raw sidecars, and pinned source/runtime/helper identities.'.freeze
  REC_KEYS = %w[
    label process_kind argv argv_file argv_sha256 stdin_file stdin_bytes stdin_sha256
    stdout_file stdout_bytes stdout_sha256 stderr_file stderr_bytes stderr_sha256 exit signal timed_out
    timeout_seconds termination_grace_seconds max_threads max_memory_usage_bytes max_memory_usage_applicable
    required_outer_run_safe_memory_limit_bytes binary_path expected_binary_sha256 binary_sha_before
    binary_sha_after spawn_error stdin_write_error stdout_read_error stderr_read_error process_classification
    store_path
  ].sort.freeze
  MAX_FILE = 64 * 1024 * 1024

  # Duplicated literals are the auditor oracle; they do not read the fixture, probe, helper, or output.
  INVALID_BYTES = [0x00, 0xff, 0x80, 0x41].pack('C*').b.freeze
  ORACLE_ROWS = [
    {left: 1, array: [], right: 101, root_lc: 'root-lc-0'.b, root_variant: [:null, nil], map: [], nested: []},
    {left: 2, array: [], right: 102, root_lc: 'root-lc-1'.b, root_variant: [:null, nil], map: [], nested: []},
    {left: 3, array: [[[:null, nil], 'null-2'.b]], right: 103, root_lc: 'root-lc-2'.b,
      root_variant: [:null, nil], map: [['null-2'.b, [:null, nil]]], nested: [[[:null, nil], 'null-2'.b]]},
    {left: 4, array: [[[:null, nil], 'null-3'.b]], right: 104, root_lc: 'root-lc-3'.b,
      root_variant: [:null, nil], map: [['null-3'.b, [:null, nil]]], nested: [[[:null, nil], 'null-3'.b]]},
    {left: 5, array: [[[:array, []], 'empty-array'.b], [[:string, ''.b], 'empty-string'.b],
      [[:uint64, 0], 'zero-u64'.b]], right: 105, root_lc: 'root-lc-4'.b, root_variant: [:array, []],
      map: [['empty'.b, [:array, []]], ['null'.b, [:null, nil]]],
      nested: [[[:array, []], 'empty'.b], [[:null, nil], 'null'.b]]},
    {left: 6, array: [[[:null, nil], 'null-5'.b], [[:array, [0, 255]], 'bytes-5'.b],
      [[:string, "middle\0".b], 'middle'.b]], right: 106, root_lc: 'root-lc-5'.b,
      root_variant: [:string, "root\0".b], map: [['middle'.b, [:string, "map\0".b]]],
      nested: [[[:string, "nested\0".b], 'middle'.b]]},
    {left: 7, array: [[[:string, INVALID_BYTES], 'late-binary'.b],
      [[:uint64, 0x0102_0304_0506_0708], 'late-u64'.b]], right: 107, root_lc: 'root-lc-6'.b,
      root_variant: [:uint64, 0xdead_beef_cafe_babe],
      map: [['late-u64'.b, [:uint64, 0x1122_3344_5566_7788]]],
      nested: [[[:uint64, 0x8877_6655_4433_2211], 'late-u64'.b]]},
    {left: 8, array: [[[:array, [255, 0, 127]], 'tail-bytes'.b],
      [[:uint64, 0xfedc_ba98_7654_3210], 'tail-u64'.b], [[:string, "tail\0".b], 'tail-string'.b]],
      right: 108, root_lc: 'root-lc-7'.b, root_variant: [:string, INVALID_BYTES],
      map: [['late-binary'.b, [:string, INVALID_BYTES]]],
      nested: [[[:string, INVALID_BYTES], 'late-binary'.b]]},
  ].freeze
  ORACLE_SIGNATURES = [
    '1|A[]|101|B(726f6f742d6c632d30|N|M[]|N[])',
    '2|A[]|102|B(726f6f742d6c632d31|N|M[]|N[])',
    '3|A[N/6e756c6c2d32]|103|B(726f6f742d6c632d32|N|M[6e756c6c2d32=N]|N[N/6e756c6c2d32])',
    '4|A[N/6e756c6c2d33]|104|B(726f6f742d6c632d33|N|M[6e756c6c2d33=N]|N[N/6e756c6c2d33])',
    '5|A[A[]/656d7074792d6172726179;S/656d7074792d737472696e67;U0/7a65726f2d753634]|105|B(726f6f742d6c632d34|A[]|M[656d707479=A[];6e756c6c=N]|N[A[]/656d707479;N/6e756c6c])',
    '6|A[N/6e756c6c2d35;A[00,ff]/62797465732d35;S6d6964646c6500/6d6964646c65]|106|B(726f6f742d6c632d35|S726f6f7400|M[6d6964646c65=S6d617000]|N[S6e657374656400/6d6964646c65])',
    '7|A[S00ff8041/6c6174652d62696e617279;U72623859790382856/6c6174652d753634]|107|B(726f6f742d6c632d36|U16045690984503098046|M[6c6174652d753634=U1234605616436508552]|N[U9833440827789222417/6c6174652d753634])',
    '8|A[A[ff,00,7f]/7461696c2d6279746573;U18364758544493064720/7461696c2d753634;S7461696c00/7461696c2d737472696e67]|108|B(726f6f742d6c632d37|S00ff8041|M[6c6174652d62696e617279=S00ff8041]|N[S00ff8041/6c6174652d62696e617279])',
  ].freeze

  S0_STREAMS = %w[
    recursive_variant_w283%2E1.object_structure
    recursive_variant_w283%2E2%2E1.variant_discr_prefix
    recursive_variant_w283%2E2%2E2.dict_prefix
    recursive_variant_w283%2E3.object_structure
    recursive_variant_w283%2E4%2E1.dict_prefix
    recursive_variant_w283%2E4%2E2.variant_discr_prefix
    recursive_variant_w283%2E4%2E3%2Evalues.variant_discr_prefix
    recursive_variant_w283%2E4%2E4%2Echoice.variant_discr_prefix
    recursive_variant_w283%2E4%2E4%2Elabel.dict_prefix
    recursive_variant_w283%2E1.id
    recursive_variant_w283%2E1.object_shared_data.size0
    recursive_variant_w283%2E1.object_shared_data%2Epaths
    recursive_variant_w283%2E1.object_shared_data%2Evalues
    recursive_variant_w283%2E2.size0
    recursive_variant_w283%2E2%2E1.variant_discr
    recursive_variant_w283%2E2%2E1.Array%28UInt8%29.size1
    recursive_variant_w283%2E2%2E1.Array%28UInt8%29
    recursive_variant_w283%2E2%2E1.String
    recursive_variant_w283%2E2%2E1.UInt64
    recursive_variant_w283%2E2%2E2.dict
    recursive_variant_w283%2E2%2E2
    recursive_variant_w283%2E3.id
    recursive_variant_w283%2E3.object_shared_data.size0
    recursive_variant_w283%2E3.object_shared_data%2Epaths
    recursive_variant_w283%2E3.object_shared_data%2Evalues
    recursive_variant_w283%2E4%2E1.dict
    recursive_variant_w283%2E4%2E1
    recursive_variant_w283%2E4%2E2.variant_discr
    recursive_variant_w283%2E4%2E2.Array%28UInt8%29.size0
    recursive_variant_w283%2E4%2E2.Array%28UInt8%29
    recursive_variant_w283%2E4%2E2.String
    recursive_variant_w283%2E4%2E2.UInt64
    recursive_variant_w283%2E4%2E3.size0
    recursive_variant_w283%2E4%2E3%2Ekeys
    recursive_variant_w283%2E4%2E3%2Evalues.variant_discr
    recursive_variant_w283%2E4%2E3%2Evalues.Array%28UInt8%29.size1
    recursive_variant_w283%2E4%2E3%2Evalues.Array%28UInt8%29
    recursive_variant_w283%2E4%2E3%2Evalues.String
    recursive_variant_w283%2E4%2E3%2Evalues.UInt64
    recursive_variant_w283%2E4%2E4.size0
    recursive_variant_w283%2E4%2E4%2Echoice.variant_discr
    recursive_variant_w283%2E4%2E4%2Echoice.Array%28UInt8%29.size1
    recursive_variant_w283%2E4%2E4%2Echoice.Array%28UInt8%29
    recursive_variant_w283%2E4%2E4%2Echoice.String
    recursive_variant_w283%2E4%2E4%2Echoice.UInt64
    recursive_variant_w283%2E4%2E4%2Elabel.dict
    recursive_variant_w283%2E4%2E4%2Elabel
  ].freeze
  S1_INSERTIONS = {
    'recursive_variant_w283%2E2%2E1.String' => 'recursive_variant_w283%2E2%2E1.String.size',
    'recursive_variant_w283%2E4%2E2.String' => 'recursive_variant_w283%2E4%2E2.String.size',
    'recursive_variant_w283%2E4%2E3%2Ekeys' => 'recursive_variant_w283%2E4%2E3%2Ekeys.size',
    'recursive_variant_w283%2E4%2E3%2Evalues.String' => 'recursive_variant_w283%2E4%2E3%2Evalues.String.size',
    'recursive_variant_w283%2E4%2E4%2Echoice.String' => 'recursive_variant_w283%2E4%2E4%2Echoice.String.size',
  }.freeze

  class Error < StandardError; end

  class Auditor < Base
    def initialize(root, mode:)
      canonical_root = PATHS.validate_evidence_root(root, purpose: :audit)
      super(canonical_root, mode: mode)
    end

    def run
      summary_contract!
      pins!
      topology!
      invocations!
      cases!
      sidecar_inventory!
      root_inventory!
      puts "W283 capture audit passed: mode=#{@mode}; cells=8; invocations=#{@records.size}; Variant bytes remain uninterpreted"
      true
    rescue StandardError => error
      warn "W283 capture audit failed: #{error.class}: #{error.message}"
      false
    end

    def self.self_test!
      a = allocate
      a.instance_variable_set(:@root, '/private/tmp/w283-auditor-seed')
      a.instance_variable_set(:@mode, :stock_only)
      a.send(:summary_status!, {'format' => FORMAT, 'status' => STOCK_STATUS}, :stock_only)
      a.send(:summary_status!, {'format' => FORMAT, 'status' => FULL_STATUS}, :full_matrix)
      checks = ['stock-and-full-exact-status-positive']
      %w[stock_schema_rejection_captured probe_infrastructure_failure incomplete_or_discrepant].each do |status|
        a.send(:reject!) { a.send(:summary_status!, {'format' => FORMAT, 'status' => status}, :stock_only) }
      end
      a.send(:reject!) { a.send(:summary_status!, {'format' => 'forged', 'status' => FULL_STATUS}, :full_matrix) }
      checks << 'schema-red-infrastructure-forged-status-negative'
      ids = a.send(:expected_ids)
      labels = a.send(:expected_labels, :stock_only)
      raise Error, 'eight-cell topology seed differs' unless ids.size == 8 && labels.size == 64
      a.send(:topology_labels!, labels, :stock_only)
      a.send(:reject!) { a.send(:topology_labels!, labels.drop(1), :stock_only) }
      a.send(:reject!) { a.send(:topology_labels!, labels.rotate(1), :stock_only) }
      full_labels = a.send(:expected_labels, :full_matrix)
      raise Error, 'full W283 topology seed differs' unless full_labels.size == 144 &&
        full_labels.fetch(64) == "#{ids.first}_helper_stock" &&
        full_labels.fetch(72) == "#{ids.first}_helper_write"
      a.send(:topology_labels!, full_labels, :full_matrix)
      a.send(:reject!) { a.send(:topology_labels!, full_labels.drop(1), :full_matrix) }
      a.send(:reject!) { a.send(:topology_labels!, full_labels.rotate(1), :full_matrix) }
      checks << 'stock-and-full-invocation-topology-positive-and-mutants'

      profile_id = ids.first
      %w[_generated _attached].each do |suffix|
        actual_id = "#{profile_id}#{suffix}"
        raise Error, "generated part profile seed differs for #{actual_id}" unless
          a.send(:profile_for_case_id, actual_id) == profile_id.split('_').last
      end
      a.send(:reject!) { a.send(:profile_for_case_id, "#{profile_id}_generated_extra") }
      a.send(:reject!) { a.send(:profile_for_case_id, 'ambiguous_s0') }
      checks << 'strict-stock-generated-and-attached-profile-labels'

      expected = a.send(:rowbinary_rows)
      raise Error, 'independent RowBinary seed has wrong row/byte count' unless expected.size == 8 && expected.sum(&:bytesize).positive?
      sigs = a.send(:literal_signatures)
      raise Error, 'independent Variant signatures differ' unless sigs == ORACLE_SIGNATURES && sigs.uniq.size == 8
      rows = a.send(:window_rows, 'full', 'stock_bulk_basic_mrk3_s0')
      a.send(:validate_window_rows!, 'stock_bulk_basic_mrk3_s0', 'full', rows)
      changed = Marshal.load(Marshal.dump(rows)); changed[6][2] = 'U0'
      a.send(:reject!) { a.send(:validate_window_rows!, 'stock_bulk_basic_mrk3_s0', 'full', changed) }
      checks << 'independent-literal-window-positive-and-changed-row-negative'

      good = a.send(:helper_report_seed, 'compact', 'mrk4', 's0', 'read', '/fixture/part')
      a.send(:helper_report!, 'stock_bulk_compact_mrk4_s0', 'compact', 'mrk4', 's0', good, 'read', '/fixture/part')
      wrong = Marshal.load(Marshal.dump(good)); wrong['reader_ordinary_profile'] = 's1'
      a.send(:reject!) { a.send(:helper_report!, 'stock_bulk_compact_mrk4_s0', 'compact', 'mrk4', 's0', wrong, 'read', '/fixture/part') }
      wrong = Marshal.load(Marshal.dump(good)); wrong['recursive_windows']['last']['signatures'].pop
      a.send(:reject!) { a.send(:helper_report!, 'stock_bulk_compact_mrk4_s0', 'compact', 'mrk4', 's0', wrong, 'read', '/fixture/part') }
      checks << 'helper-observed-profile-and-window-negative'

      a.send(:expected_mrk4_sections, 's0')
      a.send(:expected_mrk4_sections, 's1')
      a.send(:literal_occurrence_schedule!)
      a.send(:prefix_roster!, S0_STREAMS)
      a.send(:reject!) { a.send(:prefix_roster!, S0_STREAMS.reject { |name| name == 'recursive_variant_w283%2E2%2E2.dict_prefix' }) }
      checks << 'independent-zero-all-null-mixed-Q-schedule-and-prefix-mutant'

      mark_bytes = a.send(:seed_mark_bytes, 2, MARK_ROWS)
      raise Error, 'plain MRK3 grid seed differs' unless a.send(:plain_marks!, mark_bytes, 2, expected_rows: MARK_ROWS) == MARK_ROWS
      a.send(:reject!) { a.send(:plain_marks!, mark_bytes, 2, expected_rows: [2, 2, 2, 1, 1]) }
      checks << 'raw-mark-grid-including-EOF-positive-and-mutant'

      files = [
        {'path' => 'data.mrk3', 'size' => 8, 'sha256' => a.send(:sha, 'mark')},
        {'path' => 'serialization.json', 'size' => 2, 'sha256' => a.send(:sha, '{}')},
      ]
      source = {'files' => files, 'total_bytes' => 10}
      attached = {'files' => (files + [SIDECAR_ENTRY]).sort_by { |file| file['path'] }, 'total_bytes' => 38}
      a.send(:attached_contract!, source, attached, SIDECAR_BYTES)
      a.send(:reject!) { a.send(:attached_contract!, source, attached, 'modified'.b) }
      missing = Marshal.load(Marshal.dump(attached)); missing['files'].pop; missing['total_bytes'] -= SIDECAR_BYTES.bytesize
      a.send(:reject!) { a.send(:attached_contract!, source, missing, SIDECAR_BYTES) }
      checks << 'ATTACH-byte-preservation-exact-sidecar-positive-and-mutants'

      root_entries = %w[invocations parts raw-records source-inventories stores summary.json summary.md]
      a.send(:root_inventory_contract!, root_entries, ids, [], :stock_only)
      a.send(:reject!) { a.send(:root_inventory_contract!, root_entries - ['parts'], ids, [], :stock_only) }
      a.send(:reject!) { a.send(:root_inventory_contract!, root_entries, ids, ['unexpected'], :stock_only) }
      full_stores = ids + ids.map { |id| "target_#{id}" }
      a.send(:root_inventory_contract!, root_entries, full_stores, ids, :full_matrix)
      a.send(:reject!) { a.send(:root_inventory_contract!, root_entries, full_stores, ids.drop(1), :full_matrix) }
      checks << 'stock-empty-parts-and-full-generated-root-topology-mutants'

      runtime_path = '/opt/mldata_ssd/cache/crystal-click-w283.PDWAiK/recovery/runtime/clickhouse'
      runtime = {'binary' => runtime_path, 'expected_sha256' => FULL_BINARY_SHA256,
        'sha256_before' => FULL_BINARY_SHA256, 'sha256_after' => FULL_BINARY_SHA256,
        'expected_bytes' => FULL_BINARY_BYTES, 'bytes_before' => FULL_BINARY_BYTES,
        'bytes_after' => FULL_BINARY_BYTES, 'version' => FULL_VERSION, 'build' => FULL_BUILD}
      a.send(:runtime_metadata!, runtime, runtime_path)
      %w[expected_sha256 sha256_before sha256_after].each do |key|
        changed = runtime.merge(key => '0' * 64)
        a.send(:reject!) { a.send(:runtime_metadata!, changed, runtime_path) }
      end
      %w[expected_bytes bytes_before bytes_after].each do |key|
        changed = runtime.merge(key => FULL_BINARY_BYTES - 1)
        a.send(:reject!) { a.send(:runtime_metadata!, changed, runtime_path) }
      end
      {'version' => 'forged-version', 'build' => 'forged-build'}.each do |key, value|
        a.send(:reject!) { a.send(:runtime_metadata!, runtime.merge(key => value), runtime_path) }
      end
      a.instance_variable_set(:@summary, {'helper_pin' => {'expected_sha256' => 'a' * 64}})
      native = {'expected_binary_sha256' => FULL_BINARY_SHA256,
        'binary_sha_before' => FULL_BINARY_SHA256, 'binary_sha_after' => FULL_BINARY_SHA256}
      a.send(:invocation_pin!, 'native seed', native, FULL_BINARY_SHA256)
      a.send(:reject!) { a.send(:invocation_pin!, 'native seed', native.merge(
        'expected_binary_sha256' => W::BINARY_SHA256), FULL_BINARY_SHA256) }
      helper_sha = a.send(:expected_invocation_sha256, 'crystal-helper')
      helper = {'expected_binary_sha256' => helper_sha, 'binary_sha_before' => helper_sha,
        'binary_sha_after' => helper_sha}
      a.send(:invocation_pin!, 'helper seed', helper, helper_sha)
      a.send(:reject!) { a.send(:invocation_pin!, 'helper seed', helper, FULL_BINARY_SHA256) }
      checks << 'independent-full-runtime-and-invocation-metadata-mutants-helper-pin-remains-specific'

      projection = a.send(:variant_sql, 'v')
      raise Error, 'Variant SQL branch projection seed is malformed' unless
        projection.include?("variantType(v) = 'Array(UInt8)'") &&
        projection.include?("variantType(v) = 'String'") &&
        projection.include?("variantType(v) = 'UInt64'") &&
        projection.include?("variantElement(v, 'UInt64')") && !projection.include?("\n")
      checks << 'native-Variant-projection-construction-positive'

      failed = {'exit' => 1, 'signal' => nil, 'timed_out' => false, 'spawn_error' => nil,
        'stdin_write_error' => nil, 'stdout_read_error' => nil, 'stderr_read_error' => nil,
        'process_classification' => 'server_exception'}
      a.send(:reject!) { a.send(:validate_outcome!, 'stock_bulk_basic_mrk3_s0_create', failed, ''.b, ''.b) }
      checks << 'failed-raw-stage-blocks-forged-summary'
      puts "W283 capture auditor Ruby-only self-test passed: cases=#{checks.size}; #{checks.join(',')}; no capture reads or subprocesses"
      true
    rescue StandardError => error
      warn "W283 capture auditor self-test failed: #{error.class}: #{error.message}"
      false
    end

    private

    def summary_status!(summary, mode)
      expected = mode == :stock_only ? STOCK_STATUS : FULL_STATUS
      need!(summary.is_a?(Hash) && summary['format'] == FORMAT && summary['status'] == expected,
        "requires exact #{mode} W283 status #{expected}; captured RED/infrastructure is not compatibility")
    end

    def expected_ids
      M::MODES.flat_map do |mode|
        M::MARK_FORMATS.flat_map { |mark| M::PROFILES.map { |profile| "#{M::CASE}_#{mode}_#{mark}_#{profile}" } }
      end
    end

    def expected_labels(mode)
      ids = expected_ids
      labels = ids.flat_map do |id|
        %w[create insert schema_part native_check].map { |stage| "#{id}_#{stage}" } +
          %w[full middle last eof].map { |window| "#{id}_values_#{window}" }
      end
      return labels if mode == :stock_only
      labels.concat(ids.map { |id| "#{id}_helper_stock" })
      ids.each do |id|
        labels.concat(["#{id}_helper_write", "#{id}_target_create", "#{id}_attach",
          "#{id}_attached_check", "#{id}_attached_schema_part"] +
          %w[full middle last eof].map { |window| "#{id}_attached_values_#{window}" })
      end
      labels
    end

    def literal_signatures
      ORACLE_SIGNATURES
    end

    def summary_contract!
      summary_status!(@summary, @mode)
      need!(PATHS.validate_evidence_root(@root, purpose: :audit) == @root,
        'evidence root must be the canonical direct child of an owned W283 SSD task root')
      need!(@summary['evidence_root'] == @root, 'summary evidence root differs from audit root')
      need!(@summary.fetch('execution_scope') == EXECUTION_SCOPE, 'W283 execution scope differs')
      ids = expected_ids
      entries = @summary.fetch('cases')
      need!(entries.is_a?(Hash) && entries.keys.sort == ids.sort, 'expected exactly eight BASIC/COMPACT × MRK3/MRK4 × S0/S1 cells')
      tokens = ids.map do |id|
        match = /\Aw283m_([a-zA-Z0-9]+)_#{Regexp.escape(id)}\z/.match(entries.fetch(id).fetch('table'))
        need!(match, "#{id} table name is not rooted in the W283 token namespace")
        match[1]
      end
      need!(tokens.uniq.size == 1, 'W283 stock tables do not share one capture token')
      @table_token = tokens.first
      fixture = @summary.fetch('fixture')
      need!(fixture.fetch('schema') == SCHEMA && fixture.fetch('literal_signatures') == ORACLE_SIGNATURES &&
        fixture.fetch('row_count') == 8 && fixture.fetch('rows_per_mark') == 2 && fixture.fetch('data_marks') == 4 &&
        fixture.fetch('raw_mark_file_rows') == MARK_ROWS && fixture.fetch('public_reader_mark_rows') == PUBLIC_ROWS &&
        fixture.fetch('native_windows') == WINDOWS && fixture.fetch('physical_windows') == PHYSICAL_WINDOWS &&
        fixture.fetch('oracle_input') == 'independent Ruby literal ROWS encoded as RowBinary; expected signatures never derive from Crystal output' &&
        fixture.fetch('variant_alternatives') == {'0' => 'Array(UInt8)', '1' => 'String', '2' => 'UInt64', '255' => 'NULL'} &&
        fixture.fetch('coverage') == ['zero-Q', 'positive-Q all-NULL', 'empty selected Array distinct from NULL',
          'all non-NULL alternatives', 'late binary String and large UInt64'],
        'W283 literal schema/schedule/windows/coverage differ from independent oracle')
      need!(TYPE == M::TYPE && SCHEMA == M::SCHEMAS.fetch(M::CASE), 'W283 production probe declaration differs from auditor literal type')
      parameters = @summary.fetch('schema_parameters')
      need!(parameters == {
        'object_serialization_version' => 'v3', 'object_shared_data_serialization_version' => 'map',
        'map_layout_value' => 0, 'object_shared_data_buckets_for_compact_part' => 1,
        'string_profiles' => {'s0' => 'single_stream', 's1' => 'with_size_stream'},
        'mark_compression' => 'plain', 'variant_discriminator_modes' => {'basic' => 0, 'compact' => 1},
        'mark_formats' => M::MARK_FORMATS, 'allow_suspicious_low_cardinality_types' => 1,
      }, 'W283 schema/profile/Variant mode/LC settings summary differs')
      @expected_settings = {}
      ids.each do |id|
        entry = entries.fetch(id)
        mode, mark, profile = id.split('_').values_at(2, 3, 4)
        settings = expected_settings(mode, mark, profile)
        need!(entry.values_at('case_id', 'schema_kind', 'variant_discriminator_mode', 'mark_format', 'string_profile', 'status') ==
          [id, M::CASE, mode, mark, profile, 'exact_native_values'], "#{id} stock state or identity differs")
        schema_parameters = {
          'object_serialization_version' => 'v3', 'object_shared_data_serialization_version' => 'map',
          'map_layout_value' => 0, 'object_shared_data_buckets_for_compact_part' => 1,
          'string_serialization_version' => profile == 's1' ? 'with_size_stream' : 'single_stream',
          'mark_compression' => 'plain', 'variant_discriminator_mode' => mode,
        }
        need!(entry['store'] == File.join(@root, 'stores', id) && entry['schema_parameters'] == schema_parameters,
          "#{id} native store or schema parameters differ")
        exact = {
          'profile' => profile, 'clickhouse_settings' => settings,
          'object_serialization_version' => 'v3', 'object_shared_data_serialization_version' => 'map',
          'map_layout_value' => 0, 'object_shared_data_buckets_for_compact_part' => 1,
          'variant_discriminator_mode' => mode, 'allow_suspicious_low_cardinality_types' => 1,
          'mark_format' => mark, 'mark_compression' => 'plain',
        }
        need!(entry['settings_exact'] == exact, "#{id} effective settings record differs")
        @expected_settings[id] = settings
      end
      helper_pin = @summary['helper_pin']
      need!(@mode == :stock_only ? helper_pin.nil? : helper_pin.is_a?(Hash), 'W283 helper pin presence differs from audit mode')
      need!(@summary.fetch('claim_boundary') == CLAIM_BOUNDARY, 'W283 claim boundary differs or was widened')
      need!(!@summary.fetch('claim_boundary').match?(/Variant decoder|discriminator bytes decoded|semantic discriminator order proven/i),
        'W283 claim exceeds raw-window evidence')
      true
    rescue KeyError, TypeError => error
      raise Error, "W283 summary is incomplete: #{error.message}"
    end

    def expected_settings(mode, mark, profile)
      need!(M::MODE_VALUES.key?(mode) && M::MARK_FORMATS.include?(mark) && M::PROFILES.include?(profile), 'unknown W283 matrix coordinate')
      string = profile == 's1' ? 'with_size_stream' : 'single_stream'
      substream = mark == 'mrk4' ? 1 : 0
      [
        'index_granularity=2', 'index_granularity_bytes=10485760', 'enable_mixed_granularity_parts=1',
        'min_rows_for_wide_part=1000000', 'min_bytes_for_wide_part=104857600', 'min_level_for_wide_part=0',
        'compress_marks=0', "marks_compression_codec='LZ4'", 'compress_primary_key=0', 'write_final_mark=1',
        "write_marks_for_substreams_in_compact_parts=#{substream}", 'min_compress_block_size=0',
        'max_compress_block_size=4096', 'ratio_of_defaults_for_sparse_serialization=1.0',
        "default_compression_codec='LZ4'", "serialization_info_version='with_types'",
        'propagate_types_serialization_versions_to_nested_types=true', "string_serialization_version='#{string}'",
        "object_serialization_version='v3'", "object_shared_data_serialization_version='map'",
        "object_shared_data_serialization_version_for_zero_level_parts='map'", 'object_shared_data_buckets_for_compact_part=1',
        'object_shared_data_target_chunk_rows=1', "dynamic_serialization_version='v3'",
        "use_compact_variant_discriminators_serialization=#{M::MODE_VALUES.fetch(mode)}",
        'allow_suspicious_low_cardinality_types=1',
      ].join(', ')
    end

    def pins!
      runtime = @summary.fetch('runtime_pin')
      binary_path = PATHS.validate_task_file(runtime.fetch('binary'))
      @binary_path = binary_path
      runtime_metadata!(runtime, binary_path)
      binary = file!(binary_path, 'pinned W283 runtime', 1024 * 1024 * 1024)
      need!(File.executable?(binary) && File.size(binary) == FULL_BINARY_BYTES &&
        file_sha(binary, 'pinned W283 runtime', 1024 * 1024 * 1024) == FULL_BINARY_SHA256,
        'W283 native runtime bytes differ from fixed pin')
      source = @summary.fetch('source_pin')
      source_root = PATHS.validate_source_root(source.fetch('root'))
      need!(source.values_at('root', 'revision_expected', 'revision_before', 'revision_after') ==
        [source_root, W::SOURCE_REVISION, W::SOURCE_REVISION, W::SOURCE_REVISION], 'W283 source revision metadata differs')
      out, err, status = Open3.capture3('git', '-C', source_root, 'rev-parse', 'HEAD')
      need!(status.success? && err.empty? && out.strip == W::SOURCE_REVISION, 'pinned ClickHouse source checkout revision differs')
      source_actual = W::SOURCE_FILES.to_h { |rel| [rel, file_sha(File.join(source_root, rel), "pinned source #{rel}")] }
      need!(source.fetch('source_sha256_before') == source.fetch('source_sha256_after') &&
        source.fetch('source_sha256_before') == source_actual, 'pinned ClickHouse source file byte seals differ')
      local_paths = [W::PROBE_SOURCE, M::W282M::W281M::PROBE_SOURCE, M::W282M::W281M::HELPER_SOURCE,
        M::W282M::W281M::FIXTURE_SOURCE, M::W282M::PROBE_SOURCE,
        M::W282M::FIXTURE_SOURCE, W283_PROBE_SOURCE, W283_FIXTURE_SOURCE, M::PATHS_SOURCE,
        File.expand_path('verify_compact_variant_bulk_w283_runtime_pin.rb', __dir__)]
      if @mode == :full_matrix
        local_paths.concat([M::W282M::HELPER_SOURCE, M::HELPER_SOURCE])
      end
      local_source_pins!(local_paths)
      helper = @summary['helper_pin']
      if @mode == :full_matrix
        need!(helper.values_at('source', 'sha256_before', 'sha256_after') ==
          [M::HELPER_SOURCE, helper['expected_sha256'], helper['expected_sha256']] &&
          helper['expected_sha256'].to_s.match?(/\A[0-9a-f]{64}\z/), 'W283 helper source/hash identity differs')
        helper_path = PATHS.validate_task_file(helper.fetch('path'))
        helper_path = file!(helper_path, 'prebuilt W283 helper', 1024 * 1024 * 1024)
        need!(File.executable?(helper_path) && file_sha(helper_path, 'prebuilt W283 helper', 1024 * 1024 * 1024) == helper['expected_sha256'],
          'prebuilt W283 helper bytes differ from captured pin')
      end
      true
    rescue KeyError, TypeError => error
      raise Error, "W283 pin evidence incomplete: #{error.message}"
    end

    def runtime_metadata!(runtime, binary_path)
      need!(runtime.values_at('binary', 'expected_sha256', 'sha256_before', 'sha256_after',
        'expected_bytes', 'bytes_before', 'bytes_after', 'version', 'build') ==
        [binary_path, FULL_BINARY_SHA256, FULL_BINARY_SHA256, FULL_BINARY_SHA256,
          FULL_BINARY_BYTES, FULL_BINARY_BYTES, FULL_BINARY_BYTES, FULL_VERSION, FULL_BUILD],
        'W283 full native runtime metadata differs from independent literal pin')
      true
    end

    def local_source_pins!(paths)
      local_paths = paths.map { |path| File.realpath(path) }.uniq.sort
      local = @summary.fetch('matrix_source_pins')
      local_actual = local_paths.to_h { |path| [path, file_sha(path, "local W283 source #{File.basename(path)}")] }
      need!(local.fetch('sha256_before') == local.fetch('sha256_after') && local.fetch('sha256_before') == local_actual,
        'W280/W281/W282/W283 matrix, helper, or fixture source seals differ')
      true
    end

    def expected_invocation_sha256(kind)
      kind == 'crystal-helper' ? @summary.dig('helper_pin', 'expected_sha256') : FULL_BINARY_SHA256
    end

    def invocation_pin!(label, record, expected_sha)
      need!(record.values_at('expected_binary_sha256', 'binary_sha_before', 'binary_sha_after') ==
        [expected_sha, expected_sha, expected_sha], "#{label} raw runtime SHA identity differs")
      true
    end

    # W::BINARY_SHA256 resolves lexically to W280's historic stripped pin. Keep
    # this narrow override so W283 native records use its independent full pin.
    def invocations!
      @records = {}
      sidecars = []
      @summary.fetch('invocation_roster').each do |roster_entry|
        label = roster_entry.fetch('label')
        kind, binary, store, argv, extension, stdin = expected_spec(label)
        record_path = File.join(@root, 'invocations', "#{label}.json")
        record_bytes = File.binread(file!(record_path, "#{label} raw invocation record"))
        record = JSON.parse(record_bytes)
        rowbinary = kind == 'clickhouse-local' && label.end_with?('_insert')
        keys = rowbinary ? (REC_KEYS + ['stdin_encoding']).sort : REC_KEYS
        need!(record.is_a?(Hash) && record.keys.sort == keys && record_bytes == JSON.pretty_generate(record) + "\n",
          "#{label} raw record schema/canonical JSON differs")
        expected_sha = expected_invocation_sha256(kind)
        invocation_pin!(label, record, expected_sha)
        need!(record.values_at('label', 'process_kind', 'binary_path', 'store_path', 'argv',
          'stdin_file', 'argv_file', 'stdout_file', 'stderr_file', 'expected_binary_sha256',
          'binary_sha_before', 'binary_sha_after') == [label, kind, binary, store, argv,
            "#{label}.stdin.#{extension}", "#{label}.argv.json", "#{label}.stdout", "#{label}.stderr",
            expected_sha, expected_sha, expected_sha], "#{label} raw record identity/argv differs")
        need!(!rowbinary || record['stdin_encoding'] == 'rowbinary', "#{label} RowBinary encoding label differs")

        invocation_dir = File.join(@root, 'invocations')
        argv_bytes = JSON.pretty_generate(argv) + "\n"
        sidecars.concat(["#{label}.json", record['argv_file'], record['stdin_file'], record['stdout_file'], record['stderr_file']])
        actual_argv = read_at(invocation_dir, record['argv_file'])
        actual_stdin = read_at(invocation_dir, record['stdin_file'])
        stdout = read_at(invocation_dir, record['stdout_file'])
        stderr = read_at(invocation_dir, record['stderr_file'])
        need!(actual_argv == argv_bytes && record['argv_sha256'] == sha(argv_bytes), "#{label} argv sidecar/hash differs")
        need!(actual_stdin == stdin && record['stdin_bytes'] == actual_stdin.bytesize &&
          record['stdin_sha256'] == sha(actual_stdin), "#{label} stdin bytes/record hash differs from reconstruction")
        need!(record['stdout_bytes'] == stdout.bytesize && record['stdout_sha256'] == sha(stdout) &&
          record['stderr_bytes'] == stderr.bytesize && record['stderr_sha256'] == sha(stderr),
          "#{label} raw stdout/stderr bytes or hashes differ from record")
        validate_outcome!(label, record, stdout, stderr)
        resources!(label, record, kind)
        @records[label] = record
        roster_match!(roster_entry, record)
      end
      need!(Dir.children(File.join(@root, 'invocations')).sort == sidecars.sort,
        'invocations directory has missing or unexpected raw files')
      need!(@stage_refs.keys.sort == @records.keys.sort, 'some raw invocation lacks an exact summary-stage reference')
      validate_stage_references!
    rescue KeyError, JSON::ParserError => e
      raise Error, "raw invocation evidence incomplete: #{e.message}"
    end

    def expected_spec(label)
      helper_pin = @summary.fetch('helper_pin')
      if label.end_with?('_helper_stock') || label.end_with?('_helper_write')
        action = label.end_with?('_helper_stock') ? 'read' : 'write'
        suffix = action == 'read' ? '_helper_stock' : '_helper_write'
        id = label.delete_suffix(suffix)
        entry = @summary.fetch('cases').fetch(id)
        part = action == 'read' ? entry.dig('schema_part', 'part', 'path') : File.join(@root, 'parts', id, W::PART_NAME)
        need!(part, "#{label} helper part path is absent")
        path = helper_pin.fetch('path')
        mode, mark, profile = id.split('_').values_at(2, 3, 4)
        return ['crystal-helper', path, nil, [path, action, mode, mark, profile, part], 'bin', ''.b]
      end
      id = expected_ids.find { |candidate| label == candidate || label.start_with?(candidate + '_') }
      need!(id, "unknown W283 invocation label #{label.inspect}")
      entry = @summary.fetch('cases').fetch(id)
      mode, mark, profile = id.split('_').values_at(2, 3, 4)
      target = "w283m_#{@table_token}_target_#{id}"
      attached = label.include?('_attached_') || label.end_with?('_attach') || label.end_with?('_target_create')
      store_id = attached ? "target_#{id}" : id
      table = attached ? target : entry.fetch('table')
      case label
      when "#{id}_create"
        native_spec(store_id, PIN_SQL + create_sql(entry.fetch('table'), mode, mark, profile), entry.fetch('table'))
      when "#{id}_insert"
        rowbinary_spec(id, entry, store_id)
      when "#{id}_schema_part"
        native_spec(store_id, PIN_SQL + schema_sql(id, entry.fetch('table')), entry.fetch('table'))
      when "#{id}_native_check"
        native_spec(store_id, PIN_SQL + check_sql("#{id}_native", entry.fetch('table')), entry.fetch('table'))
      when "#{id}_target_create"
        native_spec(store_id, PIN_SQL + create_sql(target, mode, mark, profile) + target_schema_sql(id, target), target)
      when "#{id}_attach"
        native_spec(store_id, PIN_SQL + "ALTER TABLE default.#{target} ATTACH PART '#{W::PART_NAME}';\n", target)
      when "#{id}_attached_check"
        native_spec(store_id, PIN_SQL + check_sql("#{id}_attached", target), target)
      when "#{id}_attached_schema_part"
        native_spec(store_id, PIN_SQL + schema_sql("#{id}_attached", target), target)
      else
        match = /\A#{Regexp.escape(id)}(?:_attached)?_values_(full|middle|last|eof)\z/.match(label)
        need!(match, "unclassified W283 invocation #{label}")
        query_id = label.include?('_attached_values_') ? "#{id}_attached" : id
        native_spec(store_id, PIN_SQL + values_sql(query_id, table, match[1]), table)
      end
    rescue KeyError => error
      raise Error, "cannot reconstruct W283 invocation #{label}: #{error.message}"
    end

    def native_spec(store_id, sql, _table)
      store = File.join(@root, 'stores', store_id)
      argv = [@binary_path, 'local', '--path', store, '--session_timezone=UTC', '--max_threads=1',
        "--max_memory_usage=#{W::MEMORY_LIMIT}", '--multiquery']
      ['clickhouse-local', @binary_path, store, argv, 'sql', sql.b]
    end

    def rowbinary_spec(id, entry, store_id)
      rows = rowbinary_rows
      literal = entry.fetch('literal_input')
      need!(literal['schema_kind'] == M::CASE && literal['row_count'] == 8 &&
        literal['query'] == "INSERT INTO default.#{entry.fetch('table')} FORMAT RowBinary" &&
        literal['rows'].is_a?(Array) && literal['rows'].size == 8, "#{id} literal RowBinary record differs")
      literal['rows'].each_with_index do |row, index|
        need!(row == {'pk' => index + 1, 'values' => ORACLE_SIGNATURES.fetch(index),
          'rowbinary_hex' => rows.fetch(index).unpack1('H*')}, "#{id} independent RowBinary row #{index + 1} differs")
      end
      bytes = rows.join.b
      need!(literal.values_at('stdin_file', 'stdin_bytes', 'stdin_sha256') ==
        ["#{id}_insert.stdin.bin", bytes.bytesize, sha(bytes)], "#{id} RowBinary input byte seal differs")
      store = File.join(@root, 'stores', store_id)
      query = "INSERT INTO default.#{entry.fetch('table')} FORMAT RowBinary"
      argv = [@binary_path, 'local', '--path', store, '--session_timezone=UTC', '--max_threads=1',
        "--max_memory_usage=#{W::MEMORY_LIMIT}", '--input_format_binary_read_json_as_string=0', '--query', query]
      ['clickhouse-local', @binary_path, store, argv, 'bin', bytes]
    end

    def rowbinary_rows
      ORACLE_ROWS.map do |row|
        left_json = rowbinary_json(row.fetch(:left))
        right_json = rowbinary_json(row.fetch(:right))
        array = rowbinary_array(row.fetch(:array).map { |variant, label| rowbinary_variant(variant) + rowbinary_string(label) })
        tuple = rowbinary_string(row.fetch(:root_lc)) + rowbinary_variant(row.fetch(:root_variant))
        tuple << rowbinary_array(row.fetch(:map).map { |key, variant| rowbinary_string(key) + rowbinary_variant(variant) })
        tuple << rowbinary_array(row.fetch(:nested).map { |variant, label| rowbinary_variant(variant) + rowbinary_string(label) })
        [row.fetch(:left)].pack('Q<').b + left_json + array + right_json + tuple
      end
    end

    def rowbinary_varuint(value)
      need!(value.is_a?(Integer) && value >= 0, 'RowBinary VarUInt must be nonnegative')
      bytes = []
      loop do
        byte = value & 0x7f
        value >>= 7
        bytes << (value.zero? ? byte : byte | 0x80)
        break if value.zero?
      end
      bytes.pack('C*').b
    end
    def rowbinary_string(bytes); value = bytes.to_s.b; rowbinary_varuint(value.bytesize) + value; end
    def rowbinary_array(values); rowbinary_varuint(values.size) + values.join.b; end
    def rowbinary_json(id); rowbinary_varuint(1) + rowbinary_string('id') + [id].pack('Q<').b; end
    def rowbinary_variant(value)
      arm, payload = value
      case arm
      when :null then "\xff".b
      when :array then "\x00".b + rowbinary_array(payload.map { |byte| [byte].pack('C').b })
      when :string then "\x01".b + rowbinary_string(payload)
      when :uint64 then "\x02".b + [Integer(payload)].pack('Q<').b
      else raise Error, "unknown independent Variant literal #{arm.inspect}"
      end
    end

    def tag(kind, id, window = nil)
      "__W280M_#{kind.upcase}_#{id.upcase}#{window ? "_#{window.upcase}" : ''}__"
    end
    def schema_sql(id, table)
      "SELECT '#{tag('schema', id)}', name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw;\n" \
        "SELECT '#{tag('part', id)}', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw;\n" \
        "SELECT '#{tag('table_path', id)}', arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw;\n"
    end
    def target_schema_sql(id, table)
      "SELECT '#{tag('target_schema', id)}', name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw;\n" \
        "SELECT '#{tag('target_path', id)}', arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw;\n"
    end
    def check_sql(id, table)
      "SELECT '#{tag('check_begin', id)}' FORMAT TSVRaw;\nCHECK TABLE default.#{table} FORMAT TSV;\nSELECT '#{tag('check_end', id)}' FORMAT TSVRaw;\n"
    end
    def create_sql(table, mode, mark, profile)
      declarations = SCHEMA.map { |name, type| "`#{name}` #{type}" }.join(', ')
      "SET flatten_nested=0;\nSET allow_suspicious_low_cardinality_types=1;\nSET use_variant_as_common_type=1;\n" \
        "CREATE TABLE default.#{table} (#{declarations}) ENGINE=MergeTree ORDER BY pk SETTINGS #{expected_settings(mode, mark, profile)};\n"
    end
    def variant_sql(expression)
      array_arm = "concat('A[', arrayStringConcat(arrayMap(w283_byte -> lower(hex(reinterpretAsFixedString(w283_byte))), variantElement(#{expression}, 'Array(UInt8)')), ','), ']')"
      string_arm = "concat('S', lower(hex(variantElement(#{expression}, 'String'))))"
      uint_arm = "concat('U', toString(variantElement(#{expression}, 'UInt64')))"
      "multiIf(variantType(#{expression}) = 'Array(UInt8)', #{array_arm}, " \
        "variantType(#{expression}) = 'String', #{string_arm}, " \
        "variantType(#{expression}) = 'UInt64', #{uint_arm}, 'N')"
    end
    def native_projection_sql
      root = "`#{COLUMN}`"
      left = "tupleElement(#{root}, 1).id"; array = "tupleElement(#{root}, 2)"
      right = "tupleElement(#{root}, 3).id"; bulk = "tupleElement(#{root}, 4)"
      root_lc = "tupleElement(#{bulk}, 1)"; root_variant = "tupleElement(#{bulk}, 2)"
      map = "tupleElement(#{bulk}, 3)"; nested = "tupleElement(#{bulk}, 4)"
      "concat(toString(#{left}), '|A[', " \
        "arrayStringConcat(arrayMap(w283_a -> concat(#{variant_sql('tupleElement(w283_a, 1)')}, '/', lower(hex(tupleElement(w283_a, 2)))), #{array}), ';'), ']|', " \
        "toString(#{right}), '|B(', lower(hex(#{root_lc})), '|', #{variant_sql(root_variant)}, '|M[', " \
        "arrayStringConcat(arrayMap((w283_key, w283_value) -> concat(lower(hex(w283_key)), '=', #{variant_sql('w283_value')}), mapKeys(#{map}), mapValues(#{map})), ';'), ']|N[', " \
        "arrayStringConcat(arrayMap(w283_nested -> concat(#{variant_sql('tupleElement(w283_nested, 1)')}, '/', lower(hex(tupleElement(w283_nested, 2)))), #{nested}), ';'), '])')"
    end
    def values_sql(id, table, window)
      predicate = WINDOWS.fetch(window)
      return "SELECT '#{tag('values', id, window)}', toString(count()) FROM default.#{table} WHERE #{predicate} FORMAT TSVRaw;\n" if window == 'eof'
      where = predicate ? " WHERE #{predicate}" : ''
      "SELECT '#{tag('values', id, window)}', toString(pk), #{native_projection_sql} FROM default.#{table}#{where} " \
        "ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw;\n"
    end

    def cases!
      expected_ids.each do |id|
        entry = @summary.fetch('cases').fetch(id)
        mode, mark, profile = id.split('_').values_at(2, 3, 4)
        expected_params = {'object_serialization_version' => 'v3', 'object_shared_data_serialization_version' => 'map',
          'map_layout_value' => 0, 'object_shared_data_buckets_for_compact_part' => 1,
          'string_serialization_version' => profile == 's1' ? 'with_size_stream' : 'single_stream',
          'mark_compression' => 'plain', 'variant_discriminator_mode' => mode}
        need!(entry.values_at('case_id', 'schema_kind', 'variant_discriminator_mode', 'mark_format', 'string_profile', 'status') ==
          [id, M::CASE, mode, mark, profile, 'exact_native_values'] && entry['schema_parameters'] == expected_params,
          "#{id} native stock cell identity/status/settings differ")
        need!(entry['store'] == File.join(@root, 'stores', id), "#{id} stock store path differs")
        stage!("#{id}_create", entry.fetch('create')); stage!("#{id}_insert", entry.fetch('insert'))
        stage!("#{id}_schema_part", entry.dig('schema_part', 'invocation'))
        stage!("#{id}_native_check", entry.dig('check', 'invocation'))
        sql_stdout!("#{id}_create", [PIN_LINE]); sql_stdout!("#{id}_insert", [])
        native_schema!(id, entry.fetch('schema_part'), entry.fetch('table'))
        check_stdout!("#{id}_native", entry.fetch('check'))
        validate_windows!(id, entry.fetch('table'), entry.fetch('windows'), false)
        raw = entry.dig('schema_part', 'part', 'raw_capture')
        validate_part!(id, mark, entry.dig('schema_part', 'part', 'path'), raw.fetch('inventory'),
          raw.fetch('snapshot'), raw.fetch('callback_roster'), raw.fetch('serialization_metadata'),
          raw.fetch('serialization_metadata_sha256'), raw.fetch('serialization_metadata_raw_file'),
          raw.fetch('mark_file'), raw.fetch('mark_bytes'), raw.fetch('mark_sha256'), :stock)
        validate_full_case!(id, entry, mode, mark, profile) if @mode == :full_matrix
      end
      true
    rescue KeyError, TypeError, NoMethodError => error
      raise Error, "W283 cell evidence incomplete: #{error.class}: #{error.message}"
    end

    def validate_full_case!(id, entry, mode, mark, profile)
      stock_read = entry.fetch('library_stock_read')
      need!(stock_read['status'] == 'exact_public_recursive_reads', "#{id} public stock read is not exact")
      helper_report!(id, mode, mark, profile, stock_read.fetch('report'), 'read', entry.dig('schema_part', 'part', 'path'))
      helper_stdout!("#{id}_helper_stock", stock_read.fetch('report')); stage!("#{id}_helper_stock", stock_read.fetch('invocation'))
      generated = entry.fetch('library_generated')
      need!(generated['status'] == 'exact_generated_native_interop', "#{id} generated status is not exact")
      wrapper = generated.fetch('helper_report')
      need!(wrapper['status'] == 'exact_public_recursive_reads', "#{id} generated writer reader report is not exact")
      helper_report!(id, mode, mark, profile, wrapper.fetch('report'), 'write', File.join(@root, 'parts', id, W::PART_NAME))
      helper_stdout!("#{id}_helper_write", wrapper.fetch('report')); stage!("#{id}_helper_write", generated.fetch('helper_invocation'))
      target = generated.fetch('native_target')
      target_table = "w283m_#{@table_token}_target_#{id}"
      need!(target.values_at('state', 'table', 'store') == ['ready', target_table, File.join(@root, 'stores', "target_#{id}")],
        "#{id} native target identity differs")
      stage!("#{id}_target_create", target.fetch('create')); target_create_stdout!(id, target)
      stage!("#{id}_attach", generated.dig('attach', 'invocation')); sql_stdout!("#{id}_attach", [PIN_LINE])
      stage!("#{id}_attached_check", generated.dig('check', 'invocation'))
      check_stdout!("#{id}_attached", generated.fetch('check'))
      active = generated.dig('active_part', 'part')
      need!(active.is_a?(Hash), "#{id} attached active part absent")
      stage!("#{id}_attached_schema_part", generated.dig('active_part', 'invocation'))
      native_schema!("#{id}_attached", generated.fetch('active_part'), target_table)
      validate_windows!(id, target_table, generated.fetch('native_windows'), true)
      generated_path = File.join(@root, 'parts', id, W::PART_NAME)
      need!(generated['part_path'] == generated_path, "#{id} generated part path differs")
      metadata = generated.fetch('serialization_metadata')
      validate_part!("#{id}_generated", mark, generated_path, generated.fetch('inventory'), generated.fetch('part_snapshot'),
        generated.fetch('callback_roster'), metadata.fetch('parsed'), metadata.fetch('raw_sha256'),
        "raw-records/#{id}_generated.serialization.json", "data.#{mark}", nil, nil, :generated)
      raw = active.fetch('raw_capture')
      validate_part!("#{id}_attached", mark, active.fetch('path'), raw.fetch('inventory'), raw.fetch('snapshot'),
        raw.fetch('callback_roster'), raw.fetch('serialization_metadata'), raw.fetch('serialization_metadata_sha256'),
        raw.fetch('serialization_metadata_raw_file'), raw.fetch('mark_file'), raw.fetch('mark_bytes'), raw.fetch('mark_sha256'), :attached)
      sidecar = File.binread(file!(File.join(active.fetch('path'), SIDECAR_PATH), "#{id} ATTACH sidecar"))
      attached_contract!(generated.fetch('inventory'), raw.fetch('inventory'), sidecar)
      need!(generated.dig('attach', 'source_inventory') == generated['inventory'] &&
        generated.dig('attach', 'detached_inventory') == generated['inventory'] &&
        generated.dig('attached_inventory_contract', 'state') == 'generated_files_byte_preserved_with_exact_native_sidecar',
        "#{id} ATTACH inventory summary claim differs")
      true
    end

    def native_schema!(id, physical, table)
      normalized = SCHEMA.map { |name, type| [name, type.gsub(/\s+/, '')] }
      need!(physical['state'] == 'observed' && physical['schema'] == normalized && physical['expected_schema'] == normalized,
        "#{id} physical schema differs")
      part = physical.fetch('part'); path = part.fetch('path'); table_path = physical.fetch('table_data_path')
      directory!(path, "#{id} active part"); directory!(table_path.delete_suffix(File::SEPARATOR), "#{id} table path")
      expected = [tag('part', id), table, W::PART_NAME, path + File::SEPARATOR, 'Compact', '8', '5']
      need!(File.dirname(path) == table_path.delete_suffix(File::SEPARATOR) && File.basename(path) == W::PART_NAME &&
        physical['active_parts'] == [expected] && part['row'] == expected, "#{id} active part path/row differs")
      # The stage name is distinct from the schema query id for an attached part.
      stage_label = id.end_with?('_attached') ? "#{id.delete_suffix('_attached')}_attached_schema_part" : "#{id}_schema_part"
      lines = stdout_lines(stage_label)
      got = lines.drop(1).take(normalized.size).map { |line| line.split("\t", -1) }
      schema_tag = tag('schema', id); table_path_tag = tag('table_path', id)
      need!(got.size == normalized.size && got.each_with_index.all? do |row, index|
        row.size == 3 && row[0] == schema_tag && row[1] == normalized[index][0] && row[2].gsub(/\s+/, '') == normalized[index][1]
      end, "#{id} native schema stdout differs")
      tail = [expected.join("\t"), [table_path_tag, table_path].join("\t")]
      need!(lines.size == normalized.size + 3 && lines.drop(normalized.size + 1) == tail, "#{id} part/path stdout differs")
      true
    end

    def target_create_stdout!(id, target)
      table = target.fetch('table'); path = target.fetch('data_path')
      lines = stdout_lines("#{id}_target_create")
      normalized = SCHEMA.map { |name, type| [name, type.gsub(/\s+/, '')] }
      target_tag = tag('target_schema', id)
      rows = lines.drop(1).take(normalized.size).map { |line| line.split("\t", -1) }
      need!(rows.size == normalized.size && rows.each_with_index.all? do |row, index|
        row.size == 3 && row[0] == target_tag && row[1] == normalized[index][0] && row[2].gsub(/\s+/, '') == normalized[index][1]
      end, "#{id} target schema stdout differs")
      reported = path.end_with?(File::SEPARATOR) ? path : "#{path}#{File::SEPARATOR}"
      need!(lines.drop(1 + normalized.size) == [[tag('target_path', id), reported].join("\t")] &&
        table == "w283m_#{@table_token}_target_#{id}", "#{id} target path/table stdout differs")
      directory!(path, "#{id} target data path")
      true
    end

    def check_stdout!(query_id, check)
      need!(check['state'] == 'healthy', "#{query_id} CHECK is not healthy")
      begin_tag = tag('check_begin', query_id); end_tag = tag('check_end', query_id)
      row = "#{W::PART_NAME}\t1\t"
      label = query_id.end_with?('_attached') ? "#{query_id.delete_suffix('_attached')}_attached_check" : "#{query_id.delete_suffix('_native')}_native_check"
      need!(check['rows'] == [row] && stdout_lines(label) == [PIN_LINE, begin_tag, row, end_tag], "#{query_id} CHECK stdout differs")
      true
    end

    def window_rows(window, query_id)
      tag_value = tag('values', query_id, window)
      return [[tag_value, '0']] if window == 'eof'
      indexes = {'full' => (0...8).to_a, 'middle' => (2...6).to_a, 'last' => (6...8).to_a}.fetch(window)
      indexes.map { |index| [tag_value, (index + 1).to_s, ORACLE_SIGNATURES.fetch(index)] }
    end

    def validate_window_rows!(id, window, rows)
      expected = window_rows(window, id)
      need!(rows == expected, "#{id}/#{window} raw window differs from independent literal oracle")
      true
    end

    def validate_windows!(id, table, windows, attached)
      query_id = attached ? "#{id}_attached" : id
      need!(windows.is_a?(Hash) && windows.keys.sort == WINDOWS.keys.sort, "#{query_id} native window roster differs")
      WINDOWS.each_key do |window|
        entry = windows.fetch(window); label = "#{query_id}_values_#{window}"
        expected = window_rows(window, query_id)
        actual = window == 'eof' ? expected : expected.map { |row| {'pk' => Integer(row[1], 10), 'signature' => row[2]} }
        need!(entry['state'] == 'exact_values' && entry['rows'] == actual && entry['expected_rows'] == actual &&
          (window == 'eof' || entry['raw_rows'] == expected), "#{label} summary differs from independent oracle")
        stdout = ([PIN_LINE] + expected.map { |row| row.join("\t") }).join("\n") + "\n"
        need!(read_at(File.join(@root, 'invocations'), "#{label}.stdout") == stdout.b, "#{label} raw stdout differs")
        sql = PIN_SQL + values_sql(query_id, table, window).b
        record = @records.fetch(label)
        need!(read_at(File.join(@root, 'invocations'), record.fetch('stdin_file')) == sql, "#{label} raw SQL differs")
      end
      true
    rescue KeyError, ArgumentError => error
      raise Error, "#{query_id} window evidence incomplete: #{error.message}"
    end

    def helper_report!(id, mode, mark, profile, report, action, part)
      keys = %w[action data_mark_count format mark_format part_origin part_path public_reader_grid
        public_reader_mark_count public_reader_mark_rows reader_ordinary_profile
        reader_ordinary_profile_matches_requested recursive_windows row_count schema status
        string_profile variant_discriminator_mode].sort
      need!(report.is_a?(Hash) && report.keys.sort == keys, "#{id} helper report field set differs")
      origin = action == 'read' ? 'stock' : 'generated'
      need!(report.values_at('format', 'action', 'variant_discriminator_mode', 'mark_format', 'string_profile',
        'reader_ordinary_profile', 'reader_ordinary_profile_matches_requested', 'status', 'row_count', 'data_mark_count',
        'part_origin', 'public_reader_grid', 'public_reader_mark_count', 'public_reader_mark_rows', 'part_path') ==
        [M::HELPER_FORMAT, action, mode, mark, profile, profile, true, 'ok', 8, 4, origin,
          'nonempty_data_marks', 4, PUBLIC_ROWS, part] && report['schema'].gsub(/\s+/, '') == TYPE.gsub(/\s+/, ''),
        "#{id} helper report or observed String profile differs")
      windows = {'full' => ORACLE_SIGNATURES, 'middle' => ORACLE_SIGNATURES.drop(2).take(4),
        'last' => ORACLE_SIGNATURES.drop(6).take(2), 'eof' => []}
      recursive = report.fetch('recursive_windows')
      need!(recursive.keys.sort == windows.keys.sort, "#{id} helper recursive window roster differs")
      windows.each do |name, signatures|
        first, count = PHYSICAL_WINDOWS.fetch(name)
        need!(recursive.fetch(name) == {'signatures' => signatures, 'first_mark' => first, 'mark_count' => count},
          "#{id}/#{name} helper values or physical window differs")
      end
      true
    rescue KeyError, TypeError, NoMethodError => error
      raise Error, "#{id} helper report incomplete: #{error.message}"
    end

    def helper_report_seed(mode, mark, profile, action, part)
      report = super(mark, profile, action, part)
      report['format'] = M::HELPER_FORMAT
      report['schema'] = TYPE
      report['variant_discriminator_mode'] = mode
      report['reader_ordinary_profile_matches_requested'] = true
      report['reader_ordinary_profile'] = profile
      report
    end

    def helper_stdout!(label, report)
      bytes = read_at(File.join(@root, 'invocations'), "#{label}.stdout")
      parsed = JSON.parse(bytes)
      need!(bytes.lines.size == 1 && parsed == report, "#{label} raw helper stdout differs from report")
      true
    rescue JSON::ParserError => error
      raise Error, "#{label} helper stdout malformed: #{error.message}"
    end

    def expected_mrk4_sections(profile)
      streams = S0_STREAMS.dup
      if profile == 's1'
        S1_INSERTIONS.each do |before, inserted|
          index = streams.index(before)
          need!(index, "W283 S1 insertion anchor missing: #{before}")
          streams.insert(index, inserted)
        end
      else
        need!(profile == 's0', "unknown W283 String profile #{profile.inspect}")
      end
      [['pk', ['pk']], [COLUMN, streams]]
    end

    def mrk4_sections!(id, profile, sections)
      expected = expected_mrk4_sections(profile)
      need!(sections == expected, "#{id} MRK4 callback slot roster differs for #{profile}")
      expected
    end

    def prefix_roster!(streams)
      expected_lc = %w[
        recursive_variant_w283%2E2%2E2.dict_prefix
        recursive_variant_w283%2E4%2E1.dict_prefix
        recursive_variant_w283%2E4%2E4%2Elabel.dict_prefix
      ]
      expected_variant = %w[
        recursive_variant_w283%2E2%2E1.variant_discr_prefix
        recursive_variant_w283%2E4%2E2.variant_discr_prefix
        recursive_variant_w283%2E4%2E3%2Evalues.variant_discr_prefix
        recursive_variant_w283%2E4%2E4%2Echoice.variant_discr_prefix
      ]
      need!(streams.is_a?(Array) && streams.count { |name| name.end_with?('.dict_prefix') } == 3 &&
        streams.select { |name| name.end_with?('.dict_prefix') }.sort == expected_lc.sort &&
        streams.count { |name| name.end_with?('.variant_discr_prefix') } == 4 &&
        streams.select { |name| name.end_with?('.variant_discr_prefix') }.sort == expected_variant.sort,
        'W283 MRK4 prefix slot roster differs; Variant discriminator prefixes are syntactic, not decoded semantics')
      literal_occurrence_schedule!
      true
    end

    def literal_occurrence_schedule!
      schedule = ORACLE_ROWS.each_slice(2).map do |rows|
        array_count = rows.sum { |row| row.fetch(:array).size }
        root_count = rows.size
        map_count = rows.sum { |row| row.fetch(:map).size }
        nested_count = rows.sum { |row| row.fetch(:nested).size }
        {array_variant: array_count, array_label: array_count,
          root_variant: root_count, root_label: root_count,
          map_variant: map_count, nested_variant: nested_count, nested_label: nested_count}
      end
      expected = [
        {array_variant: 0, array_label: 0, root_variant: 2, root_label: 2, map_variant: 0, nested_variant: 0, nested_label: 0},
        {array_variant: 2, array_label: 2, root_variant: 2, root_label: 2, map_variant: 2, nested_variant: 2, nested_label: 2},
        {array_variant: 6, array_label: 6, root_variant: 2, root_label: 2, map_variant: 3, nested_variant: 3, nested_label: 3},
        {array_variant: 5, array_label: 5, root_variant: 2, root_label: 2, map_variant: 2, nested_variant: 2, nested_label: 2},
      ]
      need!(schedule == expected, 'independent per-mark Variant/LC occurrence schedule differs')
      all_null = ORACLE_ROWS.each_slice(2).to_a.fetch(1).all? do |row|
        row.fetch(:root_variant).first == :null &&
          row.fetch(:array).all? { |variant, _label| variant.first == :null } &&
          row.fetch(:map).all? { |_key, variant| variant.first == :null } &&
          row.fetch(:nested).all? { |variant, _label| variant.first == :null }
      end
      need!(all_null && schedule.fetch(0).values_at(:array_variant, :array_label, :map_variant,
        :nested_variant, :nested_label).all?(&:zero?),
        'independent literals lost zero-Q and positive-Q all-NULL discriminator lanes')
      schedule
    end

    def profile_for_case_id(id)
      base_id = if expected_ids.include?(id)
                  id
                else
                  suffix = %w[_generated _attached].find do |candidate_suffix|
                    expected_ids.any? { |candidate_id| id == "#{candidate_id}#{candidate_suffix}" }
                  end
                  suffix && id.delete_suffix(suffix)
                end
      need!(base_id && expected_ids.include?(base_id), "#{id} is not an exact W283 stock/generated/attached cell label")
      profile = base_id.split('_').last
      need!(M::PROFILES.include?(profile), "#{id} does not identify a W283 string profile")
      profile
    end

    def validate_part!(id, mark, path, inventory, snapshot, callback, parsed_metadata, metadata_sha,
                       metadata_file, mark_file, mark_bytes, mark_sha, origin)
      directory!(path, "#{id} part")
      expected_prefix = case origin
                        when :stock then File.join(@root, 'stores', id)
                        when :generated then File.join(@root, 'parts', id.delete_suffix('_generated'))
                        when :attached then File.join(@root, 'stores', "target_#{id.delete_suffix('_attached')}")
                        else raise Error, "unknown W283 part origin #{origin.inspect}"
                        end
      need!(path.start_with?(expected_prefix + File::SEPARATOR), "#{id} part escaped its source tree")
      inv = inventory!(inventory, id)
      need!(disk_inventory(path) == inv, "#{id} on-disk inventory differs")
      safe = id.gsub(/[^a-zA-Z0-9_.-]/, '_')
      snapshot_name = "source-inventories/#{safe}.json"
      need!(snapshot.is_a?(Hash) && snapshot['inventory'] == inv && snapshot['raw_prefix'] == "raw-records/#{safe}." &&
        snapshot['inventory_file'] == snapshot_name, "#{id} part snapshot references differ")
      persisted = JSON.parse(read_file(snapshot_name))
      need!(persisted['case_name'] == id && persisted['source_part_path'] == path && persisted['inventory'] == inv &&
        persisted['callback_roster'] == callback, "#{id} persisted source snapshot differs")
      @expected_snapshots << snapshot_name
      metadata_raw = File.binread(file!(File.join(path, 'serialization.json'), "#{id} serialization metadata"))
      metadata = JSON.parse(metadata_raw)
      metadata_raw_name = "raw-records/#{safe}.serialization.json"
      need!(parsed_metadata == metadata && metadata_sha == sha(metadata_raw) && metadata_file == metadata_raw_name,
        "#{id} serialization metadata summary differs")
      snap_meta = persisted.fetch('serialization_metadata')
      need!(snap_meta['raw'] == metadata_raw && snap_meta['raw_sha256'] == sha(metadata_raw) &&
        (snap_meta['parsed'].nil? || snap_meta['parsed'] == metadata) && read_file(metadata_raw_name) == metadata_raw,
        "#{id} persisted/raw serialization metadata differs")
      inv.fetch('files').each do |item|
        relative = safe_relative!(item.fetch('path'), "#{id} inventory member")
        bytes = File.binread(file!(File.join(path, relative), "#{id}/#{relative}"))
        need!(bytes.bytesize == item['size'] && sha(bytes) == item['sha256'], "#{id}/#{relative} current bytes differ")
        raw_name = "raw-records/#{safe}.#{relative}"
        need!(read_file(raw_name) == bytes, "#{id}/#{relative} raw copy differs")
        @expected_raw << raw_name
      end
      need!(mark_file == "data.#{mark}", "#{id} mark filename differs")
      mark_raw = File.binread(file!(File.join(path, mark_file), "#{id} raw mark file"))
      mark_entry = inv.fetch('files').find { |item| item['path'] == mark_file }
      need!(mark_entry && (!mark_bytes || mark_bytes == mark_raw.bytesize) && (!mark_sha || mark_sha == sha(mark_raw)) &&
        mark_entry['size'] == mark_raw.bytesize && mark_entry['sha256'] == sha(mark_raw), "#{id} raw mark seal differs")
      slots = validate_callback!(id, mark, path, inv, callback)
      expected_slots = mark == 'mrk3' ? 2 : 1 + expected_mrk4_sections(profile_for_case_id(id)).last.last.size
      need!(slots == expected_slots, "#{id} physical #{mark} callback slot count differs")
      need!(plain_marks!(mark_raw, slots, expected_rows: MARK_ROWS) == MARK_ROWS, "#{id} raw mark grid including EOF differs")
      true
    rescue KeyError, JSON::ParserError => error
      raise Error, "#{id} part evidence incomplete: #{error.message}"
    end

    def validate_callback!(id, mark, path, inventory, callback)
      columns = SCHEMA.map(&:first)
      if mark == 'mrk3'
        roster = columns.each_with_index.map { |column, index| [index, column, nil] }
        expected = {'state' => 'mrk3_single_unlabelled_slot_per_column', 'sections' => nil, 'roster' => roster,
          'text' => nil, 'sha256' => nil}
        need!(callback == expected && inventory['files'].none? { |item| item['path'] == 'columns_substreams.txt' },
          "#{id} MRK3 unlabelled top-level slot roster differs")
        return roster.size
      end
      need!(mark == 'mrk4', "unknown W283 mark format #{mark.inspect}")
      bytes = File.binread(file!(File.join(path, 'columns_substreams.txt'), "#{id} MRK4 callback roster"))
      entry = inventory.fetch('files').find { |item| item['path'] == 'columns_substreams.txt' }
      sections, roster = send(:parse_mrk4, bytes, columns, id)
      profile = profile_for_case_id(id)
      expected_sections = expected_mrk4_sections(profile)
      mrk4_sections!(id, profile, sections)
      text = bytes.dup.force_encoding(Encoding::UTF_8).to_s
      streams = sections.flat_map { |_column, names| names }
      prefix_roster!(streams.select { |stream| stream.end_with?('.dict_prefix') || stream.end_with?('.variant_discr_prefix') })
      expected = {'state' => 'native_substream_callback_roster_observed', 'text' => text,
        'sections' => expected_sections, 'roster' => roster, 'sha256' => sha(bytes)}
      need!(entry && entry['sha256'] == sha(bytes) && callback == expected,
        "#{id} raw MRK4 roster differs from literal topology")
      saved = "source-inventories/#{id}.columns_substreams.txt"
      need!(read_file(saved) == bytes, "#{id} MRK4 source inventory sidecar differs")
      @expected_snapshots << saved
      roster.size
    end

    def attached_contract!(generated, attached, sidecar)
      source = inventory!(generated, 'generated ATTACH source')
      target = inventory!(attached, 'attached ATTACH target')
      source_files = source['files'].to_h { |entry| [entry['path'], entry] }
      target_files = target['files'].to_h { |entry| [entry['path'], entry] }
      need!(source_files.keys.all? { |path| target_files[path] == source_files[path] }, 'ATTACH changed/omitted a generated file')
      extra = target_files.keys - source_files.keys
      need!(extra == [SIDECAR_PATH] && target_files[SIDECAR_PATH] == SIDECAR_ENTRY && sidecar == SIDECAR_BYTES &&
        target['total_bytes'] == source['total_bytes'] + SIDECAR_BYTES.bytesize,
        'ATTACH is not byte-preserving with exactly the allowed system-column sidecar')
      true
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  options = {root: nil, mode: :stock_only}
  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby scripts/verify_compact_variant_bulk_w283_capture.rb --stock-only|--full-matrix --evidence-root SSD_CAPTURE'
    parser.on('--stock-only', 'Audit exact stock-only evidence; RED is rejected') { options[:mode] = :stock_only }
    parser.on('--full-matrix', 'Audit stock plus generated/public-reader interop evidence') { options[:mode] = :full_matrix }
    parser.on('--evidence-root PATH', 'Completed direct child of an owned /opt/mldata_ssd/cache/crystal-click-w283.<suffix> task root') { |value| options[:root] = value }
  end.parse!
  unless options[:root]
    warn 'W283 capture auditor: --evidence-root is required'
    exit 2
  end
  exit(VerifyCompactVariantBulkW283Capture::Auditor.new(options[:root], mode: options[:mode]).run ? 0 : 1)
end
