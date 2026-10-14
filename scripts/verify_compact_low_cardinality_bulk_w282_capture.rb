#!/usr/bin/env ruby
# Read-only W282 evidence auditor. It never starts ClickHouse, Crystal, or a build.

require 'digest'
require 'find'
require 'json'
require 'open3'
require 'optparse'
require_relative 'probe_compact_low_cardinality_bulk_w282_matrix'

module VerifyCompactLowCardinalityBulkW282Capture
  M = ProbeCompactLowCardinalityBulkW282Matrix
  W281 = M::W281M
  W = M::W280
  FORMAT = M::FORMAT
  STOCK_STATUS = 'stock_native_matrix_exact'.freeze
  FULL_STATUS = 'generated_native_interop_matrix_exact'.freeze
  PIN_SQL = "SELECT '__W280_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;\n".b.freeze
  PIN_LINE = "__W280_PIN__\t#{W::VERSION}\t#{W::BUILD}".freeze
  MARK_ROWS = [2, 2, 2, 2, 0].freeze
  PUBLIC_ROWS = [2, 2, 2, 2].freeze
  SIDECAR_PATH = 'invalidated_system_columns.txt'.freeze
  SIDECAR_BYTES = "_block_offset\n_block_number\n".b.freeze
  SIDECAR_ENTRY = {'path' => SIDECAR_PATH, 'size' => 28,
    'sha256' => '7409424ab45090c1261e622f7423393905102e7e8cba36a6db88eb513ce1e06c'}.freeze
  PREFIX_STREAMS = %w[
    recursive_lc_w282%2E2%2E1.dict_prefix
    recursive_lc_w282%2E2%2E2.dict_prefix
    recursive_lc_w282%2E4%2E1%2Evalues.dict_prefix
    recursive_lc_w282%2E4%2E2.dict_prefix
    recursive_lc_w282%2E4%2E3%2Elabel.dict_prefix
    recursive_lc_w282%2E4%2E3%2Ecode.dict_prefix
  ].freeze
  MRK4_STREAMS_BEFORE_MAP_KEYS = %w[
    recursive_lc_w282%2E1.object_structure
    recursive_lc_w282%2E2%2E1.dict_prefix
    recursive_lc_w282%2E2%2E2.dict_prefix
    recursive_lc_w282%2E3.object_structure
    recursive_lc_w282%2E4%2E1%2Evalues.dict_prefix
    recursive_lc_w282%2E4%2E2.dict_prefix
    recursive_lc_w282%2E4%2E3%2Elabel.dict_prefix
    recursive_lc_w282%2E4%2E3%2Ecode.dict_prefix
    recursive_lc_w282%2E1.id
    recursive_lc_w282%2E1.object_shared_data.size0
    recursive_lc_w282%2E1.object_shared_data%2Epaths
    recursive_lc_w282%2E1.object_shared_data%2Evalues
    recursive_lc_w282%2E2.size0
    recursive_lc_w282%2E2%2E1.dict
    recursive_lc_w282%2E2%2E1
    recursive_lc_w282%2E2%2E2.dict
    recursive_lc_w282%2E2%2E2
    recursive_lc_w282%2E3.id
    recursive_lc_w282%2E3.object_shared_data.size0
    recursive_lc_w282%2E3.object_shared_data%2Epaths
    recursive_lc_w282%2E3.object_shared_data%2Evalues
    recursive_lc_w282%2E4%2E1.size0
  ].freeze
  MRK4_STREAMS_AFTER_MAP_KEYS = %w[
    recursive_lc_w282%2E4%2E1%2Evalues.dict
    recursive_lc_w282%2E4%2E1%2Evalues
    recursive_lc_w282%2E4%2E2.size0
    recursive_lc_w282%2E4%2E2.dict
    recursive_lc_w282%2E4%2E2
    recursive_lc_w282%2E4%2E3.size0
    recursive_lc_w282%2E4%2E3%2Elabel.dict
    recursive_lc_w282%2E4%2E3%2Elabel
    recursive_lc_w282%2E4%2E3%2Ecode.dict
    recursive_lc_w282%2E4%2E3%2Ecode
  ].freeze
  MRK4_STREAMS_BY_PROFILE = {
    's0' => (MRK4_STREAMS_BEFORE_MAP_KEYS + ['recursive_lc_w282%2E4%2E1%2Ekeys'] +
      MRK4_STREAMS_AFTER_MAP_KEYS).freeze,
    's1' => (MRK4_STREAMS_BEFORE_MAP_KEYS + ['recursive_lc_w282%2E4%2E1%2Ekeys.size',
      'recursive_lc_w282%2E4%2E1%2Ekeys'] + MRK4_STREAMS_AFTER_MAP_KEYS).freeze,
  }.freeze
  # Duplicate the finite input corpus here so the auditor's oracle is not
  # delegated to the probe, Crystal fixture, helper, or captured summary.
  INVALID_BYTES = [0x00, 0xff, 0x80, 0x41].pack('C*').b.freeze
  ORACLE_ROWS = [
    [1, [], 101, [], [], []],
    [2, [], 102, [], [], []],
    [3, [["a\0".b, "n\0".b], [INVALID_BYTES, nil]], 103,
      [["m\0".b, 10], [INVALID_BYTES, 11]], [], [["n\0".b, 65_535]]],
    [4, [['x'.b, ''.b]], 104, [['k'.b, 12]], [], [['bad'.b, 0], ['tail'.b, 42]]],
    [5, [], 105, [], [], []],
    [6, [], 106, [], [], []],
    [7, [['end'.b, 'last'.b]], 107, [['a'.b, 4]], [], [[''.b, 7]]],
    [8, [[''.b, nil], [INVALID_BYTES, "z\0".b]], 108,
      [['b'.b, 5], ['c'.b, 6]], [], [["final\0".b, 8]]],
  ].freeze
  ORACLE_SIGNATURES = [
    '1|A[]|101|M[]|E[]|N[]',
    '2|A[]|102|M[]|E[]|N[]',
    '3|A[6100,V6e00;00ff8041,N]|103|M[6d00=0a00;00ff8041=0b00]|E[]|N[6e00=ffff]',
    '4|A[78,V]|104|M[6b=0c00]|E[]|N[626164=0000;7461696c=2a00]',
    '5|A[]|105|M[]|E[]|N[]',
    '6|A[]|106|M[]|E[]|N[]',
    '7|A[656e64,V6c617374]|107|M[61=0400]|E[]|N[=0700]',
    '8|A[,N;00ff8041,V7a00]|108|M[62=0500;63=0600]|E[]|N[66696e616c00=0800]',
  ].freeze
  PREFIX_EVENT_BASIS = 'observed native callback slot order; per-site DFS labels are inferred from schema traversal and are not independently emitted by ClickHouse'.freeze
  PREFIX_CLAIM = 'MRK4 slot order is observed; the per-site DFS labels are inferred from schema traversal and are not independently emitted by ClickHouse. Callback count/order alone is not semantic evidence; exact native and public-reader value windows provide the value oracle.'.freeze
  CLAIM_BOUNDARY = 'Finite eight-row, four-data-mark evidence for the exact recursive JSON/Tuple declaration only, under MAP0/BASIC/V3 and MRK3/MRK4 × S0/S1. A stock schema rejection is a blocked native-compatibility probe, not permission to substitute a root LC or easier wrapper. Generated success is limited to this composition and requires exact public-reader windows plus byte-preserving ATTACH, CHECK, native windows, callback sidecars, and pinned source/runtime/helper identities.'.freeze
  REC_KEYS = %w[
    label process_kind argv argv_file argv_sha256 stdin_file stdin_bytes stdin_sha256
    stdout_file stdout_bytes stdout_sha256 stderr_file stderr_bytes stderr_sha256 exit signal timed_out
    timeout_seconds termination_grace_seconds max_threads max_memory_usage_bytes max_memory_usage_applicable
    required_outer_run_safe_memory_limit_bytes binary_path expected_binary_sha256 binary_sha_before
    binary_sha_after spawn_error stdin_write_error stdout_read_error stderr_read_error process_classification
    store_path
  ].sort.freeze
  MAX_FILE = 64 * 1024 * 1024

  class Error < StandardError; end

  class Auditor
    def initialize(root, mode:)
      @mode = mode
      raise Error, 'mode must be stock-only or full-matrix' unless %i[stock_only full_matrix].include?(mode)
      @root = directory!(File.expand_path(root), 'evidence root')
      @summary = JSON.parse(read_file('summary.json', 16 * 1024 * 1024))
      @expected_raw = []
      @expected_snapshots = []
      @records = {}
    rescue JSON::ParserError => e
      raise Error, "summary.json is malformed: #{e.message}"
    end

    def run
      summary_contract!
      pins!
      topology!
      invocations!
      cases!
      sidecar_inventory!
      root_inventory!
      puts "W282 capture audit passed: mode=#{@mode}; cells=4; invocations=#{@records.size}; MRK4 DFS labels remain inferred"
      true
    rescue StandardError => e
      warn "W282 capture audit failed: #{e.class}: #{e.message}"
      false
    end

    def self.self_test!
      a = allocate
      a.instance_variable_set(:@root, '/self-test')
      a.instance_variable_set(:@mode, :stock_only)
      a.send(:summary_status!, {'format' => FORMAT, 'status' => STOCK_STATUS}, :stock_only)
      a.send(:summary_status!, {'format' => FORMAT, 'status' => FULL_STATUS}, :full_matrix)
      checks = ['exact-stock-and-full-status-positive']

      a.send(:reject!) { a.send(:summary_status!, {'format' => FORMAT, 'status' => 'generated_admission_rejection_captured'}, :full_matrix) }
      checks << 'captured-admission-red-rejected-as-full-compatibility'
      a.send(:reject!) { a.send(:summary_status!, {'format' => FORMAT, 'status' => 'stock_schema_rejection_captured'}, :stock_only) }
      a.send(:reject!) { a.send(:summary_status!, {'format' => FORMAT, 'status' => 'probe_infrastructure_failure'}, :full_matrix) }
      checks << 'schema-red-and-infrastructure-not-exact'
      labels = a.send(:expected_labels, :stock_only)
      raise Error, 'stock topology seed differs' unless labels.size == 32 && labels.first == 'stock_bulk_mrk3_s0_create'
      a.send(:topology_labels!, labels, :stock_only)
      a.send(:reject!) { a.send(:topology_labels!, labels.drop(1), :stock_only) }
      checks << 'missing-invocation-negative'
      a.send(:reject!) { a.send(:topology_labels!, labels.rotate(1), :stock_only) }
      checks << 'reordered-invocation-negative'

      target_path = '/fixture/target-store/uuid'
      target_path_row = [a.send(:tag, 'target_path', 'stock_bulk_mrk3_s0'),
        "#{target_path}#{File::SEPARATOR}"].join("\t")
      a.send(:target_path_stdout_rows!, 'stock_bulk_mrk3_s0', target_path, [target_path_row])
      a.send(:reject!) do
        a.send(:target_path_stdout_rows!, 'stock_bulk_mrk3_s0', target_path,
          [[a.send(:tag, 'target_path', 'stock_bulk_mrk3_s0'), target_path].join("\t")])
      end
      checks << 'target-directory-path-trailing-separator-positive-and-negative'

      a.send(:reject!) { a.send(:validate_outcome!, 'stock_bulk_mrk3_s0_create', {'exit' => 1,
        'signal' => nil, 'timed_out' => false, 'spawn_error' => nil, 'stdin_write_error' => nil,
        'stdout_read_error' => nil, 'stderr_read_error' => nil, 'process_classification' => 'server_exception'}, ''.b, ''.b) }
      checks << 'forged-exact-summary-with-failed-raw-stage-negative'

      good_report = a.send(:helper_report_seed, 'mrk4', 's0', 'read', '/fixture/stock')
      a.send(:helper_report!, 'stock_bulk_mrk4_s0', 'mrk4', 's0', good_report, 'read', '/fixture/stock')
      checks << 'helper-reader-profile-positive'
      wrong_profile = Marshal.load(Marshal.dump(good_report)); wrong_profile['string_profile'] = 's1'
      a.send(:reject!) { a.send(:helper_report!, 'stock_bulk_mrk4_s0', 'mrk4', 's0', wrong_profile, 'read', '/fixture/stock') }
      wrong_observed_profile = Marshal.load(Marshal.dump(good_report)); wrong_observed_profile['reader_ordinary_profile_matches_requested'] = false
      a.send(:reject!) { a.send(:helper_report!, 'stock_bulk_mrk4_s0', 'mrk4', 's0', wrong_observed_profile, 'read', '/fixture/stock') }
      checks << 'wrong-helper-profile-negative'

      generated, attached = a.send(:seed_inventories)
      a.send(:attached_contract!, generated, attached, SIDECAR_BYTES)
      a.send(:reject!) { a.send(:attached_contract!, generated, attached, 'modified'.b) }
      missing_sidecar = Marshal.load(Marshal.dump(attached)); missing_sidecar['files'].pop; missing_sidecar['total_bytes'] -= SIDECAR_BYTES.bytesize
      a.send(:reject!) { a.send(:attached_contract!, generated, missing_sidecar, SIDECAR_BYTES) }
      checks << 'missing-or-modified-sidecar-negative'

      a.instance_variable_set(:@active_query_id, 'stock_bulk_mrk3_s0')
      expected = a.send(:window_rows, 'full')
      a.instance_variable_set(:@active_query_id, nil)
      a.send(:window_summary!, 'stock_bulk_mrk3_s0_values_full', 'stock_bulk_mrk3_s0', 'full', expected,
        {'rows' => expected.map { |r| {'pk' => Integer(r[1], 10), 'signature' => r[2]} },
         'expected_rows' => expected.map { |r| {'pk' => Integer(r[1], 10), 'signature' => r[2]} }, 'raw_rows' => expected})
      changed = Marshal.load(Marshal.dump(expected)); changed[2][2] = 'changed'
      a.send(:reject!) do
        a.send(:window_summary!, 'stock_bulk_mrk3_s0_values_full', 'stock_bulk_mrk3_s0', 'full', expected,
          {'rows' => changed.map { |r| {'pk' => Integer(r[1], 10), 'signature' => r[2]} },
           'expected_rows' => expected.map { |r| {'pk' => Integer(r[1], 10), 'signature' => r[2]} }, 'raw_rows' => changed})
      end
      checks << 'changed-row-negative'

      mark = a.send(:seed_mark_bytes, 2, MARK_ROWS)
      raise Error, 'positive raw mark grid seed differs' unless a.send(:plain_marks!, mark, 2) == MARK_ROWS
      a.send(:reject!) { a.send(:plain_marks!, mark, 2, expected_rows: [2, 2, 2, 1, 1]) }
      checks << 'changed-mark-grid-negative'

      a.send(:low_cardinality_prefix_roster!, PREFIX_STREAMS)
      a.send(:reject!) { a.send(:low_cardinality_prefix_roster!, PREFIX_STREAMS.reject { |s| s.include?('%2E4%2E2.dict_prefix') }) }
      checks << 'missing-zero-occurrence-lc-prefix-negative'

      raw_refs = ['raw-records/case.data.bin', 'raw-records/case.serialization.json']
      source_refs = ['source-inventories/case.json', 'source-inventories/case.columns_substreams.txt']
      a.send(:compare_directory_members!, 'raw-records', %w[case.data.bin case.serialization.json], raw_refs)
      a.send(:compare_directory_members!, 'source-inventories', %w[case.columns_substreams.txt case.json], source_refs)
      a.send(:reject!) { a.send(:compare_directory_members!, 'raw-records', ['case.data.bin'], raw_refs) }
      a.send(:reject!) { a.send(:compare_directory_members!, 'raw-records', %w[case.data.bin case.serialization.json extra.bin], raw_refs) }
      a.send(:reject!) { a.send(:compare_directory_members!, 'source-inventories', %w[case.json case.json], source_refs) }
      a.send(:reject!) { a.send(:compare_directory_members!, 'raw-records', %w[case.data.bin case.serialization.json], ['case.data.bin', raw_refs.last]) }
      checks << 'raw-and-source-inventory-root-relative-positive-and-closure-mutants'

      root_entries = %w[invocations parts raw-records source-inventories stores summary.json summary.md]
      stock_stores = a.send(:expected_ids)
      a.send(:root_inventory_contract!, root_entries, stock_stores, [], :stock_only)
      a.send(:reject!) { a.send(:root_inventory_contract!, root_entries - ['parts'], stock_stores, [], :stock_only) }
      a.send(:reject!) { a.send(:root_inventory_contract!, root_entries, stock_stores, ['unexpected'], :stock_only) }
      a.send(:reject!) { a.send(:root_inventory_contract!, root_entries + ['extra'], stock_stores, [], :stock_only) }
      full_stores = stock_stores + stock_stores.map { |id| "target_#{id}" }
      a.send(:root_inventory_contract!, root_entries, full_stores, stock_stores, :full_matrix)
      a.send(:reject!) { a.send(:root_inventory_contract!, root_entries, full_stores, stock_stores.drop(1), :full_matrix) }
      checks << 'stock-empty-parts-and-full-generated-root-topology-positive-and-mutants'

      %w[s0 s1].each do |profile|
        sections = a.send(:expected_mrk4_sections, profile)
        expected_total = profile == 's0' ? 34 : 35
        raise Error, "MRK4 #{profile} physical slot seed differs" unless sections.sum { |_column, streams| streams.size } == expected_total
        a.send(:mrk4_sections!, "stock_bulk_mrk4_#{profile}", profile, sections)
      end
      wrong_s1_roster = a.send(:expected_mrk4_sections, 's1').map { |column, streams| [column, streams.dup] }
      wrong_s1_roster.last[1].delete('recursive_lc_w282%2E4%2E1%2Ekeys.size')
      a.send(:reject!) { a.send(:mrk4_sections!, 'stock_bulk_mrk4_s1', 's1', wrong_s1_roster) }
      checks << 'profile-bound-mrk4-callback-count-and-exact-stream-roster'
      puts "W282 capture auditor Ruby-only self-test passed: cases=#{checks.size}; #{checks.join(',')}; no capture reads or subprocesses"
      true
    rescue StandardError => e
      warn "W282 capture auditor self-test failed: #{e.class}: #{e.message}"
      false
    end

    private

    def need!(ok, message); raise Error, message unless ok; end
    def reject!
      yield
      raise Error, 'negative seed unexpectedly passed'
    rescue Error => e
      raise if e.message == 'negative seed unexpectedly passed'
    end
    def summary_status!(summary, mode)
      expected = mode == :stock_only ? STOCK_STATUS : FULL_STATUS
      need!(summary.is_a?(Hash) && summary['format'] == FORMAT && summary['status'] == expected,
        "requires exact #{mode} status #{expected}; RED/infrastructure/incomplete captures are not compatibility")
    end
    def directory!(path, label)
      st = File.lstat(path)
      need!(st.directory? && !st.symlink? && File.realpath(path) == path, "#{label} is symlinked or non-canonical")
      path
    rescue Errno::ENOENT
      raise Error, "#{label} is absent"
    end
    def file!(path, label, max = MAX_FILE)
      st = File.lstat(path)
      need!(st.file? && !st.symlink? && File.realpath(path) == path && st.size <= max, "#{label} is absent, unsafe, or oversized")
      path
    rescue Errno::ENOENT
      raise Error, "#{label} is absent"
    end
    def safe_relative!(name, label)
      need!(name.is_a?(String) && !name.empty? && !name.start_with?('/') &&
        name.split(/[\\\/]/, -1).none? { |part| ['', '.', '..'].include?(part) }, "#{label} is unsafe")
      name
    end
    def read_file(rel, max = MAX_FILE)
      safe_relative!(rel, 'evidence path')
      path = File.join(@root, rel)
      directory!(File.dirname(path), "parent for #{rel}")
      File.binread(file!(path, rel, max))
    end
    def sha(bytes); Digest::SHA256.hexdigest(bytes); end
    def file_sha(path, label, max = MAX_FILE); Digest::SHA256.file(file!(path, label, max)).hexdigest; end
    def expected_ids; M::MARK_FORMATS.flat_map { |mark| M::PROFILES.map { |profile| "#{M::CASE}_#{mark}_#{profile}" } }; end
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
    def topology_labels!(labels, mode)
      need!(labels == expected_labels(mode), 'invocation topology is missing, reordered, duplicated, or not stock-first')
    end

    def literal_signatures
      ORACLE_ROWS.map do |row|
        left_id, array_a, right_id, map_b, array_b, nested_b = row
        hex = ->(bytes) { bytes.to_s.b.unpack1('H*') }
        nullable = ->(value) { value.nil? ? 'N' : "V#{hex.call(value)}" }
        array_a_text = array_a.map { |text, maybe| "#{hex.call(text)},#{nullable.call(maybe)}" }.join(';')
        map_text = map_b.map { |key, value| "#{hex.call(key)}=#{[value].pack('S<').unpack1('H*')}" }.join(';')
        array_text = array_b.map { |value| hex.call(value) }.join(';')
        nested_text = nested_b.map { |label, code| "#{hex.call(label)}=#{[code].pack('S<').unpack1('H*')}" }.join(';')
        "#{left_id}|A[#{array_a_text}]|#{right_id}|M[#{map_text}]|E[#{array_text}]|N[#{nested_text}]"
      end
    end

    def summary_contract!
      summary_status!(@summary, @mode)
      need!(@root == File.expand_path(@root) && File.dirname(@root) == '/private/tmp', 'evidence root must be a canonical direct child of /private/tmp')
      need!(@summary['evidence_root'] == @root, 'summary evidence root differs from audit root')
      validate_literal_schedule!
      need!(ORACLE_ROWS.size == 8 && literal_signatures == ORACLE_SIGNATURES &&
        literal_signatures == M::EXPECTED_SIGNATURES && M::ROWS == ORACLE_ROWS,
        'independent Ruby literal signatures or W282 probe literals differ')
      ids = expected_ids
      entries = @summary.fetch('cases')
      need!(entries.is_a?(Hash) && entries.keys.sort == ids.sort, 'expected exactly MRK3/MRK4 × S0/S1 cells')
      tokens = ids.map do |id|
        match = /\Aw282m_([a-zA-Z0-9]+)_#{Regexp.escape(id)}\z/.match(entries.fetch(id).fetch('table'))
        need!(match, "#{id} table name is not rooted in the W282 token namespace")
        match[1]
      end
      need!(tokens.uniq.size == 1, 'stock tables do not share exactly one capture token')
      @table_token = tokens.first

      fixture = @summary.fetch('fixture')
      expected_fixture = {
        'schema' => M::SCHEMAS.fetch(M::CASE), 'json_declaration' => M::JSON_DECLARATION,
        'literal_signatures' => literal_signatures, 'row_count' => 8, 'rows_per_mark' => 2,
        'data_marks' => 4, 'raw_mark_file_rows' => MARK_ROWS, 'public_reader_mark_rows' => PUBLIC_ROWS,
        'native_windows' => M::WINDOWS, 'physical_windows' => M::PHYSICAL_WINDOWS,
        'low_cardinality_site_serializer_dfs_hypothesis' => M::LC_SITE_DFS,
        'low_cardinality_occurrences_per_mark' => M::LC_OCCURRENCES_PER_MARK,
        'low_cardinality_prefix_callbacks_expected' => 6,
        'oracle_input' => 'independent literal Ruby values encoded as RowBinary; expected signatures are derived from those literals and never from Crystal output',
      }
      expected_fixture.each { |key, value| need!(fixture[key] == value, "fixture #{key} differs from the bounded W282 oracle") }
      need!(fixture.fetch('low_cardinality_prefix_callback_claim') == PREFIX_CLAIM,
        'MRK4 callback claim widens inferred DFS labels')
      need!(M::TYPE == M::SCHEMAS.fetch(M::CASE).last.last && M::JSON_DECLARATION ==
        'JSON(max_dynamic_types=0, max_dynamic_paths=0, id UInt64)', 'exact W282 schema or JSON declaration changed')

      schema_parameters = @summary.fetch('schema_parameters')
      need!(schema_parameters == {
        'object_serialization_version' => 'v3', 'object_shared_data_serialization_version' => 'map',
        'map_layout_value' => 0, 'object_shared_data_buckets_for_compact_part' => 1,
        'string_profiles' => {'s0' => 'single_stream', 's1' => 'with_size_stream'},
        'mark_compression' => 'plain', 'variant_discriminator_mode' => 'basic',
        'allow_suspicious_low_cardinality_types' => 1, 'mark_formats' => M::MARK_FORMATS,
      }, 'schema/profile/LC settings summary differs')

      @expected_settings = ids.to_h do |id|
        entry = entries.fetch(id)
        mark = id.split('_')[-2]; profile = id.split('_').last
        expected_parameters = {
          'object_serialization_version' => 'v3', 'object_shared_data_serialization_version' => 'map',
          'map_layout_value' => 0, 'object_shared_data_buckets_for_compact_part' => 1,
          'string_serialization_version' => profile == 's1' ? 'with_size_stream' : 'single_stream',
          'mark_compression' => 'plain', 'variant_discriminator_mode' => 'basic',
        }
        need!(entry.values_at('case_id', 'schema_kind', 'mark_format', 'string_profile', 'status') ==
          [id, M::CASE, mark, profile, 'exact_native_values'], "#{id} stock status or identity differs")
        need!(entry['store'] == File.join(@root, 'stores', id) && entry['schema_parameters'] == expected_parameters,
          "#{id} store or schema parameters differ")
        settings = expected_settings(mark, profile)
        need!(entry['settings_exact'] == {
          'profile' => profile, 'clickhouse_settings' => settings,
          'allow_suspicious_low_cardinality_types' => 1, 'object_serialization_version' => 'v3',
          'object_shared_data_serialization_version' => 'map', 'object_shared_data_buckets_for_compact_part' => 1,
          'variant_discriminator_mode' => 'basic', 'mark_format' => mark, 'mark_compression' => 'plain',
        }, "#{id} exact settings record differs")
        [id, settings]
      end

      helper_pin = @summary['helper_pin']
      need!(@mode == :stock_only ? helper_pin.nil? : helper_pin.is_a?(Hash), 'helper pin presence differs from audit mode')
      boundary = @summary.fetch('claim_boundary').to_s
      need!(boundary == CLAIM_BOUNDARY, 'W282 claim boundary differs from the frozen finite-witness boundary')
      need!(!boundary.match?(/full JSON decoder|CityHash verified|semantic DFS order is proven/i), 'capture claim exceeds its evidence')
      true
    rescue KeyError, TypeError => e
      raise Error, "summary is incomplete: #{e.message}"
    end

    def validate_literal_schedule!
      occurrences = M::LC_SITE_DFS.to_h { |site| [site, []] }
      ORACLE_ROWS.each_slice(2) do |rows|
        a_count = rows.sum { |row| row.fetch(1).size }
        map_count = rows.sum { |row| row.fetch(3).size }
        array_count = rows.sum { |row| row.fetch(4).size }
        nested_count = rows.sum { |row| row.fetch(5).size }
        [a_count, a_count, map_count, array_count, nested_count, nested_count].each_with_index do |count, index|
          occurrences.fetch(M::LC_SITE_DFS.fetch(index)) << count
        end
      end
      need!(M::LC_SITE_DFS.size == 6 && M::LC_SITE_DFS.uniq == M::LC_SITE_DFS &&
        M::LC_OCCURRENCES_PER_MARK == occurrences && occurrences.fetch(M::EMPTY_LC_SITE) == [0, 0, 0, 0],
        'LC mark occurrence schedule differs from independent Ruby rows, including the wholly empty lane')
      nonempty = M::LC_SITE_DFS - [M::EMPTY_LC_SITE]
      need!(nonempty.all? { |site| occurrences.fetch(site) == [0, 3, 0, 3] || occurrences.fetch(site) == [0, 3, 0, 2] } &&
        nonempty.any? { |site| occurrences.fetch(site).any? { |q| q.positive? && q != 2 } },
        'LC schedule lacks zero/nonzero/zero/nonzero or Q != P witness')
      true
    end

    def expected_settings(mark, profile)
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
        'use_compact_variant_discriminators_serialization=0', 'allow_suspicious_low_cardinality_types=1',
      ].join(', ')
    end

    def pins!
      runtime = @summary.fetch('runtime_pin')
      need!(runtime.values_at('binary', 'expected_sha256', 'sha256_before', 'sha256_after', 'version', 'build') ==
        [W::BINARY, W::BINARY_SHA256, W::BINARY_SHA256, W::BINARY_SHA256, W::VERSION, W::BUILD],
        'native runtime pin metadata differs')
      binary = file!(W::BINARY, 'pinned native runtime', 1024 * 1024 * 1024)
      need!(File.executable?(binary) && file_sha(binary, 'native runtime', 1024 * 1024 * 1024) == W::BINARY_SHA256,
        'actual native runtime bytes differ from the fixed pin')

      source = @summary.fetch('source_pin')
      need!(source.values_at('root', 'revision_expected', 'revision_before', 'revision_after') ==
        [W::SOURCE_ROOT, W::SOURCE_REVISION, W::SOURCE_REVISION, W::SOURCE_REVISION], 'upstream source revision metadata differs')
      out, err, status = Open3.capture3('git', '-C', W::SOURCE_ROOT, 'rev-parse', 'HEAD')
      need!(status.success? && err.empty? && out.strip == W::SOURCE_REVISION, 'current pinned-source checkout revision differs')
      source_before = source.fetch('source_sha256_before'); source_after = source.fetch('source_sha256_after')
      source_actual = W::SOURCE_FILES.to_h do |rel|
        [rel, file_sha(File.join(W::SOURCE_ROOT, rel), "pinned source #{rel}")]
      end
      need!(source_before == source_after && source_before == source_actual, 'pinned upstream source byte seals differ')

      expected_local_paths = [W281::PROBE_SOURCE, W281::HELPER_SOURCE, W281::FIXTURE_SOURCE,
        M::PROBE_SOURCE, M::FIXTURE_SOURCE]
      expected_local_paths << M::HELPER_SOURCE if @mode == :full_matrix
      expected_local_paths = expected_local_paths.map { |path| File.realpath(path) }.uniq.sort
      local_pins = @summary.fetch('matrix_source_pins')
      local_before = local_pins.fetch('sha256_before'); local_after = local_pins.fetch('sha256_after')
      local_actual = expected_local_paths.to_h do |path|
        [path, file_sha(path, "matrix source #{File.basename(path)}")]
      end
      need!(local_before == local_after && local_before == local_actual, 'W281/W282 matrix, helper, or fixture source seals differ')

      helper = @summary.fetch('helper_pin')
      if @mode == :full_matrix
        need!(helper.values_at('source', 'sha256_before', 'sha256_after') ==
          [M::HELPER_SOURCE, helper['expected_sha256'], helper['expected_sha256']] &&
          helper['expected_sha256'].to_s.match?(/\A[0-9a-f]{64}\z/), 'prebuilt helper source/hash record differs')
        helper_path = file!(helper.fetch('path'), 'prebuilt W282 helper', 1024 * 1024 * 1024)
        need!(File.executable?(helper_path) && file_sha(helper_path, 'prebuilt W282 helper', 1024 * 1024 * 1024) == helper['expected_sha256'],
          'prebuilt W282 helper executable bytes differ')
      end
      true
    rescue KeyError, TypeError => e
      raise Error, "pin evidence incomplete: #{e.message}"
    end

    def topology!
      roster = @summary.fetch('invocation_roster')
      expected_keys = %w[argv argv_file binary_path label process_kind record_file stderr_file stdin_file stdout_file store_path].sort
      need!(roster.is_a?(Array) && roster.all? { |entry| entry.is_a?(Hash) && entry.keys.sort == expected_keys },
        'invocation roster field set differs')
      labels = roster.map { |entry| entry.fetch('label') }
      topology_labels!(labels, @mode)
      @labels = labels
      refs = Hash.new(0)
      @stage_objects = Hash.new { |hash, key| hash[key] = [] }
      walk = lambda do |node|
        case node
        when Hash
          if @labels.include?(node['label']) && node.key?('classification') && node.key?('record_file')
            refs[node['label']] += 1
            @stage_objects[node['label']] << node
          end
          node.each { |key, value| walk.call(value) unless key == 'invocation_roster' }
        when Array
          node.each { |value| walk.call(value) }
        end
      end
      walk.call(@summary)
      @stage_refs = refs
      expected_refs = @labels.to_h { |label| [label, label.end_with?('_helper_write') ? 2 : 1] }
      need!(@stage_refs == expected_refs, 'summary does not contain exactly one raw-stage reference (two for helper write) per invocation')
      true
    rescue KeyError => e
      raise Error, "invocation topology incomplete: #{e.message}"
    end

    def expected_spec(label)
      helper_pin = @summary.fetch('helper_pin')
      if label.end_with?('_helper_stock') || label.end_with?('_helper_write')
        action = label.end_with?('_helper_stock') ? 'read' : 'write'
        id = label.delete_suffix(action == 'read' ? '_helper_stock' : '_helper_write')
        entry = @summary.fetch('cases').fetch(id)
        part = action == 'read' ? entry.dig('schema_part', 'part', 'path') : File.join(@root, 'parts', id, W::PART_NAME)
        need!(part, "#{label} part path is absent")
        path = helper_pin.fetch('path')
        return ['crystal-helper', path, nil, [path, action, id.split('_')[-2], id.split('_').last, part], 'bin', ''.b]
      end

      id = expected_ids.find { |candidate| label == candidate || label.start_with?(candidate + '_') }
      need!(id, "unknown invocation label #{label.inspect}")
      entry = @summary.fetch('cases').fetch(id)
      mark = id.split('_')[-2]; profile = id.split('_').last
      target = "w282m_#{@table_token}_target_#{id}"
      attached = label.include?('_attached_') || label.end_with?('_attach') || label.end_with?('_target_create')
      store_id = attached ? "target_#{id}" : id
      table = attached ? target : entry.fetch('table')

      case label
      when "#{id}_create"
        native_spec(store_id, PIN_SQL + create_sql(entry.fetch('table'), mark, profile), entry.fetch('table'))
      when "#{id}_insert"
        rowbinary_spec(id, entry, store_id)
      when "#{id}_schema_part"
        native_spec(store_id, PIN_SQL + schema_sql(id, entry.fetch('table')), entry.fetch('table'))
      when "#{id}_native_check"
        native_spec(store_id, PIN_SQL + check_sql("#{id}_native", entry.fetch('table')), entry.fetch('table'))
      when "#{id}_target_create"
        sql = PIN_SQL + create_sql(target, mark, profile) + target_schema_sql(id, target)
        native_spec(store_id, sql, target)
      when "#{id}_attach"
        native_spec(store_id, PIN_SQL + "ALTER TABLE default.#{target} ATTACH PART '#{W::PART_NAME}';\n", target)
      when "#{id}_attached_check"
        native_spec(store_id, PIN_SQL + check_sql("#{id}_attached", target), target)
      when "#{id}_attached_schema_part"
        native_spec(store_id, PIN_SQL + schema_sql("#{id}_attached", target), target)
      else
        match = /\A#{Regexp.escape(id)}(?:_attached)?_values_(full|middle|last|eof)\z/.match(label)
        need!(match, "unclassified invocation #{label}")
        query_id = label.include?('_attached_values_') ? "#{id}_attached" : id
        native_spec(store_id, PIN_SQL + values_sql(query_id, table, match[1]), table)
      end
    rescue KeyError => e
      raise Error, "cannot reconstruct #{label}: #{e.message}"
    end

    def native_spec(store_id, sql, _table)
      store = File.join(@root, 'stores', store_id)
      argv = [W::BINARY, 'local', '--path', store, '--session_timezone=UTC', '--max_threads=1',
        "--max_memory_usage=#{W::MEMORY_LIMIT}", '--multiquery']
      ['clickhouse-local', W::BINARY, store, argv, 'sql', sql.b]
    end

    def rowbinary_spec(id, entry, store_id)
      rows = (0...M::ROW_COUNT).map { |index| rowbinary_row(index) }
      literal = entry.fetch('literal_input')
      need!(literal['row_count'] == M::ROW_COUNT && literal['query'] ==
        "INSERT INTO default.#{entry.fetch('table')} FORMAT RowBinary" && literal['rows'].is_a?(Array) && literal['rows'].size == M::ROW_COUNT,
        "#{id} literal RowBinary roster differs")
      literal['rows'].each_with_index do |row, index|
        need!(row == {'pk' => index + 1, 'values' => literal_signatures.fetch(index),
          'rowbinary_hex' => rows.fetch(index).unpack1('H*')}, "#{id} literal RowBinary row #{index + 1} differs from Ruby literals")
      end
      bytes = rows.join.b
      need!(literal['stdin_file'] == "#{id}_insert.stdin.bin" && literal['stdin_bytes'] == bytes.bytesize &&
        literal['stdin_sha256'] == sha(bytes), "#{id} literal RowBinary stdin seal differs")
      store = File.join(@root, 'stores', store_id)
      query = "INSERT INTO default.#{entry.fetch('table')} FORMAT RowBinary"
      argv = [W::BINARY, 'local', '--path', store, '--session_timezone=UTC', '--max_threads=1',
        "--max_memory_usage=#{W::MEMORY_LIMIT}", '--input_format_binary_read_json_as_string=0', '--query', query]
      ['clickhouse-local', W::BINARY, store, argv, 'bin', bytes]
    end

    def rowbinary_varuint(value)
      need!(value.is_a?(Integer) && value >= 0, 'RowBinary VarUInt is not nonnegative')
      bytes = []
      loop do
        byte = value & 0x7f
        value >>= 7
        bytes << (value.zero? ? byte : byte | 0x80)
        break if value.zero?
      end
      bytes.pack('C*').b
    end
    def rowbinary_string(value)
      bytes = value.to_s.b
      rowbinary_varuint(bytes.bytesize) + bytes
    end
    def rowbinary_json(identifier)
      rowbinary_varuint(1) + rowbinary_string('id') + [identifier].pack('Q<').b
    end
    def rowbinary_array(values)
      rowbinary_varuint(values.size) + values.join.b
    end
    def rowbinary_nullable_string(value)
      value.nil? ? "\x01".b : "\x00".b + rowbinary_string(value)
    end
    def rowbinary_row(index)
      left_id, array_a, right_id, map_b, array_b, nested_b = ORACLE_ROWS.fetch(index)
      a = rowbinary_array(array_a.map { |text, nullable| rowbinary_string(text) + rowbinary_nullable_string(nullable) })
      map = rowbinary_array(map_b.map { |key, value| rowbinary_string(key) + [value].pack('S<').b })
      empty_strings = rowbinary_array(array_b.map { |value| rowbinary_string(value) })
      nested = rowbinary_array(nested_b.map { |label, code| rowbinary_string(label) + [code].pack('S<').b })
      [left_id].pack('Q<').b + rowbinary_json(left_id) + a + rowbinary_json(right_id) + map + empty_strings + nested
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
    def create_sql(table, mark, profile)
      declarations = M::SCHEMAS.fetch(M::CASE).map { |name, type| "`#{name}` #{type}" }.join(', ')
      "SET flatten_nested=0;\nSET allow_suspicious_low_cardinality_types=1;\nSET use_variant_as_common_type=1;\n" \
        "CREATE TABLE default.#{table} (#{declarations}) ENGINE=MergeTree ORDER BY pk SETTINGS #{expected_settings(mark, profile)};\n"
    end
    def native_projection_sql
      root = "`#{M::COLUMN}`"
      left_id = "tupleElement(#{root}, 1).id"
      array_a = "tupleElement(#{root}, 2)"
      right_id = "tupleElement(#{root}, 3).id"
      bulk_b = "tupleElement(#{root}, 4)"
      map_b = "tupleElement(#{bulk_b}, 1)"
      array_b = "tupleElement(#{bulk_b}, 2)"
      nested_b = "tupleElement(#{bulk_b}, 3)"
      array_a_item = 'tupleElement(w282_a, 1)'
      nullable_a_item = 'tupleElement(w282_a, 2)'
      nested_label = 'tupleElement(w282_nested, 1)'
      nested_code = 'tupleElement(w282_nested, 2)'
      string_hex = ->(expression) { "lower(hex(#{expression}))" }
      raw_scalar = ->(expression) { "lower(hex(reinterpretAsFixedString(#{expression})))" }
      nullable = ->(expression) do
        "if(isNull(#{expression}), 'N', concat('V', #{string_hex.call("assumeNotNull(#{expression})")}))"
      end
      "concat(toString(#{left_id}), '|A[', " \
        "arrayStringConcat(arrayMap(w282_a -> concat(#{string_hex.call(array_a_item)}, ',', " \
        "#{nullable.call(nullable_a_item)}), #{array_a}), ';'), ']|', " \
        "toString(#{right_id}), '|M[', " \
        "arrayStringConcat(arrayMap((w282_map_key, w282_map_value) -> " \
        "concat(#{string_hex.call('w282_map_key')}, '=', #{raw_scalar.call('w282_map_value')}), " \
        "mapKeys(#{map_b}), mapValues(#{map_b})), ';'), ']|E[', " \
        "arrayStringConcat(arrayMap(w282_e -> #{string_hex.call('w282_e')}, #{array_b}), ';'), ']|N[', " \
        "arrayStringConcat(arrayMap(w282_nested -> " \
        "concat(#{string_hex.call(nested_label)}, '=', #{raw_scalar.call(nested_code)}), " \
        "#{nested_b}), ';'), ']')"
    end
    def values_sql(id, table, window)
      predicate = M::WINDOWS.fetch(window)
      if window == 'eof'
        return "SELECT '#{tag('values', id, window)}', toString(count()) FROM default.#{table} WHERE #{predicate} FORMAT TSVRaw;\n"
      end
      where = predicate ? " WHERE #{predicate}" : ''
      "SELECT '#{tag('values', id, window)}', toString(pk), #{native_projection_sql} " \
        "FROM default.#{table}#{where} ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw;\n"
    end

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
        expected_sha = kind == 'crystal-helper' ? @summary.dig('helper_pin', 'expected_sha256') : W::BINARY_SHA256
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

    def read_at(directory, name)
      safe_relative!(name, 'invocation sidecar path')
      path = File.join(directory, name)
      File.binread(file!(path, name))
    end
    def validate_outcome!(label, record, stdout, stderr)
      good = record['timed_out'] == false && record['signal'].nil? && record['exit'] == 0 &&
        %w[spawn_error stdin_write_error stdout_read_error stderr_read_error].all? { |key| record[key].nil? } &&
        record['process_classification'] == 'success'
      need!(good && stderr.empty?, "#{label} raw stage failed, timed out, signalled, or emitted stderr")
      need!(stdout.is_a?(String), "#{label} raw stdout is not bytes")
      true
    end
    def resources!(label, record, kind)
      contract = W::W241
      helper = kind == 'crystal-helper'
      expected = [contract::TIMEOUT, contract::GRACE, contract::OUTER_RUN_SAFE_LIMIT,
        helper ? nil : 1, helper ? nil : contract::MEMORY, !helper]
      actual = record.values_at('timeout_seconds', 'termination_grace_seconds',
        'required_outer_run_safe_memory_limit_bytes', 'max_threads', 'max_memory_usage_bytes', 'max_memory_usage_applicable')
      need!(actual == expected, "#{label} timeout/resource contract differs")
    end
    def roster_match!(roster, record)
      %w[label process_kind binary_path store_path argv stdin_file argv_file stdout_file stderr_file].each do |key|
        need!(roster[key] == record[key], "roster #{record['label']}.#{key} differs from raw record")
      end
      need!(roster['record_file'] == "#{record['label']}.json", "roster #{record['label']} record file differs")
    end
    def validate_stage_references!
      @stage_objects.each do |label, stages|
        record = @records.fetch(label)
        expected = {
          'label' => label, 'classification' => record['process_classification'],
          'exit' => record['exit'], 'signal' => record['signal'],
          'stdout_file' => record['stdout_file'], 'stdout_bytes' => record['stdout_bytes'],
          'stdout_sha256' => record['stdout_sha256'], 'stderr_file' => record['stderr_file'],
          'stderr_bytes' => record['stderr_bytes'], 'stderr_sha256' => record['stderr_sha256'],
          'argv_file' => record['argv_file'], 'argv' => record['argv'],
          'stdin_file' => record['stdin_file'], 'stdin_bytes' => record['stdin_bytes'],
          'stdin_sha256' => record['stdin_sha256'], 'record_file' => "#{label}.json",
        }
        stages.each { |stage| need!(stage == expected, "#{label} summary-stage reference differs from raw record") }
      end
    end

    def cases!
      expected_ids.each do |id|
        entry = @summary.fetch('cases').fetch(id)
        mark = id.split('_')[-2]
        profile = id.split('_').last
        need!(entry.values_at('case_id', 'schema_kind', 'mark_format', 'string_profile', 'status') ==
          [id, M::CASE, mark, profile, 'exact_native_values'], "#{id} stock cell identity/status differs")
        need!(entry['store'] == File.join(@root, 'stores', id) &&
          entry['schema_parameters'] == {
            'object_serialization_version' => 'v3', 'object_shared_data_serialization_version' => 'map',
            'map_layout_value' => 0, 'object_shared_data_buckets_for_compact_part' => 1,
            'string_serialization_version' => profile == 's1' ? 'with_size_stream' : 'single_stream',
            'mark_compression' => 'plain', 'variant_discriminator_mode' => 'basic',
          }, "#{id} native store/schema parameters differ")

        stage!("#{id}_create", entry.fetch('create'))
        stage!("#{id}_insert", entry.fetch('insert'))
        stage!("#{id}_schema_part", entry.dig('schema_part', 'invocation'))
        stage!("#{id}_native_check", entry.dig('check', 'invocation'))
        sql_stdout!("#{id}_create", [PIN_LINE])
        sql_stdout!("#{id}_insert", [])
        native_schema!(id, entry.fetch('schema_part'), entry.fetch('table'))
        check_stdout!("#{id}_native", entry.fetch('check'))
        validate_windows!(id, entry.fetch('table'), entry.fetch('windows'), false)

        raw = entry.dig('schema_part', 'part', 'raw_capture')
        validate_part!(id, mark, entry.dig('schema_part', 'part', 'path'), raw.fetch('inventory'),
          raw.fetch('snapshot'), raw.fetch('callback_roster'), raw.fetch('serialization_metadata'),
          raw.fetch('serialization_metadata_sha256'), raw.fetch('serialization_metadata_raw_file'),
          raw.fetch('mark_file'), raw.fetch('mark_bytes'), raw.fetch('mark_sha256'), :stock)

        next if @mode == :stock_only
        validate_full_case!(id, entry, mark, profile)
      end
      true
    rescue KeyError, TypeError, NoMethodError => e
      raise Error, "cell evidence incomplete: #{e.class}: #{e.message}"
    end

    def validate_full_case!(id, entry, mark, profile)
      stock_read = entry.fetch('library_stock_read')
      need!(stock_read['status'] == 'exact_public_recursive_reads', "#{id} stock helper read is not exact")
      helper_report!(id, mark, profile, stock_read.fetch('report'), 'read',
        entry.dig('schema_part', 'part', 'path'))
      helper_stdout!("#{id}_helper_stock", stock_read.fetch('report'))
      stage!("#{id}_helper_stock", stock_read.fetch('invocation'))

      generated = entry.fetch('library_generated')
      need!(generated['status'] == 'exact_generated_native_interop', "#{id} generated status is not exact")
      helper_wrapper = generated.fetch('helper_report')
      need!(helper_wrapper['status'] == 'exact_public_recursive_reads', "#{id} generated helper report status differs")
      helper_report!(id, mark, profile, helper_wrapper.fetch('report'), 'write',
        File.join(@root, 'parts', id, W::PART_NAME))
      helper_stdout!("#{id}_helper_write", helper_wrapper.fetch('report'))
      stage!("#{id}_helper_write", generated.fetch('helper_invocation'))

      target = generated.fetch('native_target')
      target_table = "w282m_#{@table_token}_target_#{id}"
      need!(target.values_at('state', 'table', 'store') ==
        ['ready', target_table, File.join(@root, 'stores', "target_#{id}")], "#{id} target identity differs")
      stage!("#{id}_target_create", target.fetch('create'))
      target_create_stdout!(id, target)
      stage!("#{id}_attach", generated.dig('attach', 'invocation'))
      sql_stdout!("#{id}_attach", [PIN_LINE])
      stage!("#{id}_attached_check", generated.dig('check', 'invocation'))
      check_stdout!("#{id}_attached", generated.fetch('check'))

      active = generated.dig('active_part', 'part')
      need!(active.is_a?(Hash), "#{id} attached active part is absent")
      stage!("#{id}_attached_schema_part", generated.dig('active_part', 'invocation'))
      native_schema!("#{id}_attached", generated.fetch('active_part'), target_table)
      validate_windows!(id, target_table, generated.fetch('native_windows'), true)

      generated_path = File.join(@root, 'parts', id, W::PART_NAME)
      need!(generated['part_path'] == generated_path, "#{id} generated part path differs")
      metadata = generated.fetch('serialization_metadata')
      validate_part!("#{id}_generated", mark, generated_path, generated.fetch('inventory'),
        generated.fetch('part_snapshot'), generated.fetch('callback_roster'), metadata.fetch('parsed'),
        metadata.fetch('raw_sha256'), "raw-records/#{id}_generated.serialization.json", "data.#{mark}", nil, nil, :generated)

      raw = generated.dig('active_part', 'part', 'raw_capture')
      validate_part!("#{id}_attached", mark, active.fetch('path'), raw.fetch('inventory'), raw.fetch('snapshot'),
        raw.fetch('callback_roster'), raw.fetch('serialization_metadata'), raw.fetch('serialization_metadata_sha256'),
        raw.fetch('serialization_metadata_raw_file'), raw.fetch('mark_file'), raw.fetch('mark_bytes'),
        raw.fetch('mark_sha256'), :attached)
      attached_contract!(generated.fetch('inventory'), raw.fetch('inventory'),
        File.binread(file!(File.join(active.fetch('path'), SIDECAR_PATH), "#{id} attached sidecar")))
      need!(generated.dig('attach', 'source_inventory') == generated['inventory'] &&
        generated.dig('attach', 'detached_inventory') == generated['inventory'],
        "#{id} detached inventory changed before ATTACH")
      need!(generated.dig('attached_inventory_contract', 'state') ==
        'generated_files_byte_preserved_with_exact_native_sidecar', "#{id} ATTACH inventory claim differs")
      true
    end

    def stage!(label, stage)
      need!(stage.is_a?(Hash) && @records.key?(label), "#{label} raw stage/record is missing")
      record = @records.fetch(label)
      expected = {
        'label' => label, 'classification' => record['process_classification'],
        'exit' => record['exit'], 'signal' => record['signal'],
        'stdout_file' => record['stdout_file'], 'stdout_bytes' => record['stdout_bytes'],
        'stdout_sha256' => record['stdout_sha256'], 'stderr_file' => record['stderr_file'],
        'stderr_bytes' => record['stderr_bytes'], 'stderr_sha256' => record['stderr_sha256'],
        'argv_file' => record['argv_file'], 'argv' => record['argv'],
        'stdin_file' => record['stdin_file'], 'stdin_bytes' => record['stdin_bytes'],
        'stdin_sha256' => record['stdin_sha256'], 'record_file' => "#{label}.json",
      }
      need!(stage == expected, "#{label} summary stage differs from its raw record")
      true
    end

    def sql_stdout!(label, lines)
      expected = lines.empty? ? ''.b : (lines.join("\n") + "\n").b
      need!(read_at(File.join(@root, 'invocations'), "#{label}.stdout") == expected,
        "#{label} raw native stdout differs")
      true
    end

    def stdout_lines(label)
      bytes = read_at(File.join(@root, 'invocations'), "#{label}.stdout")
      text = bytes.dup.force_encoding(Encoding::UTF_8)
      need!(text.valid_encoding? && text.end_with?("\n"), "#{label} stdout is not newline-terminated UTF-8")
      lines = text.split("\n", -1)
      lines.pop
      need!(lines.shift == PIN_LINE, "#{label} runtime pin output differs")
      [PIN_LINE] + lines
    end

    def native_schema!(id, physical, table)
      schema = M::SCHEMAS.fetch(M::CASE).map { |name, type| [name, type.gsub(/\s+/, '')] }
      need!(physical['state'] == 'observed' && physical['schema'] == schema &&
        physical['expected_schema'] == schema, "#{id} native schema differs")
      part = physical.fetch('part')
      path = part.fetch('path')
      table_path = physical.fetch('table_data_path')
      directory!(path, "#{id} active part")
      directory!(table_path.delete_suffix(File::SEPARATOR), "#{id} table data path")
      expected_row = [tag('part', id), table, W::PART_NAME, path + File::SEPARATOR, 'Compact', '8', '5']
      need!(File.dirname(path) == table_path.delete_suffix(File::SEPARATOR) &&
        File.basename(path) == W::PART_NAME && physical['active_parts'] == [expected_row] &&
        part['row'] == expected_row, "#{id} physical active part row/path differs")
      lines = stdout_lines("#{id}_schema_part")
      schema_tag = tag('schema', id)
      table_path_tag = tag('table_path', id)
      got_schema = lines.drop(1).take(schema.size).map { |line| line.split("\t", -1) }
      need!(got_schema.size == schema.size && got_schema.each_with_index.all? do |row, index|
        row.size == 3 && row[0] == schema_tag && row[1] == schema[index][0] && row[2].gsub(/\s+/, '') == schema[index][1]
      end, "#{id} native schema stdout differs")
      expected_tail = [expected_row.join("\t"), [table_path_tag, table_path].join("\t")]
      need!(lines.size == 1 + schema.size + expected_tail.size && lines.drop(1 + schema.size) == expected_tail,
        "#{id} schema/part/path stdout has extra or missing rows")
      true
    rescue KeyError, TypeError => e
      raise Error, "#{id} native schema evidence incomplete: #{e.message}"
    end

    def target_create_stdout!(id, target)
      table = target.fetch('table')
      path = target.fetch('data_path')
      lines = stdout_lines("#{id}_target_create")
      schema = M::SCHEMAS.fetch(M::CASE).map { |name, type| [name, type.gsub(/\s+/, '')] }
      expected_tag = tag('target_schema', id)
      rows = lines.drop(1).take(schema.size).map { |line| line.split("\t", -1) }
      need!(rows.size == schema.size && rows.each_with_index.all? do |row, index|
        row.size == 3 && row[0] == expected_tag && row[1] == schema[index][0] && row[2].gsub(/\s+/, '') == schema[index][1]
      end, "#{id} target schema stdout differs")
      path_row = lines.drop(1 + schema.size)
      target_path_stdout_rows!(id, path, path_row)
      directory!(path, "#{id} target data path")
      need!(table == "w282m_#{@table_token}_target_#{id}", "#{id} target table name differs")
      true
    rescue KeyError => e
      raise Error, "#{id} target create evidence incomplete: #{e.message}"
    end

    def target_path_stdout_rows!(id, path, rows)
      reported_path = path.end_with?(File::SEPARATOR) ? path : "#{path}#{File::SEPARATOR}"
      expected = [[tag('target_path', id), reported_path].join("\t")]
      need!(rows == expected, "#{id} target path stdout differs")
      true
    end

    def check_stdout!(id, check)
      need!(check['state'] == 'healthy', "#{id} native CHECK is not healthy")
      begin_tag = tag('check_begin', id)
      end_tag = tag('check_end', id)
      row = "#{W::PART_NAME}\t1\t"
      need!(check['rows'] == [row] && stdout_lines("#{id}_check") == [PIN_LINE, begin_tag, row, end_tag],
        "#{id} native CHECK summary/stdout differs")
      true
    end

    def validate_windows!(id, table, windows, attached)
      query_id = attached ? "#{id}_attached" : id
      need!(windows.is_a?(Hash) && windows.keys.sort == M::WINDOWS.keys.sort,
        "#{query_id} native window roster differs")
      @active_query_id = query_id
      M::WINDOWS.each_key do |window|
        entry = windows.fetch(window)
        label = "#{query_id}_values_#{window}"
        need!(entry['state'] == 'exact_values', "#{label} is not exact")
        rows = window_rows(window)
        actual_summary_rows = if window == 'eof'
                                rows
                              else
                                rows.map { |row| {'pk' => Integer(row[1], 10), 'signature' => row[2]} }
                              end
        need!(entry['rows'] == actual_summary_rows && entry['expected_rows'] == actual_summary_rows,
          "#{label} summary rows differ from the independent literal oracle")
        need!(window == 'eof' || entry['raw_rows'] == rows, "#{label} raw row summary differs")
        expected_stdout = ([PIN_LINE] + rows.map { |row| row.join("\t") }).join("\n") + "\n"
        need!(read_at(File.join(@root, 'invocations'), "#{label}.stdout") == expected_stdout.b,
          "#{label} raw native stdout differs from the Ruby literal signatures")
        sql = PIN_SQL + values_sql(query_id, table, window).b
        record = @records.fetch(label)
        need!(read_at(File.join(@root, 'invocations'), record.fetch('stdin_file')) == sql,
          "#{label} raw SQL differs from reconstructed window query")
      end
      true
    rescue KeyError, ArgumentError => e
      raise Error, "#{query_id} native window evidence incomplete: #{e.message}"
    ensure
      @active_query_id = nil
    end
    def helper_report!(id, mark, profile, report, action, part)
      expected_keys = %w[
        action data_mark_count format mark_format part_origin part_path public_reader_grid
        public_reader_mark_count public_reader_mark_rows reader_ordinary_profile_matches_requested
        recursive_windows row_count schema status string_profile
      ].sort
      need!(report.is_a?(Hash) && report.keys.sort == expected_keys, "#{id} helper report fields differ")
      origin = action == 'read' ? 'stock' : 'generated'
      schema = M::SCHEMAS.fetch(M::CASE).last.last.gsub(/\s+/, '')
      need!(report.values_at('format', 'action', 'mark_format', 'string_profile',
        'reader_ordinary_profile_matches_requested', 'status', 'row_count', 'data_mark_count',
        'part_origin', 'public_reader_grid', 'public_reader_mark_count', 'public_reader_mark_rows', 'part_path') ==
        [M::HELPER_FORMAT, action, mark, profile, true, 'ok', 8, 4, origin,
          'nonempty_data_marks', 4, PUBLIC_ROWS, part] && report['schema'].gsub(/\s+/, '') == schema,
        "#{id} helper reader profile or report envelope differs")
      windows = {'full' => literal_signatures, 'middle' => literal_signatures.drop(2).take(4),
        'last' => literal_signatures.drop(6).take(2), 'eof' => []}
      recursive = report.fetch('recursive_windows')
      need!(recursive.keys.sort == windows.keys.sort, "#{id} helper window roster differs")
      windows.each do |window, expected|
        actual = recursive.fetch(window)
        first, count = M::PHYSICAL_WINDOWS.fetch(window)
        need!(actual == {'signatures' => expected, 'first_mark' => first, 'mark_count' => count},
          "#{id}/#{window} helper recursive read differs from the Ruby literal oracle")
      end
      true
    rescue KeyError, TypeError, NoMethodError => e
      raise Error, "#{id} helper report incomplete: #{e.message}"
    end

    def helper_stdout!(label, report)
      bytes = read_at(File.join(@root, 'invocations'), "#{label}.stdout")
      parsed = JSON.parse(bytes)
      need!(bytes.lines.size == 1 && parsed == report, "#{label} raw helper stdout differs from its report")
      true
    rescue JSON::ParserError => e
      raise Error, "#{label} helper stdout is malformed: #{e.message}"
    end

    def expected_mrk4_sections(profile)
      streams = MRK4_STREAMS_BY_PROFILE.fetch(profile) do
        raise Error, "unknown W282 string profile #{profile.inspect}"
      end
      [['pk', ['pk']], [M::COLUMN, streams]]
    end

    def mrk4_sections!(id, profile, sections)
      expected = expected_mrk4_sections(profile)
      need!(sections == expected,
        "#{id} MRK4 source-inventory stream names, counts, or order differ for #{profile}")
      expected
    end

    def profile_for_case_id(id)
      profile = M::PROFILES.find do |candidate|
        M::MARK_FORMATS.any? do |mark|
          base = "#{M::CASE}_#{mark}_#{candidate}"
          id == base || id.start_with?(base + '_')
        end
      end
      need!(profile, "#{id} does not identify a pinned W282 profile")
      profile
    end

    def validate_part!(id, mark, path, inventory, snapshot, callback, parsed_metadata, metadata_sha,
                       metadata_file, mark_file, mark_bytes, mark_sha, origin)
      directory!(path, "#{id} part")
      prefix = part_prefix(origin, id)
      need!(path.start_with?(prefix), "#{id} part escaped its source tree")
      inv = inventory!(inventory, id)
      need!(disk_inventory(path) == inv, "#{id} current part inventory differs")
      safe = id.gsub(/[^a-zA-Z0-9_.-]/, '_')
      snapshot_name = "source-inventories/#{safe}.json"
      need!(snapshot.is_a?(Hash) && snapshot['inventory'] == inv &&
        snapshot['raw_prefix'] == "raw-records/#{safe}." && snapshot['inventory_file'] == snapshot_name,
        "#{id} snapshot references differ")
      snapshot_bytes = read_file(snapshot_name)
      persisted = JSON.parse(snapshot_bytes)
      need!(persisted['case_name'] == id && persisted['source_part_path'] == path &&
        persisted['inventory'] == inv && persisted['callback_roster'] == callback,
        "#{id} persisted snapshot differs from current part bytes")
      @expected_snapshots << snapshot_name

      metadata_raw = File.binread(file!(File.join(path, 'serialization.json'), "#{id} serialization metadata"))
      metadata = JSON.parse(metadata_raw)
      metadata_raw_name = "raw-records/#{safe}.serialization.json"
      need!(parsed_metadata == metadata && metadata_sha == sha(metadata_raw) && metadata_file == metadata_raw_name,
        "#{id} serialization metadata summary differs")
      snapshot_metadata = persisted.fetch('serialization_metadata')
      need!(snapshot_metadata['raw'] == metadata_raw && snapshot_metadata['raw_sha256'] == sha(metadata_raw) &&
        (snapshot_metadata['parsed'].nil? || snapshot_metadata['parsed'] == metadata),
        "#{id} persisted serialization metadata differs")
      need!(read_file(metadata_raw_name) == metadata_raw, "#{id} raw serialization metadata copy differs")

      inv.fetch('files').each do |item|
        relative = item.fetch('path')
        safe_relative!(relative, "#{id} inventory path")
        bytes = File.binread(file!(File.join(path, relative), "#{id}/#{relative}"))
        need!(bytes.bytesize == item['size'] && sha(bytes) == item['sha256'], "#{id}/#{relative} bytes differ from inventory")
        raw_name = "raw-records/#{safe}.#{relative}"
        need!(read_file(raw_name) == bytes, "#{id}/#{relative} raw copy differs")
        @expected_raw << raw_name
      end
      need!(mark_file == "data.#{mark}", "#{id} raw mark filename differs")
      mark_raw = File.binread(file!(File.join(path, mark_file), "#{id} #{mark_file}"))
      mark_entry = inv.fetch('files').find { |file| file['path'] == mark_file }
      need!(mark_entry && (!mark_bytes || mark_bytes == mark_raw.bytesize) &&
        (!mark_sha || mark_sha == sha(mark_raw)) && mark_entry['size'] == mark_raw.bytesize &&
        mark_entry['sha256'] == sha(mark_raw), "#{id} raw mark capture differs")

      slots = validate_callback!(id, mark, path, inv, callback)
      expected_slots = if mark == 'mrk3'
        2
      else
        1 + MRK4_STREAMS_BY_PROFILE.fetch(profile_for_case_id(id)).size
      end
      need!(slots == expected_slots, "#{id} #{mark} physical callback slot count differs")
      need!(plain_marks!(mark_raw, slots) == MARK_ROWS, "#{id} raw plain mark grid differs, including EOF")
      true
    rescue KeyError, JSON::ParserError => e
      raise Error, "#{id} part evidence incomplete: #{e.message}"
    end

    def validate_callback!(id, mark, path, inventory, callback)
      columns = M::SCHEMAS.fetch(M::CASE).map(&:first)
      if mark == 'mrk3'
        roster = columns.each_with_index.map { |column, index| [index, column, nil] }
        expected = {
          'state' => 'mrk3_single_unlabelled_slot_per_column', 'sections' => nil,
          'roster' => roster, 'text' => nil, 'sha256' => nil,
          'expected_low_cardinality_sites' => M::LC_SITE_DFS,
          'low_cardinality_prefix_events' => 'MRK3 has one physical slot per top-level column; nested callbacks are not individually named',
          'low_cardinality_prefix_event_basis' => 'no per-site MRK3 callback order is observed',
          'low_cardinality_prefix_slot_ordinals' => [],
        }
        need!(callback == expected && inventory['files'].none? { |file| file['path'] == 'columns_substreams.txt' },
          "#{id} MRK3 single unlabelled slot roster differs")
        return roster.size
      end

      name = 'columns_substreams.txt'
      bytes = File.binread(file!(File.join(path, name), "#{id} MRK4 callback roster"))
      entry = inventory['files'].find { |file| file['path'] == name }
      sections, roster = parse_mrk4(bytes, columns, id)
      mrk4_sections!(id, profile_for_case_id(id), sections)
      text = bytes.dup.force_encoding(Encoding::UTF_8).to_s
      streams = sections.flat_map { |_column, names| names }.select { |stream| stream.end_with?('.dict_prefix') }
      low_cardinality_prefix_roster!(streams)
      events = []
      sections.each do |column, names|
        names.each_with_index do |stream, index|
          next unless stream.end_with?('.dict_prefix')
          events << {'column' => column, 'stream' => stream, 'section_slot' => index}
        end
      end
      need!(events.size == M::LC_SITE_DFS.size, "#{id} MRK4 observed LowCardinality prefix slot count differs")
      inferred_events = events.each_with_index.map do |event, index|
        event.merge('inferred_site_dfs' => M::LC_SITE_DFS.fetch(index), 'observed_slot_ordinal' => index)
      end
      ordinals = events.map do |event|
        roster.index { |slot| slot[1] == event.fetch('column') && slot[2] == event.fetch('stream') }
      end
      need!(ordinals.all? && ordinals == ordinals.sort, "#{id} observed prefix slots are absent or reordered in physical roster")
      expected = {
        'state' => 'native_substream_callback_roster_observed', 'text' => text, 'sections' => sections,
        'roster' => roster, 'sha256' => sha(bytes), 'expected_low_cardinality_sites' => M::LC_SITE_DFS,
        'low_cardinality_prefix_events' => inferred_events,
        'low_cardinality_prefix_slot_ordinals' => ordinals, 'low_cardinality_prefix_event_basis' => PREFIX_EVENT_BASIS,
      }
      need!(entry && entry['sha256'] == sha(bytes) && callback == expected,
        "#{id} MRK4 raw callback roster differs; DFS labels remain inferred, not independent")
      saved = "source-inventories/#{id}.columns_substreams.txt"
      need!(read_file(saved) == bytes, "#{id} MRK4 source roster sidecar differs")
      @expected_snapshots << saved
      roster.size
    end

    def parse_mrk4(bytes, columns, label)
      text = bytes.dup.force_encoding(Encoding::UTF_8)
      need!(text.valid_encoding?, "#{label} MRK4 roster is invalid UTF-8")
      lines = text.split("\n", -1)
      need!(lines.pop == '' && lines.shift == 'columns substreams version: 1', "#{label} MRK4 roster header differs")
      header = /\A(0|[1-9][0-9]*) columns:\z/.match(lines.shift.to_s)
      need!(header && Integer(header[1], 10) == columns.size, "#{label} MRK4 column count differs")
      sections = []
      until lines.empty?
        match = /\A(0|[1-9][0-9]*) substreams for column `([a-z][a-z0-9_]*)`:\z/.match(lines.shift.to_s)
        need!(match, "#{label} MRK4 section is malformed")
        count = Integer(match[1], 10)
        need!(count.between?(1, 512) && lines.size >= count, "#{label} MRK4 section slot count is invalid")
        streams = count.times.map do
          item = /\A\t([A-Za-z0-9_.%]+)\z/.match(lines.shift.to_s)
          need!(item, "#{label} MRK4 stream name is malformed")
          item[1]
        end
        need!(streams.uniq == streams, "#{label} MRK4 section repeats a stream")
        sections << [match[2], streams]
      end
      need!(sections.map(&:first) == columns, "#{label} MRK4 section order differs from declared columns")
      flat = sections.flat_map { |column, streams| streams.map { |stream| [column, stream] } }
      [sections, flat.each_with_index.map { |(column, stream), index| [index, column, stream] }]
    end

    # This verifies the observed syntactic roster, not semantic DFS identities.
    # The separate bounded raw-byte check owns prefix extents; this auditor does
    # not decode JSON or infer which bytes belong to each LC site.
    def low_cardinality_prefix_roster!(streams)
      need!(streams.is_a?(Array) && streams.size == 6 && streams.sort == PREFIX_STREAMS.sort,
        'MRK4 observed .dict_prefix stream set differs, including the zero-occurrence lane')
      need!(streams.include?('recursive_lc_w282%2E4%2E2.dict_prefix'),
        'MRK4 observed roster omits the syntactic zero-occurrence prefix slot')
      true
    end

    def plain_marks!(bytes, slots, expected_rows: MARK_ROWS)
      need!(slots.is_a?(Integer) && slots.positive?, 'plain mark file has no physical slots')
      stride = slots * 16 + 8
      need!(bytes.bytesize == stride * expected_rows.size, 'plain mark byte length differs')
      cursor = 0
      marks = expected_rows.map do
        coordinates = slots.times.map do
          point = bytes.byteslice(cursor, 16).unpack('Q<Q<')
          cursor += 16
          point
        end
        rows = bytes.byteslice(cursor, 8).unpack1('Q<')
        cursor += 8
        [coordinates, rows]
      end
      need!(cursor == bytes.bytesize && marks.map(&:last) == expected_rows, 'raw mark row domains differ')
      slots.times do |slot|
        previous = nil
        marks.each do |coordinates, _rows|
          current = coordinates.fetch(slot)
          need!(previous.nil? || current[0] > previous[0] || (current[0] == previous[0] && current[1] >= previous[1]),
            'mark coordinates regress')
          previous = current
        end
      end
      marks.map(&:last)
    end

    def inventory!(inventory, label)
      need!(inventory.is_a?(Hash) && inventory.keys.sort == %w[files total_bytes] &&
        inventory['files'].is_a?(Array) && inventory['total_bytes'].is_a?(Integer), "#{label} inventory is malformed")
      files = inventory.fetch('files')
      paths = files.map do |file|
        need!(file.is_a?(Hash) && file.keys.sort == %w[path sha256 size] && file['size'].is_a?(Integer) &&
          file['size'] >= 0 && file['sha256'].is_a?(String) && file['sha256'].match?(/\A[0-9a-f]{64}\z/),
          "#{label} inventory entry is malformed")
        safe_relative!(file.fetch('path'), "#{label} part inventory path")
      end
      need!(paths == paths.uniq.sort && inventory['total_bytes'] == files.sum { |file| file.fetch('size') },
        "#{label} inventory paths/total differ")
      inventory
    end

    def disk_inventory(path)
      files = []
      total = 0
      Find.find(path) do |entry|
        next if entry == path
        stat = File.lstat(entry)
        need!(!stat.symlink?, "symlink in part tree: #{entry}")
        next if stat.directory?
        need!(stat.file? && stat.size <= MAX_FILE, "non-regular or oversized part file: #{entry}")
        relative = entry.delete_prefix(path + File::SEPARATOR)
        safe_relative!(relative, 'part inventory relative path')
        total += stat.size
        need!(files.size < 256 && total <= 128 * 1024 * 1024, 'part inventory exceeds bounds')
        files << {'path' => relative, 'size' => stat.size, 'sha256' => file_sha(entry, 'part file')}
      end
      {'files' => files.sort_by { |file| file['path'] }, 'total_bytes' => total}
    end

    def part_prefix(origin, id)
      case origin
      when :stock
        need!(expected_ids.include?(id), 'unknown stock part case id')
        File.join(@root, 'stores', id) + File::SEPARATOR
      when :generated
        base = id.delete_suffix('_generated')
        need!(id == "#{base}_generated" && expected_ids.include?(base), 'unknown generated part case id')
        File.join(@root, 'parts', base) + File::SEPARATOR
      when :attached
        base = id.delete_suffix('_attached')
        need!(id == "#{base}_attached" && expected_ids.include?(base), 'unknown attached part case id')
        File.join(@root, 'stores', "target_#{base}") + File::SEPARATOR
      else
        raise Error, "unknown part origin #{origin.inspect}"
      end
    end

    def attached_contract!(generated, attached, sidecar)
      source = inventory!(generated, 'generated')
      target = inventory!(attached, 'attached')
      source_files = source['files'].to_h { |file| [file['path'], file] }
      target_files = target['files'].to_h { |file| [file['path'], file] }
      need!(source_files.keys.all? { |path| target_files[path] == source_files[path] }, 'ATTACH changed or omitted a generated file')
      extra = target_files.keys - source_files.keys
      need!(extra == [SIDECAR_PATH] && target_files[SIDECAR_PATH] == SIDECAR_ENTRY &&
        sidecar == SIDECAR_BYTES && target['total_bytes'] == source['total_bytes'] + SIDECAR_BYTES.bytesize,
        'ATTACH inventory is not byte-preserving with exactly the pinned sidecar')
      true
    end

    def compare_directory!(name, expected)
      base = File.join(@root, name)
      directory!(base, name)
      actual = []
      Find.find(base) do |path|
        next if path == base
        stat = File.lstat(path)
        need!(!stat.symlink?, "symlink in #{name}")
        need!(!stat.directory?, "unexpected nested directory in #{name}")
        need!(stat.file?, "non-regular item in #{name}")
        relative = path.delete_prefix(base + File::SEPARATOR)
        safe_relative!(relative, "#{name} member")
        need!(!relative.include?('/'), "nested evidence file in #{name}")
        actual << relative
      end
      compare_directory_members!(name, actual, expected)
    end

    def compare_directory_members!(name, actual, expected)
      need!(%w[raw-records source-inventories].include?(name), "unknown evidence inventory directory #{name.inspect}")
      need!(actual.is_a?(Array) && expected.is_a?(Array), "#{name} inventory members are not arrays")
      relative_expected = expected.map do |reference|
        prefix = "#{name}/"
        need!(reference.is_a?(String) && reference.start_with?(prefix), "#{name} reference has the wrong root prefix")
        relative = reference.delete_prefix(prefix)
        safe_relative!(relative, "#{name} reference")
        need!(!relative.include?('/'), "nested #{name} reference")
        relative
      end
      need!(relative_expected.uniq == relative_expected, "#{name} expected inventory repeats a reference")
      actual.each do |relative|
        safe_relative!(relative, "#{name} member")
        need!(!relative.include?('/'), "nested evidence file in #{name}")
      end
      need!(actual.uniq == actual && actual.sort == relative_expected.sort,
        "#{name} has missing or unexpected evidence files")
      true
    end

    def sidecar_inventory!
      compare_directory!('raw-records', @expected_raw)
      compare_directory!('source-inventories', @expected_snapshots)
      true
    end

    def root_inventory!
      root_entries = Dir.children(@root)
      expected_directories = %w[invocations parts raw-records source-inventories stores]
      expected_directories.each do |name|
        directory!(File.join(@root, name), "evidence #{name}")
      end
      file!(File.join(@root, 'summary.md'), 'summary.md')
      store_entries = Dir.children(File.join(@root, 'stores'))
      part_entries = Dir.children(File.join(@root, 'parts'))
      root_inventory_contract!(root_entries, store_entries, part_entries, @mode)
      true
    end

    def root_inventory_contract!(root_entries, store_entries, part_entries, mode)
      need!(%i[stock_only full_matrix].include?(mode), "unknown root inventory mode #{mode.inspect}")
      expected_root = %w[invocations parts raw-records source-inventories stores summary.json summary.md]
      need!(root_entries.is_a?(Array) && root_entries.uniq == root_entries && root_entries.sort == expected_root.sort,
        'evidence root has missing or unexpected entries')
      ids = expected_ids
      expected_stores = mode == :full_matrix ? ids + ids.map { |id| "target_#{id}" } : ids
      need!(store_entries.is_a?(Array) && store_entries.uniq == store_entries && store_entries.sort == expected_stores.sort,
        mode == :full_matrix ? 'native target store inventory differs' : 'stock native store inventory differs')
      expected_parts = mode == :full_matrix ? ids : []
      need!(part_entries.is_a?(Array) && part_entries.uniq == part_entries && part_entries.sort == expected_parts.sort,
        mode == :full_matrix ? 'generated part directory inventory differs' : 'stock-only parts directory must be empty')
      true
    end

    def seed_mark_bytes(slots, rows)
      ''.b.tap do |bytes|
        rows.each_with_index do |count, mark|
          slots.times { |slot| bytes << [mark, slot].pack('Q<Q<') }
          bytes << [count].pack('Q<')
        end
      end
    end

    def seed_inventories
      files = [
        {'path' => 'data.mrk3', 'size' => 8, 'sha256' => sha('mark')},
        {'path' => 'serialization.json', 'size' => 2, 'sha256' => sha('{}')},
      ]
      generated = {'files' => files, 'total_bytes' => 10}
      attached_files = (files + [SIDECAR_ENTRY]).sort_by { |file| file['path'] }
      [generated, {'files' => attached_files, 'total_bytes' => 38}]
    end

    def helper_report_seed(mark, profile, action, part)
      origin = action == 'read' ? 'stock' : 'generated'
      windows = {'full' => literal_signatures, 'middle' => literal_signatures.drop(2).take(4),
        'last' => literal_signatures.drop(6).take(2), 'eof' => []}
      {
        'format' => M::HELPER_FORMAT, 'action' => action, 'mark_format' => mark,
        'string_profile' => profile, 'reader_ordinary_profile_matches_requested' => true,
        'status' => 'ok', 'part_path' => part, 'schema' => M::TYPE,
        'row_count' => 8, 'data_mark_count' => 4, 'part_origin' => origin,
        'public_reader_grid' => 'nonempty_data_marks', 'public_reader_mark_count' => 4,
        'public_reader_mark_rows' => PUBLIC_ROWS,
        'recursive_windows' => windows.to_h do |window, signatures|
          first_mark, mark_count = M::PHYSICAL_WINDOWS.fetch(window)
          [window, {'signatures' => signatures, 'first_mark' => first_mark, 'mark_count' => mark_count}]
        end,
      }
    end

    def window_rows(window)
      return [[tag('values', @active_query_id || 'stock_bulk', window), '0']] if window == 'eof'
      indexes = {'full' => (0...8).to_a, 'middle' => (2...6).to_a, 'last' => (6...8).to_a}.fetch(window)
      query_id = @active_query_id || 'stock_bulk'
      indexes.map { |index| [tag('values', query_id, window), (index + 1).to_s, literal_signatures.fetch(index)] }
    end

    def window_summary!(label, id, window, expected, actual)
      @active_query_id = id
      rows = window_rows(window)
      summary_rows = window == 'eof' ? rows : rows.map { |row| {'pk' => Integer(row[1], 10), 'signature' => row[2]} }
      need!(rows == expected && actual['rows'] == summary_rows && actual['expected_rows'] == summary_rows &&
        (window == 'eof' || actual['raw_rows'] == rows), "#{label} summary rows differ from literal oracle")
      true
    ensure
      @active_query_id = nil
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = {mode: nil, evidence_root: nil, self_test: false}
  parser = OptionParser.new do |opts|
    opts.banner = 'Usage: ruby scripts/verify_compact_low_cardinality_bulk_w282_capture.rb (--stock-only | --full-matrix) --evidence-root PATH'
    opts.on('--stock-only', 'Audit only the four stock native controls') do
      raise OptionParser::InvalidArgument, 'choose only one audit mode' if options[:mode]
      options[:mode] = :stock_only
    end
    opts.on('--full-matrix', 'Audit all stock, public-reader, generated, and attached cells') do
      raise OptionParser::InvalidArgument, 'choose only one audit mode' if options[:mode]
      options[:mode] = :full_matrix
    end
    opts.on('--evidence-root PATH', 'Existing captured evidence root') { |value| options[:evidence_root] = value }
    opts.on('--self-test', 'Run pure-Ruby positive and mutation-seed checks') { options[:self_test] = true }
  end
  parser.parse!

  if options[:self_test]
    abort(parser.to_s) if options[:mode] || options[:evidence_root]
    exit(VerifyCompactLowCardinalityBulkW282Capture::Auditor.self_test! ? 0 : 1)
  end
  unless options[:mode] && options[:evidence_root]
    warn parser.to_s
    exit 2
  end
  exit(VerifyCompactLowCardinalityBulkW282Capture::Auditor.new(
    options[:evidence_root], mode: options[:mode]).run ? 0 : 1)
end
