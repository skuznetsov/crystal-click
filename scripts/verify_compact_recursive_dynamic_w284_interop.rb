#!/usr/bin/env ruby
# W284 additive DEBUG/RELEASE helper-to-native interoperability driver.
# Preparation and Ruby-only self-tests never launch Crystal, ClickHouse, or a
# helper. Execution consumes only the explicitly pinned immutable inputs.

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'pathname'
require 'stringio'

require_relative 'verify_compact_recursive_dynamic_w284'
require_relative 'audit_compact_recursive_dynamic_w284_capture'

module VerifyCompactRecursiveDynamicW284Interop
  extend self

  W = VerifyCompactRecursiveDynamicW284
  A = AuditCompactRecursiveDynamicW284Capture
  FORMAT = 'compact_recursive_dynamic_w284_interop_v1'.freeze
  STATUS = 'debug_release_stock_read_generated_attach_reopen_exact_for_eight_cells'.freeze
  AUDITOR_SHA256 = '1db190f899211dde26d1a05e92324c353fab664a846ada52a5aaae72f7b742a7'.freeze
  STOCK_SUMMARY_SHA256 = '23000107f8c82dd13bc19fc575882837d691390f87b2409f72f58a9bc695e89d'.freeze
  STOCK_AUDIT_REPORT_SHA256 = '19a885b02950e258396c01139f8d07969226d7319e41aa11eb9119659c8a220d'.freeze
  STOCK_AUDIT_REPORT = File.join(A::REPORT_ROOT, 'compact-recursive-dynamic-w284-capture-audit-v3.json').freeze
  STOCK_SUMMARY = A::SUMMARY_DEFAULT
  TASK_ROOT = W::TASK_ROOT
  REPORT_NAME = 'w284-recursive-dynamic-interop.json'.freeze
  INPUT_MANIFEST_NAME = 'input_manifest.json'.freeze
  MAX_SUMMARY_BYTES = 4 * 1024 * 1024
  MAX_HELPER_OUTPUT_BYTES = 1024 * 1024
  MAX_HELPER_SECONDS = 60
  MAX_MUTANT_BYTES = 64 * 1024 * 1024
  SIDECAR_PATH = 'invalidated_system_columns.txt'.freeze
  SIDECAR_BYTES = "_block_offset\n_block_number\n".b.freeze
  SIDECAR_SHA256 = '7409424ab45090c1261e622f7423393905102e7e8cba36a6db88eb513ce1e06c'.freeze
  HELPER_FORMAT = 'compact_recursive_dynamic_w284_helper_v1'.freeze
  PUBLIC_MUTANT_ERROR_CLASSES = %w[
    CrystalClick::CorruptPartError
    CrystalClick::UnsupportedFormatError
  ].freeze
  HELPER_KEYS = %w[
    format action variant_discriminator_mode mark_format string_profile reader_ordinary_profile
    status part_path schema row_count data_mark_count part_origin public_reader_mark_rows
    dynamic_prefix_capture dynamic_statistics_placement recursive_windows
  ].sort.freeze
  BUILD_KINDS = %w[debug release].freeze
  CASE_IDS = W::CASES.map { |cell| cell.fetch(:id) }.freeze
  EXPECTED_PART_NAME = W::EXPECTED_PART_NAME
  EXPECTED_ROWS_PER_MARK = [2, 2, 2, 2].freeze
  WINDOWS = {
    'full' => {first_mark: 0, mark_count: 4},
    'middle' => {first_mark: 1, mark_count: 2},
    'last' => {first_mark: 3, mark_count: 1},
    'eof' => {first_mark: 4, mark_count: 0},
  }.freeze

  # Literal reader rows are deliberately repeated here, independently of the
  # Crystal fixture and its report. They encode the public-helper signature.
  HELPER_EXPECTED_ROWS = [
    '0[]',
    '1[14:UInt64:1040]',
    '2[15:String:6368696c6421;16:NULL]',
    '1[17:UInt64:1060]',
    '0[]',
    '0[]',
    '1[18:NULL]',
    '1[19:NULL]',
  ].freeze
  HELPER_EXPECTED_WINDOWS = {
    'full' => HELPER_EXPECTED_ROWS,
    'middle' => HELPER_EXPECTED_ROWS.drop(2).take(4),
    'last' => HELPER_EXPECTED_ROWS.drop(6).take(2),
    'eof' => [],
  }.freeze

  FROZEN_LOCAL_INPUTS = {
    'scripts/verify_compact_recursive_dynamic_w284.rb' => 'd8bb336239c172da97ca30b7519d77ab160ba5dcaea049ce4ec59249a465976b',
    'scripts/compact_recursive_dynamic_w284_helper.cr' => 'cd28fb724d1069285431f9c301db003623a4ca3c4a38c86311c4b0fe2e615801',
    'scripts/support/compact_recursive_dynamic_w284_fixture.cr' => '3f1ba0ab9f5a1565b73fb54e4573a3710a1e2975768a9efa8be8bfd6b5cbce29',
  }.freeze

  class Error < StandardError; end

  class Driver
    def initialize(options)
      @options = options
      @evidence_argument = options.fetch(:evidence_root)
      @summary_path = File.expand_path(options.fetch(:summary_path))
      @audit_report_path = File.expand_path(options.fetch(:audit_report_path))
      @helper_inputs = {
        'debug' => {path: options[:debug_helper], sha256: options[:debug_helper_sha256]},
        'release' => {path: options[:release_helper], sha256: options[:release_helper_sha256]},
      }
      @runner = W::Runner.new(
        evidence_root: @evidence_argument,
        source_root: W::SOURCE_ROOT,
        binary: W::BINARY,
      )
      @cells = {'debug' => {}, 'release' => {}}
      @mutants = {}
      @native_records = []
      @helper_records = []
      @runtime_before = nil
      @runtime_bytes_before = nil
      @source_revision_before = nil
      @source_hashes_before = nil
      @driver_sha_before = nil
      @root = nil
    end

    def print_plan
      planned = BUILD_KINDS.to_h do |build_kind|
        helper = @helper_inputs.fetch(build_kind)
        helper_path = helper.fetch(:path) || "<#{build_kind.upcase}_HELPER_PATH>"
        cells = W::CASES.map do |cell|
          id = cell.fetch(:id)
          part_path = File.join(TASK_ROOT, 'stock-first', 'cases', id, 'store', 'store', '<disk>', '<part-id>', EXPECTED_PART_NAME)
          target_store = File.join(@evidence_argument, build_kind, 'cases', id, 'native', 'store')
          target_table = target_table_name(build_kind, id)
          create_sql = target_create_sql(build_kind, cell)
          attach_sql = native_consumer_sql(target_table, 'attach')
          reopen_sql = native_consumer_sql(target_table, 'reopen')
          {
            id: id,
            stock_helper_argv: [helper_path, 'read', cell.fetch(:mode), cell.fetch(:mark), cell.fetch(:profile), part_path],
            generated_helper_argv: [helper_path, 'write', cell.fetch(:mode), cell.fetch(:mark), cell.fetch(:profile),
              File.join(@evidence_argument, build_kind, 'parts', id)],
            native_argv: @runner.send(:native_argv, target_store),
            target_table: target_table,
            native_sql: {
              empty_target_create: {bytes: create_sql.bytesize, sha256: Digest::SHA256.hexdigest(create_sql)},
              attach_check_windows: {bytes: attach_sql.bytesize, sha256: Digest::SHA256.hexdigest(attach_sql)},
              reopen_check_windows: {bytes: reopen_sql.bytesize, sha256: Digest::SHA256.hexdigest(reopen_sql)},
            },
          }
        end
        [build_kind, {
          helper_path: helper_path,
          helper_sha256: helper.fetch(:sha256) || "<#{build_kind.upcase}_HELPER_SHA256>",
          cells: cells,
          public_mrk4_coordinate_mutant: [helper_path, 'read', 'basic', 'mrk4', 's0',
            File.join(@evidence_argument, build_kind, 'mutants', 'basic_mrk4_s0', EXPECTED_PART_NAME)],
        }]
      end
      plan = {
        format: FORMAT,
        status: 'plan_only_no_helper_or_native_execution',
        evidence_root: @evidence_argument,
        stock_capture: {summary: @summary_path, summary_sha256: STOCK_SUMMARY_SHA256,
          audit_report: @audit_report_path, audit_report_sha256: STOCK_AUDIT_REPORT_SHA256},
        source_pin: {root: W::SOURCE_ROOT, revision: W::SOURCE_REVISION},
        runtime_pin: W::RUNTIME_PIN.merge(binary: W::BINARY),
        helper_inputs: planned,
        topology: {
          build_kinds: BUILD_KINDS,
          immutable_stock_helper_reads: CASE_IDS.size * BUILD_KINDS.size,
          generated_helper_writes: CASE_IDS.size * BUILD_KINDS.size,
          copied_public_helper_mutants: BUILD_KINDS.size,
          native_processes: CASE_IDS.size * BUILD_KINDS.size * 3,
          total_helper_processes: CASE_IDS.size * BUILD_KINDS.size * 2 + BUILD_KINDS.size,
          total_processes: CASE_IDS.size * BUILD_KINDS.size * 3 + CASE_IDS.size * BUILD_KINDS.size * 2 + BUILD_KINDS.size,
          order: 'stock read; generated write; native empty target create; detached copy; native ATTACH/CHECK/all four literal windows; separate native reopen/CHECK/all four literal windows; public-helper coordinate mutant',
        },
        literal_helper_windows: HELPER_EXPECTED_WINDOWS,
        native_windows: W::EXPECTED_WINDOWS,
        resource_policy: {
          max_parallel_processes: 1,
          native_timeout_seconds: W::PROCESS_TIMEOUT_SECONDS,
          helper_timeout_seconds: MAX_HELPER_SECONDS,
          streams_bounded_during_read: true,
          native_process_group: 'inherits outer unchanged run_safe process group; no pgroup is created',
          timeout_boundary: 'PID-specific TERM then KILL; only the unchanged outer run_safe guard owns whole-group cleanup',
          no_execution_authorization_embedded: true,
        },
        claim_boundary: 'Only the exact W284 schema, eight pinned stock captures, two explicitly pinned helper binaries, and BASIC/COMPACT × MRK3/MRK4 × S0/S1 cells are in scope; no broader Dynamic/JSON layout claim.',
      }
      puts JSON.pretty_generate(plan)
      true
    end

    def self_test
      tests = []
      positive_helper = VerifyCompactRecursiveDynamicW284Interop.synthetic_helper_report(
        'read', 'stock', '/stock/all_1_1_0')
      validate_helper_report!(positive_helper, action: 'read', origin: 'stock', cell: W::CASES.first,
        part_path: '/stock/all_1_1_0')
      tests << 'independent-literal-helper-windows-positive'
      mutant_helper = Marshal.load(Marshal.dump(positive_helper))
      mutant_helper.fetch('recursive_windows').fetch('full').fetch('signatures')[1] = 'changed'
      reject!('mutated helper literal window') do
        validate_helper_report!(mutant_helper, action: 'read', origin: 'stock', cell: W::CASES.first,
          part_path: '/stock/all_1_1_0')
      end
      tests << 'helper-window-mutant-negative'

      check_runner = @runner
      expected_check = "__W284_CHECK_BEGIN__attach__\n#{EXPECTED_PART_NAME}\t1\t\n__W284_CHECK_END__attach__\n"
      check_runner.send(:validate_check_result!, 'self-test', 'attach', expected_check, EXPECTED_PART_NAME)
      tests << 'native-check-exact-row-positive'
      ["__W284_CHECK_BEGIN__attach__\n#{EXPECTED_PART_NAME}\t0\t\n__W284_CHECK_END__attach__\n",
       "__W284_CHECK_BEGIN__attach__\n__W284_CHECK_END__attach__\n",
       "__W284_CHECK_BEGIN__attach__\n#{EXPECTED_PART_NAME}\t1\t\n#{EXPECTED_PART_NAME}\t1\t\n__W284_CHECK_END__attach__\n"].each_with_index do |bad, index|
        reject!("CHECK mutant #{index}") do
          check_runner.send(:validate_check_result!, 'self-test', 'attach', bad, EXPECTED_PART_NAME)
        end
      end
      tests << 'native-check-false-empty-duplicate-mutants-negative'

      expected_windows = W::WINDOWS.to_h do |window, _predicate|
        marker = window == 'eof' ? '__W284_EOF__' : "__W284_VALUES_#{window}__"
        lines = if window == 'eof'
          ["#{marker}\t0"]
        else
          W::EXPECTED_WINDOWS.fetch(window).map do |signature|
            pk, body = signature.split('|', 2)
            [marker, pk, body].join("\t")
          end
        end
        [window, lines]
      end
      native_windows = expected_windows.values.flatten.join("\n") + "\n"
      check_runner.send(:validate_windows!, 'self-test', native_windows)
      tests << 'native-four-window-literals-positive'
      changed_window = native_windows.sub('14:UInt64:U1040', '14:UInt64:U1041')
      reject!('native window literal mutant') do
        check_runner.send(:validate_windows!, 'self-test', changed_window)
      end
      tests << 'native-window-literal-mutant-negative'

      attach_table = target_table_name('debug', 'basic_mrk4_s0')
      attach_sql = native_consumer_sql(attach_table, 'attach')
      reopen_sql = native_consumer_sql(attach_table, 'reopen')
      attach_statement = "ALTER TABLE default.#{attach_table} ATTACH PART '#{EXPECTED_PART_NAME}';"
      raise Error, 'actual ATTACH SQL does not contain exactly one target-part ATTACH' unless
        attach_sql.lines.map(&:chomp).count(attach_statement) == 1
      raise Error, 'actual reopen SQL unexpectedly contains an ATTACH statement' if
        reopen_sql.lines.any? { |line| line.include?('ATTACH PART') }
      raise Error, 'actual ATTACH SQL places CHECK before ATTACH' unless
        attach_sql.index(attach_statement) < attach_sql.index('__W284_CHECK_BEGIN__attach__')
      tests << 'actual-attach-once-and-reopen-no-attach-sql-positive'

      seed = {files: [{relative_path: 'data.bin', bytes: 3, sha256: Digest::SHA256.hexdigest('abc')}],
        total_bytes: 3, file_count: 1}
      attached = Marshal.load(Marshal.dump(seed))
      attached[:files] << {relative_path: SIDECAR_PATH, bytes: SIDECAR_BYTES.bytesize,
        sha256: SIDECAR_SHA256}
      attached[:files].sort_by! { |entry| entry.fetch(:relative_path) }
      attached[:total_bytes] += SIDECAR_BYTES.bytesize
      attached[:file_count] += 1
      attached_inventory_contract!(seed, attached, SIDECAR_BYTES)
      tests << 'byte-preserving-attach-plus-pinned-sidecar-positive'
      wrong_sidecar = SIDECAR_BYTES.sub('_block_number', '_block_offset')
      reject!('wrong sidecar') { attached_inventory_contract!(seed, attached, wrong_sidecar) }
      extra = Marshal.load(Marshal.dump(attached))
      extra[:files] << {relative_path: 'unexpected', bytes: 0, sha256: Digest::SHA256.hexdigest('')}
      reject!('unexpected attached file') { attached_inventory_contract!(seed, extra, SIDECAR_BYTES) }
      tests << 'sidecar-byte-and-extra-file-mutants-negative'

      bounded_stream = StringIO.new('abcdef'.b)
      bounded_reader, bounded_state, bounded_lock = start_bounded_reader(bounded_stream, limit: 3)
      bounded = finish_bounded_reader(bounded_reader, bounded_stream, bounded_state, bounded_lock, 'self-test stdout')
      raise Error, 'bounded helper stream did not retain exactly the cap' unless
        bounded.fetch(:bytes) == 'abc'.b && bounded.fetch(:observed_bytes) == 6 && bounded.fetch(:truncated)
      zero_stream = StringIO.new('x'.b)
      zero_reader, zero_state, zero_lock = start_bounded_reader(zero_stream, limit: 0)
      zero_bounded = finish_bounded_reader(zero_reader, zero_stream, zero_state, zero_lock, 'self-test zero-cap stdout')
      raise Error, 'zero-cap helper stream was not bounded' unless
        zero_bounded.fetch(:bytes).empty? && zero_bounded.fetch(:observed_bytes) == 1 && zero_bounded.fetch(:truncated)
      tests << 'bounded-stream-cap-and-zero-cap-positive'

      geometry = {'global_slot_count' => 12, 'record_words' => 25}
      synthetic = Array.new(80, 0).pack('Q<*')
      synthetic[55 * 8, 8] = [11].pack('Q<')
      mutation = mutate_coordinate_bytes(synthetic, geometry, mark_index: 2, slot_index: 2)
      raise Error, 'coordinate mutation byte offset differs' unless mutation.fetch(:byte_offset) == 440
      raise Error, 'coordinate mutation before/after differs' unless
        mutation.fetch(:coordinate_before) == [0, 11] && mutation.fetch(:coordinate_after) == [0, 12]
      raise Error, 'coordinate mutation changed more than the expected byte' unless mutation.fetch(:changed_bytes).size == 1
      raise Error, 'coordinate mutation omitted the exact copied bytes' unless
        mutation.fetch(:bytes).bytesize == synthetic.bytesize && mutation.fetch(:bytes) != synthetic
      tests << 'MRK4-coordinate-copy-mutant-byte-accounting-positive'
      raise Error, 'matrix process count differs' unless planned_process_counts == {
        native: 48, helper: 34, total: 82,
      }
      tests << 'debug-release-finite-process-topology-positive'
      stock = load_and_audit_stock!
      CASE_IDS.each do |id|
        raise Error, "stock case envelope lookup differs for #{id}" unless audited_stock_case(stock, id) == stock.fetch(:report).fetch('cells').fetch(id)
      end
      mutant_case = audited_stock_case(stock, 'basic_mrk4_s0')
      raise Error, 'stock mutant case is not the audited exact MRK4 case' unless
        mutant_case.fetch('mark_format') == 'mrk4' && mutant_case.fetch('mode') == 'basic'
      reject!('stock lookup from outer metadata hash') { audited_stock_case(stock.reject { |key, _| key == :case_data }, 'basic_mrk4_s0') }
      verify_inventory_matches_auditor!(mutant_case.fetch('part_path'), mutant_case.fetch('part_inventory'),
        'self-test live immutable stock inventory')
      tests << 'actual-stock-audit-envelope-lookups-and-live-inventory-normalization-positive'
      changed_stock = Marshal.load(Marshal.dump(mutant_case.fetch('part_inventory')))
      changed_stock.fetch('files').first['bytes'] += 1
      reject!('live stock inventory byte-mutant') do
        verify_inventory_matches_auditor!(mutant_case.fetch('part_path'), changed_stock,
          'self-test mutated stock inventory')
      end
      tests << 'live-stock-inventory-mutant-negative'

      accepted_error = validate_public_helper_mutant_error!({
        'format' => HELPER_FORMAT, 'status' => 'error',
        'error_class' => 'CrystalClick::CorruptPartError', 'error' => 'invalid Dynamic structure coordinate',
      }, 'self-test')
      raise Error, 'expected public reader corruption class was not preserved' unless
        accepted_error.fetch(:error_class) == 'CrystalClick::CorruptPartError'
      accepted_unsupported_error = validate_public_helper_mutant_error!({
        'format' => HELPER_FORMAT, 'status' => 'error',
        'error_class' => 'CrystalClick::UnsupportedFormatError', 'error' => 'unsupported mark coordinate',
      }, 'self-test')
      raise Error, 'expected public reader unsupported-format class was not preserved' unless
        accepted_unsupported_error.fetch(:error_class) == 'CrystalClick::UnsupportedFormatError'
      reject!('unrelated public-helper crash class') do
        validate_public_helper_mutant_error!({
          'format' => HELPER_FORMAT, 'status' => 'error',
          'error_class' => 'NoMethodError', 'error' => 'unrelated crash',
        }, 'self-test')
      end
      tests << 'public-mutant-allowed-corruption-unsupported-classes-and-unrelated-crash-negative'

      complete_cells = BUILD_KINDS.to_h do |build_kind|
        [build_kind, CASE_IDS.to_h { |id| [id, {cell: {id: id}}] }]
      end
      complete_mutants = BUILD_KINDS.to_h { |build_kind| [build_kind, {status: 'fixture'}] }
      validate_completion_state!(cells: complete_cells, mutants: complete_mutants,
        native_count: 48, helper_count: 34)
      tests << 'exact-completion-rosters-and-process-counts-positive'
      missing_cell = Marshal.load(Marshal.dump(complete_cells))
      missing_cell.fetch('debug').delete(CASE_IDS.first)
      reject!('completion missing cell') do
        validate_completion_state!(cells: missing_cell, mutants: complete_mutants,
          native_count: 48, helper_count: 34)
      end
      reject!('completion wrong native count') do
        validate_completion_state!(cells: complete_cells, mutants: complete_mutants,
          native_count: 47, helper_count: 34)
      end
      reject!('completion wrong helper count') do
        validate_completion_state!(cells: complete_cells, mutants: complete_mutants,
          native_count: 48, helper_count: 33)
      end
      tests << 'missing-cell-and-wrong-process-count-mutants-negative'
      puts "W284 interop Ruby-only self-test passed: cases=#{tests.size}; #{tests.join(',')}; no filesystem writes or subprocesses"
      true
    rescue StandardError => error
      warn "W284 interop Ruby-only self-test failed: #{error.class}: #{error.message}"
      false
    end

    def run
      @root = validate_evidence_root!(@evidence_argument)
      @driver_sha_before = sha_file(File.expand_path(__FILE__))
      validate_inputs_before!
      stock = load_and_audit_stock!
      helpers = validate_helpers_before!
      write_exclusive(File.join(@root, INPUT_MANIFEST_NAME), JSON.pretty_generate(input_manifest(stock, helpers)) + "\n")

      BUILD_KINDS.each do |build_kind|
        helper = helpers.fetch(build_kind)
        build_root = make_directory!(File.join(@root, build_kind))
        make_directory!(File.join(build_root, 'cases'))
        make_directory!(File.join(build_root, 'parts'))
        W::CASES.each do |cell|
          id = cell.fetch(:id)
          @cells.fetch(build_kind)[id] = run_cell!(build_kind, helper, cell,
            audited_stock_case(stock, id), build_root)
        end
        @mutants[build_kind] = run_coordinate_mutant!(build_kind, helper,
          audited_stock_case(stock, 'basic_mrk4_s0'), build_root)
      end

      validate_completion_state!(cells: @cells, mutants: @mutants,
        native_count: @native_records.size, helper_count: @helper_records.size)
      validate_inputs_after!(helpers)
      validate_stock_unchanged!(stock)
      result = result_document(stock, helpers)
      write_exclusive(File.join(@root, REPORT_NAME), JSON.pretty_generate(result) + "\n")
      puts "W284 interop passed: builds=#{BUILD_KINDS.join(',')} cells_per_build=#{CASE_IDS.size} native_processes=#{@native_records.size} helper_processes=#{@helper_records.size} report=#{File.join(@root, REPORT_NAME)}"
      true
    rescue StandardError => error
      @fatal_error = "#{error.class}: #{error.message}"
      persist_inconclusive(error)
      warn "W284 interop inconclusive; no matrix qualification claimed: #{@fatal_error}"
      false
    end

    private

    def fail!(message)
      raise Error, "W284 interop: #{message}"
    end

    def reject!(label)
      yield
      fail!("#{label} unexpectedly passed")
    rescue StandardError => error
      raise if error.is_a?(Error) && error.message.end_with?("#{label} unexpectedly passed")
    end

    def planned_process_counts
      {
        native: CASE_IDS.size * BUILD_KINDS.size * 3,
        helper: CASE_IDS.size * BUILD_KINDS.size * 2 + BUILD_KINDS.size,
        total: CASE_IDS.size * BUILD_KINDS.size * 5 + BUILD_KINDS.size,
      }
    end

    def audited_stock_case(stock, id)
      case_data = stock.fetch(:case_data)
      fail!("audited stock case is absent from the sealed case-data envelope: #{id}") unless case_data.is_a?(Hash)
      case_data.fetch(id)
    rescue KeyError => error
      raise Error, "W284 interop: audited stock case lookup failed for #{id}: #{error.message}"
    end

    def validate_completion_state!(cells:, mutants:, native_count:, helper_count:)
      expected_ids = CASE_IDS.sort
      fail!('completion build-kind roster differs') unless cells.is_a?(Hash) && cells.keys.sort == BUILD_KINDS.sort
      cells.each do |build_kind, completed|
        fail!("#{build_kind} completion cell roster differs") unless
          completed.is_a?(Hash) && completed.keys.sort == expected_ids
        completed.each do |id, result|
          fail!("#{build_kind}/#{id} completion record identity differs") unless
            result.is_a?(Hash) && result.dig(:cell, :id) == id
        end
      end
      fail!('completion public-mutant build-kind roster differs') unless
        mutants.is_a?(Hash) && mutants.keys.sort == BUILD_KINDS.sort
      observed = {native: native_count, helper: helper_count, total: native_count + helper_count}
      fail!("completion process counts differ: #{observed.inspect}") unless observed == planned_process_counts
      true
    end

    def validate_evidence_root!(path)
      fail!('evidence root path is required') unless path.is_a?(String) && !path.empty?
      task_root = File.realpath(TASK_ROOT)
      raise Error, 'task root is not the direct W284 child of the approved external SSD cache' unless
        File.dirname(task_root) == File.join(File.realpath(W::SSD_ALIAS), 'cache') &&
        File.basename(task_root) == 'crystal-click-w284.9Nzwqc'
      fail!('W284 task root is not on the approved external SSD') if File.stat(task_root).dev == File.stat('/').dev
      expanded = File.expand_path(path)
      stat = File.lstat(expanded)
      fail!('evidence root may not be a symlink') if stat.symlink?
      real = File.realpath(expanded)
      fail!('evidence root must be a direct child of the W284 SSD task root') unless File.dirname(real) == task_root
      fail!('evidence root must be a current-user-owned directory on the task SSD') unless
        stat.directory? && stat.uid == Process.uid && stat.dev == File.stat(task_root).dev
      fail!('evidence root must be empty') unless Dir.children(real).empty?
      real
    rescue Errno::ENOENT
      raise Error, 'evidence root, W284 task root, or approved SSD mount is missing'
    end

    def validate_inputs_before!
      @source_root = File.realpath(W::SOURCE_ROOT)
      @source_revision_before = @runner.send(:git_revision, @source_root)
      fail!('pinned ClickHouse source revision differs') unless @source_revision_before == W::SOURCE_REVISION
      @source_hashes_before = local_source_hashes
      @driver_sha_before = sha_file(File.expand_path(__FILE__))
      fail!('W284 offline auditor code hash differs from the independently reviewed pin') unless
        sha_file(File.expand_path('audit_compact_recursive_dynamic_w284_capture.rb', __dir__)) == AUDITOR_SHA256
      @runtime_path = File.realpath(W::BINARY)
      fail!('pinned runtime binary path differs') unless File.expand_path(W::BINARY) == W::BINARY
      runtime_stat = File.stat(@runtime_path)
      fail!('pinned ClickHouse runtime is not an executable regular file') unless runtime_stat.file? && File.executable?(@runtime_path)
      @runtime_before = sha_file(@runtime_path)
      @runtime_bytes_before = runtime_stat.size
      fail!('full runtime SHA differs from the W284 pin') unless @runtime_before == W::RUNTIME_PIN.fetch(:sha256)
      fail!('full runtime byte size differs from the W284 pin') unless @runtime_bytes_before == W::RUNTIME_PIN.fetch(:bytes)
      true
    rescue Errno::ENOENT
      raise Error, 'pinned source or runtime is missing'
    end

    def local_source_hashes
      W::INPUT_SOURCE_PATHS.to_h do |path|
        expected = FROZEN_LOCAL_INPUTS.fetch(Pathname.new(path).relative_path_from(Pathname.new(W::REPO_ROOT)).to_s)
        fail!("frozen local source is missing or symlinked: #{path}") unless File.file?(path) && !File.symlink?(path)
        observed = sha_file(path)
        fail!("frozen local source SHA differs: #{path}") unless observed == expected
        [path, observed]
      end
    end

    def validate_inputs_after!(helpers)
      source_revision = @runner.send(:git_revision, @source_root)
      fail!('pinned source revision changed during interop') unless source_revision == @source_revision_before
      source_hashes = local_source_hashes
      fail!('W284 frozen local source bytes changed during interop') unless source_hashes == @source_hashes_before
      runtime_after = sha_file(@runtime_path)
      runtime_bytes_after = File.size(@runtime_path)
      fail!('full runtime changed during interop') unless
        runtime_after == @runtime_before && runtime_bytes_after == @runtime_bytes_before
      driver_after = sha_file(File.expand_path(__FILE__))
      fail!('interop driver changed during execution') unless driver_after == @driver_sha_before
      helpers.each do |build_kind, helper|
        fail!("#{build_kind} helper bytes changed during interop") unless sha_file(helper.fetch(:path)) == helper.fetch(:sha256)
      end
      @source_revision_after = source_revision
      @source_hashes_after = source_hashes
      @runtime_after = runtime_after
      @runtime_bytes_after = runtime_bytes_after
      @driver_sha_after = driver_after
      true
    end

    def validate_helpers_before!
      BUILD_KINDS.to_h do |build_kind|
        input = @helper_inputs.fetch(build_kind)
        path = input.fetch(:path)
        expected_sha = input.fetch(:sha256)
        fail!("explicit #{build_kind} helper path and SHA-256 are required") unless
          path.is_a?(String) && !path.empty? && expected_sha.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(expected_sha)
        expanded = File.expand_path(path)
        stat = File.lstat(expanded)
        fail!("#{build_kind} helper may not be a symlink") if stat.symlink?
        real = File.realpath(expanded)
        fail!("#{build_kind} helper must be a canonical absolute path on the W284 task SSD") unless
          expanded == real && stat.file? && File.executable?(real) && stat.dev == File.stat(File.realpath(TASK_ROOT)).dev
        observed = sha_file(real)
        fail!("#{build_kind} helper SHA differs from its explicit pin") unless observed == expected_sha
        [build_kind, {path: real, sha256: observed, bytes: stat.size}]
      end
    rescue Errno::ENOENT
      raise Error, 'one of the explicit precompiled helpers is missing'
    end

    def load_and_audit_stock!
      summary_bytes = read_bounded_file(@summary_path, MAX_SUMMARY_BYTES, 'stock summary')
      fail!('stock summary SHA differs from the immutable W284 capture') unless Digest::SHA256.hexdigest(summary_bytes) == STOCK_SUMMARY_SHA256
      fail!('stock summary must resolve to the exact immutable W284 summary') unless
        File.realpath(@summary_path) == File.realpath(STOCK_SUMMARY)
      report_bytes = read_bounded_file(@audit_report_path, MAX_SUMMARY_BYTES, 'offline audit report')
      fail!('all-cell offline report SHA differs from the reviewed W284 audit') unless
        Digest::SHA256.hexdigest(report_bytes) == STOCK_AUDIT_REPORT_SHA256
      fail!('audit report path is not the pinned v3 report') unless File.realpath(@audit_report_path) == File.realpath(STOCK_AUDIT_REPORT)
      summary = JSON.parse(summary_bytes)
      report = JSON.parse(report_bytes)
      fail!('offline report format/status differs') unless report['format'] == A::FORMAT &&
        report['status'] == 'offline_dynamic_v3_prefix_audit_passed_for_eight_stock_cells'
      fail!('offline report summary identity differs') unless report.dig('summary', 'sha256') == STOCK_SUMMARY_SHA256
      fail!('captured summary status is not the exact stock-only baseline') unless
        summary['status'] == 'stock_sql_values_and_raw_part_inventory_exact_prefix_unparsed'
      fail!('stock summary cell roster differs') unless summary.fetch('cells').keys.sort == CASE_IDS.sort
      fail!('offline report cell roster differs') unless report.fetch('cells').keys.sort == CASE_IDS.sort
      audited = CASE_IDS.to_h do |case_id|
        cell = A.audit_case(summary_path: @summary_path, case_id: case_id)
        fail!("single-case audit disagrees with the pinned eight-cell report for #{case_id}") unless cell == report.fetch('cells').fetch(case_id)
        [case_id, cell]
      end
      {summary_bytes: summary_bytes.bytesize, summary_sha256: STOCK_SUMMARY_SHA256,
       report_bytes: report_bytes.bytesize, report_sha256: STOCK_AUDIT_REPORT_SHA256,
       summary_path: File.realpath(@summary_path), report_path: File.realpath(@audit_report_path),
       case_data: audited, report: report}
    rescue JSON::ParserError, KeyError => error
      fail!("stock capture metadata is invalid: #{error.class}: #{error.message}")
    end

    def validate_stock_unchanged!(stock)
      fail!('stock summary changed during interop') unless
        Digest::SHA256.file(stock.fetch(:summary_path)).hexdigest == STOCK_SUMMARY_SHA256
      fail!('offline capture audit report changed during interop') unless
        Digest::SHA256.file(stock.fetch(:report_path)).hexdigest == STOCK_AUDIT_REPORT_SHA256
      CASE_IDS.each do |case_id|
        fresh = A.audit_case(summary_path: stock.fetch(:summary_path), case_id: case_id)
        fail!("immutable stock part or case ledger changed during interop: #{case_id}") unless
          fresh == stock.fetch(:case_data).fetch(case_id)
      end
      true
    end

    def input_manifest(stock, helpers)
      {
        format: 'compact_recursive_dynamic_w284_interop_inputs_v1',
        evidence_root: @root,
        source_pin: {root: @source_root, revision: @source_revision_before},
        runtime_pin: W::RUNTIME_PIN.merge(binary: @runtime_path, sha256_before: @runtime_before,
          bytes_before: @runtime_bytes_before),
        local_source_sha256_before: @source_hashes_before,
        driver_sha256_before: @driver_sha_before,
        offline_auditor_sha256: AUDITOR_SHA256,
        stock_capture: stock.reject { |key, _| key == :case_data || key == :report },
        helper_pins: helpers,
        expected_process_topology: planned_process_counts,
        independent_helper_window_literals: HELPER_EXPECTED_WINDOWS,
        scope: 'two separately pinned precompiled helpers; exact eight captured W284 cases; no source edits or build during this driver',
        process_group_policy: 'all direct children inherit the unchanged outer run_safe process group; this driver never requests pgroup or creates descendants',
      }
    end

    def run_cell!(build_kind, helper, cell, stock_cell, build_root)
      id = cell.fetch(:id)
      case_root = make_directory!(File.join(build_root, 'cases', id))
      stock_part = stock_cell.fetch('part_path')
      expected_inventory = stock_cell.fetch('part_inventory')
      verify_inventory_matches_auditor!(stock_part, expected_inventory, "#{build_kind}/#{id} stock")
      stock_read = run_helper_success!(build_kind, helper, cell, 'read', 'stock', stock_part,
        File.join(case_root, 'helper-stock'))
      verify_inventory_matches_auditor!(stock_part, expected_inventory, "#{build_kind}/#{id} post-stock-read")

      generated_part = File.join(build_root, 'parts', id)
      fail!("generated part path already exists: #{generated_part}") if File.exist?(generated_part) || File.symlink?(generated_part)
      generated_write = run_helper_success!(build_kind, helper, cell, 'write', 'generated', generated_part,
        File.join(case_root, 'helper-generated'))
      generated_inventory = @runner.send(:inventory_part, generated_part)
      fail!("#{build_kind}/#{id} generated part tree is empty") if generated_inventory.fetch(:file_count).zero?
      fail!("#{build_kind}/#{id} helper report omitted generated source part path") unless generated_write.fetch('part_path') == generated_part

      target = create_empty_target!(build_kind, cell, case_root)
      detached = copy_to_detached!(build_kind, id, generated_part, generated_inventory, target)
      attached = attach_and_check!(build_kind, cell, id, case_root, target, generated_inventory)
      reopened = reopen_and_check!(build_kind, cell, id, case_root, target, generated_inventory, attached.fetch(:active_inventory))
      fail!("#{build_kind}/#{id} generated source part changed after native consumers") unless
        @runner.send(:inventory_part, generated_part) == generated_inventory
      {
        cell: cell,
        stock_part: stock_part,
        stock_inventory: expected_inventory,
        public_stock_read: stock_read,
        generated_part: generated_part,
        generated_helper_write: generated_write,
        generated_source_inventory: generated_inventory,
        native_target: target,
        native_detached_copy: detached,
        native_attach: attached,
        native_reopen: reopened,
        generated_source_unchanged: true,
      }
    end

    def run_helper_success!(build_kind, helper, cell, action, origin, part_path, stage_root)
      ensure_helper_pin!(build_kind, helper)
      make_directory!(stage_root)
      argv = [helper.fetch(:path), action, cell.fetch(:mode), cell.fetch(:mark), cell.fetch(:profile), part_path]
      result = run_bounded_helper!("#{build_kind}_#{cell.fetch(:id)}_#{action}_#{origin}", argv, stage_root,
        helper.fetch(:sha256))
      fail!("#{build_kind}/#{cell.fetch(:id)} helper #{action} failed or emitted stderr") unless
        !result.fetch(:timed_out) && result.fetch(:spawn_error).nil? && result.fetch(:read_error).nil? &&
        result.fetch(:exitstatus) == 0 && result.fetch(:termsig).nil? && result.fetch(:stderr).empty? &&
        !result.fetch(:stdout_truncated) && !result.fetch(:stderr_truncated)
      report = JSON.parse(result.fetch(:stdout).force_encoding(Encoding::UTF_8))
      validate_helper_report!(report, action: action, origin: origin, cell: cell, part_path: part_path)
      report.merge('_process' => result.fetch(:record))
    rescue JSON::ParserError, KeyError => error
      fail!("#{build_kind}/#{cell.fetch(:id)} helper output is malformed: #{error.class}: #{error.message}")
    end

    def validate_helper_report!(report, action:, origin:, cell:, part_path:)
      fail!('helper result is not the exact closed JSON envelope') unless report.is_a?(Hash) && report.keys.sort == HELPER_KEYS
      expected = {
        'format' => HELPER_FORMAT,
        'action' => action,
        'variant_discriminator_mode' => cell.fetch(:mode),
        'mark_format' => cell.fetch(:mark),
        'string_profile' => cell.fetch(:profile),
        'reader_ordinary_profile' => cell.fetch(:profile),
        'status' => 'ok',
        'part_path' => part_path,
        'schema' => W::TRACE_TYPE,
        'row_count' => W::ROW_COUNT,
        'data_mark_count' => W::DATA_MARK_COUNT,
        'part_origin' => origin,
        'public_reader_mark_rows' => EXPECTED_ROWS_PER_MARK,
        'dynamic_prefix_capture' => 'not_implemented',
        'dynamic_statistics_placement' => 'unobserved',
      }
      expected.each { |key, value| fail!("helper report #{key} differs") unless report.fetch(key) == value }
      windows = report.fetch('recursive_windows')
      fail!('helper recursive window roster differs') unless windows.is_a?(Hash) && windows.keys.sort == HELPER_EXPECTED_WINDOWS.keys.sort
      HELPER_EXPECTED_WINDOWS.each do |name, signatures|
        entry = windows.fetch(name)
        spec = WINDOWS.fetch(name)
        fail!("helper #{name} literal signatures differ") unless entry.fetch('signatures') == signatures
        fail!("helper #{name} mark bounds differ") unless
          entry.fetch('first_mark') == spec.fetch(:first_mark) && entry.fetch('mark_count') == spec.fetch(:mark_count)
      end
      report
    end

    def create_empty_target!(build_kind, cell, case_root)
      id = cell.fetch(:id)
      table = target_table_name(build_kind, id)
      store = File.join(case_root, 'native', 'store')
      make_directory!(File.join(case_root, 'native'))
      fail!("#{build_kind}/#{id} native store path already exists") if File.exist?(store) || File.symlink?(store)
      sql = target_create_sql(build_kind, cell)
      result = run_native!("#{build_kind}_#{id}_target_create", store, sql,
        File.join(case_root, 'native', 'target-create'))
      @runner.send(:validate_pin_output!, "#{build_kind}/#{id}/target-create", result.fetch(:stdout))
      @runner.send(:validate_schema_output!, "#{build_kind}/#{id}/target-create", result.fetch(:stdout))
      path_tag = "__W284_TARGET_PATH__#{build_kind}_#{id}__"
      path_rows = tagged_rows(result.fetch(:stdout), path_tag, 2, "#{build_kind}/#{id} target path")
      fail!("#{build_kind}/#{id} target data path is not unique") unless path_rows.size == 1 && !path_rows.first.fetch(1).empty?
      data_path = File.expand_path(path_rows.first.fetch(1))
      store_real = File.realpath(store)
      data_real = File.realpath(data_path)
      fail!("#{build_kind}/#{id} native table data path escaped its store") unless
        data_real.start_with?("#{store_real}#{File::SEPARATOR}") && File.directory?(data_real) && !File.symlink?(data_path)
      parts_tag = "__W284_TARGET_PARTS__#{build_kind}_#{id}__"
      part_rows = tagged_rows(result.fetch(:stdout), parts_tag, 2, "#{build_kind}/#{id} empty target parts")
      fail!("#{build_kind}/#{id} target was not empty before ATTACH") unless part_rows == [[parts_tag, '0']]
      {table: table, store: store_real, data_path: data_real, create_sql_sha256: Digest::SHA256.hexdigest(sql),
       create_invocation: result.fetch(:record), active_parts_before_attach: 0}
    end

    def target_create_sql(build_kind, cell)
      id = cell.fetch(:id)
      table = target_table_name(build_kind, id)
      schema_marker = '__W284_SCHEMA__'
      path_tag = "__W284_TARGET_PATH__#{build_kind}_#{id}__"
      parts_tag = "__W284_TARGET_PARTS__#{build_kind}_#{id}__"
      [
        'SET flatten_nested=0;',
        'SET allow_suspicious_low_cardinality_types=1;',
        'SET use_variant_as_common_type=1;',
        @runner.send(:pin_sql),
        "CREATE TABLE default.#{table} (pk UInt64, trace #{W::TRACE_TYPE}) ENGINE=MergeTree ORDER BY pk SETTINGS #{@runner.send(:table_settings, cell)};",
        "SELECT '#{schema_marker}', name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw;",
        "SELECT '#{path_tag}', arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw;",
        "SELECT '#{parts_tag}', toString(count()) FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw;",
      ].join("\n") + "\n"
    end

    def copy_to_detached!(build_kind, id, generated_part, generated_inventory, target)
      detached_root = File.join(target.fetch(:data_path), 'detached')
      if File.exist?(detached_root) || File.symlink?(detached_root)
        stat = File.lstat(detached_root)
        fail!("#{build_kind}/#{id} target detached path is unsafe") unless stat.directory? && !stat.symlink? && Dir.children(detached_root).empty?
      else
        Dir.mkdir(detached_root, 0o700)
      end
      destination = File.join(detached_root, EXPECTED_PART_NAME)
      fail!("#{build_kind}/#{id} detached part path already exists") if File.exist?(destination) || File.symlink?(destination)
      FileUtils.cp_r(generated_part, destination, preserve: true)
      copied_inventory = @runner.send(:inventory_part, destination)
      fail!("#{build_kind}/#{id} detached copy differs byte-for-byte from generated source") unless
        copied_inventory == generated_inventory
      {path: destination, inventory: copied_inventory, matches_generated_source: true}
    rescue SystemCallError => error
      fail!("#{build_kind}/#{id} detached part copy failed: #{error.class}: #{error.message}")
    end

    def attach_and_check!(build_kind, cell, id, case_root, target, generated_inventory)
      sql = native_consumer_sql(target.fetch(:table), 'attach')
      result = run_native!("#{build_kind}_#{id}_attach", target.fetch(:store), sql,
        File.join(case_root, 'native', 'attach'))
      validate_native_consumer!(build_kind, id, 'attach', cell, result)
      active = native_part_path!(build_kind, id, 'attach', result.fetch(:stdout), target)
      active_inventory = @runner.send(:inventory_part, active.fetch(:path))
      sidecar_bytes = read_bounded_file(File.join(active.fetch(:path), SIDECAR_PATH),
        SIDECAR_BYTES.bytesize, "#{build_kind}/#{id} ATTACH sidecar")
      sidecar = attached_inventory_contract!(generated_inventory, active_inventory, sidecar_bytes)
      fail!("#{build_kind}/#{id} generated source changed during ATTACH") unless
        @runner.send(:inventory_part, File.join(@root, build_kind, 'parts', id)) == generated_inventory
      {native_part: active, active_inventory: active_inventory, native_sidecar: sidecar,
       invocation: result.fetch(:record), sql_sha256: Digest::SHA256.hexdigest(sql)}
    end

    def reopen_and_check!(build_kind, cell, id, case_root, target, generated_inventory, expected_active_inventory)
      sql = native_consumer_sql(target.fetch(:table), 'reopen')
      result = run_native!("#{build_kind}_#{id}_reopen", target.fetch(:store), sql,
        File.join(case_root, 'native', 'reopen'))
      validate_native_consumer!(build_kind, id, 'reopen', cell, result)
      active = native_part_path!(build_kind, id, 'reopen', result.fetch(:stdout), target)
      active_inventory = @runner.send(:inventory_part, active.fetch(:path))
      fail!("#{build_kind}/#{id} attached files changed during reopen") unless active_inventory == expected_active_inventory
      fail!("#{build_kind}/#{id} generated source changed during reopen") unless
        @runner.send(:inventory_part, File.join(@root, build_kind, 'parts', id)) == generated_inventory
      {native_part: active, active_inventory: active_inventory, invocation: result.fetch(:record),
       sql_sha256: Digest::SHA256.hexdigest(sql), files_unchanged_from_attach: true}
    end

    def native_consumer_sql(table, stage)
      fail!('native consumer stage must be attach or reopen') unless %w[attach reopen].include?(stage)
      statements = [
        'SET flatten_nested=0;',
        'SET allow_suspicious_low_cardinality_types=1;',
        @runner.send(:pin_sql),
      ]
      statements << "ALTER TABLE default.#{table} ATTACH PART '#{EXPECTED_PART_NAME}';" if stage == 'attach'
      statements << @runner.send(:check_sql, table, stage)
      statements.concat(W::WINDOWS.map { |name, predicate| @runner.send(:window_sql, table, name, predicate) })
      statements << "SELECT '__W284_NATIVE_PART__#{stage}__', name, toString(rows), toString(marks), part_type, path FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw;"
      sql = statements.join("\n") + "\n"
      attach_lines = sql.lines.map(&:chomp).select { |line| line.include?('ATTACH PART') }
      expected_attach = "ALTER TABLE default.#{table} ATTACH PART '#{EXPECTED_PART_NAME}';"
      expected_attaches = stage == 'attach' ? [expected_attach] : []
      fail!("#{stage} native SQL ATTACH roster differs") unless attach_lines == expected_attaches
      fail!('ATTACH must precede the CHECK marker') if stage == 'attach' &&
        sql.index(expected_attach) >= sql.index('__W284_CHECK_BEGIN__attach__')
      sql
    end

    def validate_native_consumer!(build_kind, id, stage, _cell, result)
      label = "#{build_kind}/#{id}/#{stage}"
      stdout = result.fetch(:stdout)
      @runner.send(:validate_pin_output!, label, stdout)
      @runner.send(:validate_check_result!, label, stage, stdout, EXPECTED_PART_NAME)
      @runner.send(:validate_windows!, label, stdout)
      true
    end

    def native_part_path!(build_kind, id, stage, stdout, target)
      tag = "__W284_NATIVE_PART__#{stage}__"
      rows = tagged_rows(stdout, tag, 6, "#{build_kind}/#{id}/#{stage} active native part")
      fail!("#{build_kind}/#{id}/#{stage} active native part row is missing or duplicated") unless rows.size == 1
      _tag, name, row_count, marks, part_type, raw_path = rows.first
      fail!("#{build_kind}/#{id}/#{stage} native part identity differs") unless
        name == EXPECTED_PART_NAME && row_count == W::ROW_COUNT.to_s && marks == (W::DATA_MARK_COUNT + 1).to_s && part_type == 'Compact'
      path = File.expand_path(raw_path)
      real = File.realpath(path)
      data_root = File.realpath(target.fetch(:data_path))
      fail!("#{build_kind}/#{id}/#{stage} native part escaped the empty target table path") unless
        real.start_with?("#{data_root}#{File::SEPARATOR}") && File.basename(real) == EXPECTED_PART_NAME &&
        File.directory?(real) && !File.symlink?(path)
      {name: name, rows: Integer(row_count), marks: Integer(marks), part_type: part_type, path: real}
    rescue ArgumentError, Errno::ENOENT => error
      fail!("#{build_kind}/#{id}/#{stage} native part row is malformed: #{error.class}: #{error.message}")
    end

    def run_native!(label, store, sql, stage_root)
      make_directory!(stage_root)
      sql_path = File.join(stage_root, 'input.sql')
      @runner.send(:write_new, sql_path, sql)
      argv = @runner.send(:native_argv, store)
      record = @runner.send(:run_process!, label, argv, sql, sql_path, stage_root)
      @native_records << record
      fail!("#{label} ClickHouse process failed: exit=#{record[:exitstatus].inspect}, signal=#{record[:termsig].inspect}") unless
        record[:exitstatus] == 0 && record[:termsig].nil? && !record[:timed_out]
      fail!("#{label} native process stream capture was truncated or failed") unless
        !record[:stdout_truncated] && !record[:stderr_truncated] &&
        record[:stdout_read_error].nil? && record[:stderr_read_error].nil? && record[:stdin_write_error].nil?
      stdout = File.binread(File.join(stage_root, 'stdout.bin'))
      {stdout: stdout, record: record}
    end

    def run_bounded_helper!(label, argv, stage_root, expected_sha)
      helper_path = argv.fetch(0)
      stdout_capture = {bytes: ''.b, observed_bytes: 0, truncated: true, error: 'process did not start'}
      stderr_capture = {bytes: ''.b, observed_bytes: 0, truncated: true, error: 'process did not start'}
      timed_out = false
      spawn_error = nil
      status = nil
      begin
        ensure_helper_binary_sha!(helper_path, expected_sha)
        @runner.send(:write_new, File.join(stage_root, 'argv.json'), JSON.pretty_generate(argv) + "\n")
        Open3.popen3(*argv) do |stdin, stdout, stderr, waiter|
          stdin.close
          stdout.binmode
          stderr.binmode
          stdout_reader, stdout_state, stdout_lock = start_bounded_reader(stdout)
          stderr_reader, stderr_state, stderr_lock = start_bounded_reader(stderr)
          unless waiter.join(MAX_HELPER_SECONDS)
            timed_out = true
            stop_pid(waiter.pid, 'TERM')
            unless waiter.join(5)
              stop_pid(waiter.pid, 'KILL')
              waiter.join(5)
            end
          end
          status = waiter.value if waiter.join(0)
          stdout_capture = finish_bounded_reader(stdout_reader, stdout, stdout_state, stdout_lock, 'stdout')
          stderr_capture = finish_bounded_reader(stderr_reader, stderr, stderr_state, stderr_lock, 'stderr')
        end
      rescue Errno::ENOENT, IOError, SystemCallError => error
        spawn_error = "#{error.class}: #{error.message}"
      end
      @runner.send(:write_new, File.join(stage_root, 'stdout.bin'), stdout_capture.fetch(:bytes))
      @runner.send(:write_new, File.join(stage_root, 'stderr.bin'), stderr_capture.fetch(:bytes))
      after_sha = (sha_file(helper_path) rescue nil)
      record = {
        label: label, argv: argv, process_group: 'inherited; pgroup was not requested',
        timed_out: timed_out, exitstatus: status&.exitstatus, termsig: status&.termsig,
        spawn_error: spawn_error, helper_sha256_expected: expected_sha,
        helper_sha256_after: after_sha, stdout_bytes: stdout_capture.fetch(:bytes).bytesize,
        stdout_observed_bytes: stdout_capture.fetch(:observed_bytes), stdout_truncated: stdout_capture.fetch(:truncated),
        stdout_read_error: stdout_capture.fetch(:error), stdout_sha256: Digest::SHA256.hexdigest(stdout_capture.fetch(:bytes)),
        stderr_bytes: stderr_capture.fetch(:bytes).bytesize,
        stderr_observed_bytes: stderr_capture.fetch(:observed_bytes), stderr_truncated: stderr_capture.fetch(:truncated),
        stderr_read_error: stderr_capture.fetch(:error), stderr_sha256: Digest::SHA256.hexdigest(stderr_capture.fetch(:bytes)),
      }
      @runner.send(:write_new, File.join(stage_root, 'invocation.json'), JSON.pretty_generate(record) + "\n")
      @helper_records << record
      {stdout: stdout_capture.fetch(:bytes), stderr: stderr_capture.fetch(:bytes),
        timed_out: timed_out, exitstatus: status&.exitstatus, termsig: status&.termsig,
        spawn_error: spawn_error,
        read_error: [stdout_capture.fetch(:error), stderr_capture.fetch(:error)].compact.join('; ').then { |s| s.empty? ? nil : s },
        stdout_truncated: stdout_capture.fetch(:truncated), stderr_truncated: stderr_capture.fetch(:truncated),
        record: record}
    end

    def start_bounded_reader(stream, limit: MAX_HELPER_OUTPUT_BYTES)
      state = {bytes: ''.b, observed_bytes: 0, truncated: false, error: nil, finished: false}
      lock = Mutex.new
      reader = Thread.new do
        begin
          loop do
            chunk = stream.readpartial(W::STREAM_CHUNK_BYTES)
            lock.synchronize do
              state[:observed_bytes] += chunk.bytesize
              remaining = limit - state[:bytes].bytesize
              state[:bytes] << chunk.byteslice(0, remaining) if remaining.positive?
              state[:truncated] ||= chunk.bytesize > remaining
            end
          end
        rescue EOFError
          nil
        rescue IOError, SystemCallError => error
          lock.synchronize { state[:error] = "#{error.class}: #{error.message}" }
        ensure
          lock.synchronize { state[:finished] = true }
        end
      end
      [reader, state, lock]
    end

    def finish_bounded_reader(reader, stream, state, lock, label)
      return bounded_reader_snapshot(state, lock) if reader.join(5)
      begin
        stream.close unless stream.closed?
      rescue IOError, SystemCallError
        nil
      end
      if reader.join(1)
        snapshot = bounded_reader_snapshot(state, lock)
        snapshot[:error] ||= "#{label} stream was closed because its reader did not finish"
        snapshot[:truncated] = true
        return snapshot
      end
      reader.kill if reader.alive?
      reader.join(1)
      snapshot = bounded_reader_snapshot(state, lock)
      snapshot[:error] ||= "#{label} reader did not finish within five seconds"
      snapshot[:truncated] = true
      snapshot
    end

    def bounded_reader_snapshot(state, lock)
      lock.synchronize do
        state.merge(bytes: state.fetch(:bytes).dup).reject { |key, _| key == :finished }
      end
    end

    def run_coordinate_mutant!(build_kind, helper, stock_cell, build_root)
      id = 'basic_mrk4_s0'
      cell = W::CASES.find { |entry| entry.fetch(:id) == id }
      stock_path = stock_cell.fetch('part_path')
      stock_inventory = stock_cell.fetch('part_inventory')
      verify_inventory_matches_auditor!(stock_path, stock_inventory, "#{build_kind}/#{id} mutant source")
      mutant_path = File.join(build_root, 'mutants', id, EXPECTED_PART_NAME)
      make_directory!(File.dirname(File.dirname(mutant_path)))
      make_directory!(File.dirname(mutant_path))
      FileUtils.cp_r(stock_path, mutant_path, preserve: true)
      source_inventory = @runner.send(:inventory_part, stock_path)
      copied_inventory = @runner.send(:inventory_part, mutant_path)
      fail!("#{build_kind} mutant copy differs before mutation") unless copied_inventory == source_inventory
      raw_path = File.join(mutant_path, 'data.mrk4')
      raw_before = File.binread(raw_path)
      geometry = stock_cell.fetch('mark_geometry')
      mutation = mutate_coordinate_bytes(raw_before, geometry, mark_index: 2,
        slot_index: geometry.fetch('dynamic_structure_global_slot'))
      File.open(raw_path, 'wb') { |file| file.write(mutation.fetch(:bytes)) }
      raw_after = File.binread(raw_path)
      fail!("#{build_kind} mutant raw MRK4 length changed") unless raw_after.bytesize == raw_before.bytesize
      fail!("#{build_kind} mutant raw MRK4 bytes differ from derived one-word mutation") unless raw_after == mutation.fetch(:bytes)
      mutated_inventory = @runner.send(:inventory_part, mutant_path)
      changed_files = changed_inventory_paths(source_inventory, mutated_inventory)
      fail!("#{build_kind} mutant changed files other than data.mrk4") unless changed_files == ['data.mrk4']
      helper_result = run_helper_error!(build_kind, helper, cell, mutant_path,
        File.join(build_root, 'mutants', id, 'public-helper'))
      verify_inventory_matches_auditor!(stock_path, stock_inventory, "#{build_kind}/#{id} post-mutant stock source")
      {
        source_part: stock_path,
        copied_mutant_part: mutant_path,
        copied_source_inventory: source_inventory,
        mutated_inventory: mutated_inventory,
        mutation: mutation.reject { |key, _| key == :bytes },
        only_changed_file: changed_files,
        checksums_file_resealed: false,
        public_helper_result: helper_result,
        interpretation: 'Public helper actually attempted the copied plain-MRK4 part. The exact error is recorded without attributing it to Dynamic grammar; this is not an offline-inventory denial or a native checksum validation result.',
        immutable_stock_source_rechecked: true,
      }
    rescue SystemCallError => error
      fail!("#{build_kind} copied MRK4 public-helper mutant failed: #{error.class}: #{error.message}")
    end

    def run_helper_error!(build_kind, helper, cell, part_path, stage_root)
      ensure_helper_pin!(build_kind, helper)
      make_directory!(stage_root)
      argv = [helper.fetch(:path), 'read', cell.fetch(:mode), cell.fetch(:mark), cell.fetch(:profile), part_path]
      result = run_bounded_helper!("#{build_kind}_#{cell.fetch(:id)}_mrk4_coordinate_mutant", argv, stage_root,
        helper.fetch(:sha256))
      fail!("#{build_kind} public helper accepted the +1 MRK4 coordinate mutant") unless
        !result.fetch(:timed_out) && result.fetch(:spawn_error).nil? && result.fetch(:read_error).nil? &&
        result.fetch(:exitstatus).is_a?(Integer) && result.fetch(:exitstatus) != 0 &&
        result.fetch(:termsig).nil? && !result.fetch(:stdout_truncated) && !result.fetch(:stderr_truncated)
      fail!("#{build_kind} mutant helper returned normal stdout before rejection") unless result.fetch(:stdout).empty?
      error_report = JSON.parse(result.fetch(:stderr).force_encoding(Encoding::UTF_8))
      rejection = validate_public_helper_mutant_error!(error_report, build_kind)
      {status: 'public_helper_rejected_mutant', error_class: rejection.fetch(:error_class),
       error: rejection.fetch(:error), process: result.fetch(:record),
       rejection_reason_classification: 'unclassified_from_exact_public-helper-error; not claimed as Dynamic grammar'}
    rescue JSON::ParserError, KeyError => error
      fail!("#{build_kind} public-helper mutant error was not parseable: #{error.class}: #{error.message}")
    end

    def validate_public_helper_mutant_error!(error_report, label)
      fail!("#{label} mutant rejection envelope is not a helper error") unless
        error_report.is_a?(Hash) && error_report['format'] == HELPER_FORMAT && error_report['status'] == 'error' &&
        error_report['error_class'].is_a?(String) && error_report['error'].is_a?(String) &&
        !error_report['error'].empty?
      fail!("#{label} mutant helper failed with an unrelated class") unless
        PUBLIC_MUTANT_ERROR_CLASSES.include?(error_report.fetch('error_class'))
      {error_class: error_report.fetch('error_class'), error: error_report.fetch('error')}
    end

    def mutate_coordinate_bytes(raw, geometry, mark_index:, slot_index:)
      fail!('coordinate mutation input is not a binary String') unless raw.is_a?(String)
      slots = Integer(geometry.fetch('global_slot_count'))
      words_per_record = Integer(geometry.fetch('record_words'))
      fail!('MRK4 record word geometry is inconsistent') unless words_per_record == 2 * slots + 1
      fail!('mutant mark index is outside the captured four data marks') unless mark_index == 2
      fail!('DynamicStructure slot differs from the audited schema ledger') unless slot_index == 2
      coordinate_word = mark_index * words_per_record + 2 * slot_index + 1
      byte_offset = coordinate_word * 8
      fail!('MRK4 coordinate word is outside the raw mark file') if byte_offset > raw.bytesize - 8
      before_bytes = raw.byteslice(byte_offset, 8)
      before = before_bytes.unpack1('Q<')
      coordinate_before = raw.byteslice(byte_offset - 8, 16).unpack('Q<Q<')
      fail!('MRK4 DynamicStructure offset cannot be incremented safely') if before == (2**64 - 1)
      after = before + 1
      mutated = raw.dup.force_encoding(Encoding::BINARY)
      mutated[byte_offset, 8] = [after].pack('Q<')
      offsets = raw.bytes.each_index.select { |index| raw.getbyte(index) != mutated.getbyte(index) }
      fail!('MRK4 coordinate mutation did not change exactly one raw byte') unless offsets == [byte_offset]
      {
        bytes: mutated,
        coordinate_component: 'decompressed_offset',
        mark_index: mark_index,
        global_slot_index: slot_index,
        record_words: words_per_record,
        coordinate_word_index: coordinate_word,
        byte_offset: byte_offset,
        coordinate_before: coordinate_before,
        coordinate_after: [coordinate_before.fetch(0), after],
        raw_bytes: raw.bytesize,
        raw_sha256_before: Digest::SHA256.hexdigest(raw),
        raw_sha256_after: Digest::SHA256.hexdigest(mutated),
        changed_bytes: offsets.map { |offset| {offset: offset, before_hex: raw.getbyte(offset).to_s(16).rjust(2, '0'), after_hex: mutated.getbyte(offset).to_s(16).rjust(2, '0')} },
        row_geometry_unchanged: true,
      }
    end

    def changed_inventory_paths(before, after)
      old_files = before.fetch(:files).to_h { |entry| [entry.fetch(:relative_path), entry] }
      new_files = after.fetch(:files).to_h { |entry| [entry.fetch(:relative_path), entry] }
      (old_files.keys | new_files.keys).select { |path| old_files[path] != new_files[path] }.sort
    end

    def verify_inventory_matches_auditor!(path, expected, label)
      observed = @runner.send(:inventory_part, path)
      fail!("#{label} inventory differs from independently audited stock part") unless
        observed.fetch(:file_count) == expected.fetch('file_count') &&
        observed.fetch(:total_bytes) == expected.fetch('total_bytes') &&
        observed.fetch(:sha256) == expected.fetch('snapshot_sha256') &&
        normalize_inventory_file_entries(observed.fetch(:files), :symbol, label) ==
          normalize_inventory_file_entries(expected.fetch('files'), :string, label)
      observed
    end

    def normalize_inventory_file_entries(entries, key_kind, label)
      fail!("#{label} inventory file roster is malformed") unless entries.is_a?(Array)
      keys = key_kind == :symbol ? %i[relative_path bytes sha256] : %w[relative_path bytes sha256]
      entries.map do |entry|
        fail!("#{label} inventory file entry is malformed") unless entry.is_a?(Hash) && entry.keys.sort == keys.sort
        if key_kind == :symbol
          {'relative_path' => entry.fetch(:relative_path), 'bytes' => entry.fetch(:bytes), 'sha256' => entry.fetch(:sha256)}
        else
          {'relative_path' => entry.fetch('relative_path'), 'bytes' => entry.fetch('bytes'), 'sha256' => entry.fetch('sha256')}
        end
      end.sort_by { |entry| entry.fetch('relative_path') }
    end

    def attached_inventory_contract!(source, attached, sidecar_bytes)
      old_files = source.fetch(:files).to_h { |entry| [entry.fetch(:relative_path), entry] }
      new_files = attached.fetch(:files).to_h { |entry| [entry.fetch(:relative_path), entry] }
      fail!('ATTACH removed or changed a generated source file') unless old_files.all? { |path, entry| new_files[path] == entry }
      extras = new_files.keys - old_files.keys
      fail!('ATTACH added files other than the single pinned sidecar') unless extras == [SIDECAR_PATH]
      entry = new_files.fetch(SIDECAR_PATH)
      fail!('ATTACH sidecar inventory size/hash differs') unless
        entry.fetch(:bytes) == SIDECAR_BYTES.bytesize && entry.fetch(:sha256) == SIDECAR_SHA256
      fail!('ATTACH sidecar actual bytes differ') unless sidecar_bytes == SIDECAR_BYTES
      fail!('ATTACH part inventory file count is not exactly source plus sidecar') unless
        attached.fetch(:file_count) == source.fetch(:file_count) + 1
      {path: SIDECAR_PATH, bytes: sidecar_bytes.bytesize, sha256: Digest::SHA256.hexdigest(sidecar_bytes),
       exact_source_files_preserved: true, extra_files: extras}
    end

    def target_table_name(build_kind, id)
      "w284_interop_#{build_kind}_#{id}"
    end

    def tagged_rows(stdout, tag, fields, label)
      text = stdout.dup.force_encoding(Encoding::UTF_8)
      fail!("#{label} stdout is not valid UTF-8") unless text.valid_encoding?
      fail!("#{label} stdout is not newline terminated") unless text.empty? || text.end_with?("\n")
      matches = text.lines(chomp: true).select { |line| line.start_with?("#{tag}\t") }
      parsed = matches.map { |line| line.split("\t", -1) }
      fail!("#{label} marker row has an unexpected field count") unless parsed.all? { |row| row.size == fields }
      parsed
    end

    def ensure_helper_pin!(build_kind, helper)
      ensure_helper_binary_sha!(helper.fetch(:path), helper.fetch(:sha256))
      true
    rescue Errno::ENOENT
      fail!("#{build_kind} helper disappeared during interop")
    end

    def ensure_helper_binary_sha!(path, expected)
      stat = File.lstat(path)
      fail!('helper binary changed type or became symlinked') unless stat.file? && !stat.symlink? && File.executable?(path)
      fail!('helper binary SHA changed during the matrix') unless sha_file(path) == expected
    end

    def stop_pid(pid, signal)
      Process.kill(signal, pid)
    rescue Errno::ESRCH
      nil
    end

    def make_directory!(path)
      expanded = File.expand_path(path)
      root_prefix = "#{@root}#{File::SEPARATOR}"
      fail!("refusing directory outside W284 evidence root: #{expanded}") unless expanded.start_with?(root_prefix)
      fail!("directory already exists or is symlinked: #{expanded}") if File.exist?(expanded) || File.symlink?(expanded)
      parent = File.dirname(expanded)
      parent_stat = File.lstat(parent)
      fail!("directory parent is unsafe: #{parent}") unless parent_stat.directory? && !parent_stat.symlink?
      Dir.mkdir(expanded, 0o700)
      fail!("created directory is not canonical: #{expanded}") unless File.realpath(expanded) == expanded
      expanded
    rescue Errno::ENOENT
      raise Error, "directory parent is missing for #{path}"
    end

    def read_bounded_file(path, limit, label)
      stat = File.lstat(path)
      fail!("#{label} is not a regular non-symlink file") unless stat.file? && !stat.symlink?
      fail!("#{label} exceeds byte bound") if stat.size > limit
      bytes = String.new(encoding: Encoding::BINARY)
      File.open(path, 'rb') do |file|
        while (chunk = file.read(64 * 1024))
          fail!("#{label} streamed read exceeded byte bound") if bytes.bytesize > limit - chunk.bytesize
          bytes << chunk
        end
      end
      fail!("#{label} size changed while read") unless bytes.bytesize == stat.size
      bytes
    rescue Errno::ENOENT
      fail!("#{label} is absent")
    end

    def sha_file(path)
      Digest::SHA256.file(path).hexdigest
    end

    def write_exclusive(path, bytes)
      fail!("refusing output outside W284 root: #{path}") unless File.expand_path(path).start_with?("#{@root}#{File::SEPARATOR}")
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(bytes)
        file.flush
      end
    end

    def result_document(stock, helpers)
      {
        format: FORMAT,
        status: STATUS,
        evidence_root: @root,
        source_pin: {root: @source_root, revision_expected: W::SOURCE_REVISION,
          revision_before: @source_revision_before, revision_after: @source_revision_after},
        runtime_pin: W::RUNTIME_PIN.merge(binary: @runtime_path, sha256_before: @runtime_before,
          sha256_after: @runtime_after, bytes_before: @runtime_bytes_before, bytes_after: @runtime_bytes_after),
        local_source_sha256_before: @source_hashes_before,
        local_source_sha256_after: @source_hashes_after,
        driver_sha256_before: @driver_sha_before,
        driver_sha256_after: @driver_sha_after,
        offline_auditor_sha256: AUDITOR_SHA256,
        stock_capture: stock.reject { |key, _| key == :case_data || key == :report },
        helper_pins: helpers,
        cells: @cells,
        public_helper_coordinate_mutants: @mutants,
        process_counts: {native: @native_records.size, helper: @helper_records.size,
          total: @native_records.size + @helper_records.size},
        native_processes: @native_records,
        helper_processes: @helper_records,
        process_policy: {
          max_parallel_processes: 1,
          native_timeout_seconds: W::PROCESS_TIMEOUT_SECONDS,
          helper_timeout_seconds: MAX_HELPER_SECONDS,
          stream_caps: {native_bytes: W::MAX_PART_BYTES, helper_bytes_each_stream: MAX_HELPER_OUTPUT_BYTES},
          process_group: 'no child uses pgroup; all children inherit the outer run_safe process group',
          timeout: 'PID-specific TERM then KILL is bounded; only the unchanged outer run_safe guard owns whole-group cleanup',
        },
        claim_boundary: {
          proves: 'Pinned helper reads of eight exact stock parts and writes of eight generated parts per DEBUG/RELEASE helper; native empty target creation, ATTACH/CHECK/four windows, and separate reopen/CHECK/four windows for each generated part; exact byte-preservation plus one pinned sidecar; public helper attempted one copied plain-MRK4 coordinate mutant per helper and reported the exact observed error.',
          does_not_prove: [
            'Any Dynamic/JSON/Compact layout outside this exact schema and matrix.',
            'That the MRK4 mutant error is specifically Dynamic grammar rejection; the exact public-helper error is recorded without attributing its cause.',
            'ClickHouse CityHash128 validation by the offline auditor.',
            'Generic Dynamic discovery, Dynamic/JSON actual arms, compact marks, projections, materialized views, or performance.',
          ],
        },
      }
    end

    def persist_inconclusive(error)
      return unless @root && File.directory?(@root)
      path = File.join(@root, 'inconclusive.json')
      return if File.exist?(path) || File.symlink?(path)
      data = {
        format: FORMAT,
        status: 'inconclusive_no_matrix_qualification',
        error: "#{error.class}: #{error.message}",
        completed_cells: @cells,
        public_helper_coordinate_mutants: @mutants,
        native_processes: @native_records,
        helper_processes: @helper_records,
        process_counts: {native: @native_records.size, helper: @helper_records.size},
        runtime_sha256_after: (@runtime_path && sha_file(@runtime_path) rescue nil),
        source_revision_after: (@source_root && @runner.send(:git_revision, @source_root) rescue nil),
      }
      write_exclusive(path, JSON.pretty_generate(data) + "\n")
    rescue StandardError
      nil
    end
  end

  def self.synthetic_helper_report(action, origin, part_path)
    cell = W::CASES.first
    {
      'format' => HELPER_FORMAT,
      'action' => action,
      'variant_discriminator_mode' => cell.fetch(:mode),
      'mark_format' => cell.fetch(:mark),
      'string_profile' => cell.fetch(:profile),
      'reader_ordinary_profile' => cell.fetch(:profile),
      'status' => 'ok',
      'part_path' => part_path,
      'schema' => W::TRACE_TYPE,
      'row_count' => W::ROW_COUNT,
      'data_mark_count' => W::DATA_MARK_COUNT,
      'part_origin' => origin,
      'public_reader_mark_rows' => EXPECTED_ROWS_PER_MARK,
      'dynamic_prefix_capture' => 'not_implemented',
      'dynamic_statistics_placement' => 'unobserved',
      'recursive_windows' => HELPER_EXPECTED_WINDOWS.to_h do |name, signatures|
        spec = WINDOWS.fetch(name)
        [name, {'signatures' => signatures, 'first_mark' => spec.fetch(:first_mark), 'mark_count' => spec.fetch(:mark_count)}]
      end,
    }
  end

  def self.run(argv = ARGV)
    options = {
      execute: false,
      self_test: false,
      evidence_root: File.join(TASK_ROOT, 'interop-debug-release'),
      summary_path: STOCK_SUMMARY,
      audit_report_path: STOCK_AUDIT_REPORT,
      debug_helper: nil,
      debug_helper_sha256: nil,
      release_helper: nil,
      release_helper_sha256: nil,
    }
    OptionParser.new do |parser|
      parser.banner = 'Usage: ruby scripts/verify_compact_recursive_dynamic_w284_interop.rb [--plan | --self-test | --execute] [helper pins]'
      parser.on('--plan', 'print exact bounded matrix plan only (default)') { options[:execute] = false; options[:self_test] = false }
      parser.on('--self-test', 'run Ruby-only validator/mutant tests; no subprocess or writes') { options[:self_test] = true; options[:execute] = false }
      parser.on('--execute', 'execute pinned precompiled helper and native interoperability matrix') { options[:execute] = true; options[:self_test] = false }
      parser.on('--evidence-root PATH', 'existing empty direct child of W284 SSD task root') { |v| options[:evidence_root] = v }
      parser.on('--summary PATH', 'pinned immutable stock-first summary JSON') { |v| options[:summary_path] = v }
      parser.on('--audit-report PATH', 'pinned all-cell offline Dynamic prefix audit report') { |v| options[:audit_report_path] = v }
      parser.on('--debug-helper PATH', 'explicit precompiled DEBUG helper binary') { |v| options[:debug_helper] = v }
      parser.on('--debug-helper-sha256 SHA256', 'explicit DEBUG helper SHA-256') { |v| options[:debug_helper_sha256] = v }
      parser.on('--release-helper PATH', 'explicit precompiled RELEASE helper binary') { |v| options[:release_helper] = v }
      parser.on('--release-helper-sha256 SHA256', 'explicit RELEASE helper SHA-256') { |v| options[:release_helper_sha256] = v }
    end.parse!(argv)
    raise Error, 'unexpected positional arguments' unless argv.empty?
    driver = Driver.new(options)
    return driver.self_test if options.fetch(:self_test)
    return driver.run if options.fetch(:execute)
    driver.print_plan
  rescue OptionParser::ParseError, Error => error
    warn "W284 interop request rejected: #{error.class}: #{error.message}"
    false
  end
end

exit(VerifyCompactRecursiveDynamicW284Interop.run ? 0 : 1) if $PROGRAM_NAME == __FILE__
