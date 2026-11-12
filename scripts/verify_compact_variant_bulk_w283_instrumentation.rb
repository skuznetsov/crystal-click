#!/usr/bin/env ruby
# Pure-Ruby falsifiers for W283 status classification, settings substitution,
# and the read-only raw-capture auditor.

require 'optparse'
require_relative 'probe_compact_variant_bulk_w283_matrix'
require_relative 'verify_compact_variant_bulk_w283_capture'

module VerifyCompactVariantBulkW283Instrumentation
  M = ProbeCompactVariantBulkW283Matrix
  A = VerifyCompactVariantBulkW283Capture
  PROBE = M::Probe
  CELL_IDS = M::MODES.flat_map do |mode|
    M::MARK_FORMATS.flat_map { |mark| M::PROFILES.map { |profile| "#{M::CASE}_#{mode}_#{mark}_#{profile}" } }
  end.freeze

  STOCK_EXACT = 'exact_native_values'.freeze
  READ_EXACT = 'exact_public_recursive_reads'.freeze
  GENERATED_EXACT = 'exact_generated_native_interop'.freeze
  ADMISSION_RED = 'library_admission_rejection_captured'.freeze
  INFRA_FAILURE = 'helper_infrastructure_failure'.freeze

  class Error < StandardError; end

  def self.run(evidence_root: nil)
    raise Error, 'matrix must expose exactly eight ordered W283 cells' unless
      CELL_IDS.size == 8 && CELL_IDS.uniq == CELL_IDS && CELL_IDS == A::Auditor.allocate.send(:expected_ids)
    checks = []

    raw_record_helper_lifecycle_checks!
    checks << 'raw-record-helper-pins-before-reconstruction-with-missing-pin-and-wrong-order-negatives'

    stock = summary(full_matrix: false, cells: stock_cells)
    assert_status!(stock, 'stock_native_matrix_exact')
    checks << 'eight-cell-stock-success'

    full = summary(full_matrix: true, cells: full_cells)
    assert_status!(full, 'generated_native_interop_matrix_exact')
    checks << 'eight-cell-full-requires-public-reads-and-generated-writes'

    missing_read_cells = full_cells
    missing_read_cells.fetch(CELL_IDS.first)[:library_stock_read][:status] = 'helper_incomplete'
    assert_status!(summary(full_matrix: true, cells: missing_read_cells), 'incomplete_or_discrepant')
    missing_generated_cells = full_cells
    missing_generated_cells.fetch(CELL_IDS.last)[:library_generated][:status] = 'probe_error'
    assert_status!(summary(full_matrix: true, cells: missing_generated_cells), 'incomplete_or_discrepant')
    omitted = stock_cells
    omitted.delete(CELL_IDS.last)
    assert_status!(summary(full_matrix: false, cells: omitted), 'incomplete_or_discrepant')
    checks << 'missing-read-generated-or-stock-cell-blocks-exact-status'

    red = summary(full_matrix: true, cells: full_cells(generated_status: ADMISSION_RED))
    assert_status!(red, 'generated_admission_rejection_captured')
    reject_audit_status!(red, :full_matrix)
    checks << 'captured-admission-red-is-not-compatibility'

    infra_cells = full_cells
    infra_cells.fetch(CELL_IDS.last)[:library_generated][:status] = INFRA_FAILURE
    infra = summary(full_matrix: true, cells: infra_cells)
    assert_status!(infra, 'probe_infrastructure_failure')
    reject_audit_status!(infra, :full_matrix)
    checks << 'infrastructure-failure-cannot-be-promoted'

    rejected = CELL_IDS.to_h do |id|
      [id, {case_id: id, status: 'create_server_exception'}]
    end
    stock_red = summary(full_matrix: false, cells: rejected)
    assert_status!(stock_red, 'stock_schema_rejection_captured')
    reject_audit_status!(stock_red, :stock_only)
    checks << 'stock-schema-rejection-is-a-blocked-probe'

    settings_substitution_checks!
    checks << 'basic-parent-setting-occurs-once-and-mode-substitution-is-exact'

    unless A::Auditor.self_test!
      raise Error, 'capture auditor pure-Ruby falsifier suite failed'
    end
    checks << 'raw-topology-pins-windows-profiles-sidecars-marks-and-prefix-mutants'

    if evidence_root
      actual_capture_mutants!(evidence_root)
      checks << 'pristine-full-capture-and-six-in-memory-mutants'
    end

    boundary = evidence_root ? 'capture read-only; mutants in memory; no native calls' : 'no capture reads, native calls, or subprocesses'
    puts "W283 instrumentation Ruby-only checks passed: #{checks.join(',')}; #{boundary}"
    true
  rescue StandardError => error
    warn "W283 instrumentation check failed: #{error.class}: #{error.message}"
    false
  end

  def self.raw_record_helper_lifecycle_checks!
    expected_failure = 'raw-record helper missing pin initialization before invocation reconstruction'
    [
      [:summary_contract!, :topology!, :invocations!],
      [:summary_contract!, :topology!, :invocations!, :pins!],
    ].each do |seeded_events|
      begin
        validate_raw_record_helper_lifecycle!(seeded_events)
      rescue Error => error
        raise Error, "seeded lifecycle failed unexpectedly: #{error.message}" unless error.message.start_with?(expected_failure)
      else
        raise Error, "raw-record helper lifecycle accepted seeded bad order: #{seeded_events.inspect}"
      end
    end

    original_auditor = A.const_get(:Auditor, false)
    recording_auditor = Class.new do
      attr_reader :events

      def initialize(_root, mode:)
        raise ArgumentError, 'recording auditor requires full_matrix mode' unless mode == :full_matrix
        @events = []
      end

      def summary_contract!; @events << :summary_contract!; end
      def pins!; @events << :pins!; end
      def topology!; @events << :topology!; end
      def invocations!; @events << :invocations!; end
    end

    removed_auditor = false
    begin
      A.send(:remove_const, :Auditor)
      removed_auditor = true
      A.const_set(:Auditor, recording_auditor)
      auditor = auditor_with_raw_records('/private/tmp/w283-lifecycle-seed')
      validate_raw_record_helper_lifecycle!(auditor.events)
    ensure
      if removed_auditor
        A.send(:remove_const, :Auditor) if A.const_defined?(:Auditor, false)
        A.const_set(:Auditor, original_auditor)
      end
    end

    puts 'W283 raw-record helper lifecycle Ruby-only regression passed: pin precedes reconstruction; missing-pin and wrong-order seeds rejected; no capture reads or subprocesses'
    true
  end

  def self.validate_raw_record_helper_lifecycle!(events)
    pin_index = events.index(:pins!)
    invocation_index = events.index(:invocations!)
    unless pin_index && invocation_index && pin_index < invocation_index
      raise Error, 'raw-record helper missing pin initialization before invocation reconstruction'
    end
    expected = %i[summary_contract! pins! topology! invocations!]
    raise Error, "raw-record helper lifecycle order differs: #{events.inspect}" unless events == expected
    true
  end

  def self.actual_capture_mutants!(root)
    pristine = A::Auditor.new(root, mode: :full_matrix)
    raise Error, 'pristine W283 full_matrix capture did not pass its auditor' unless pristine.run

    missing_case = A::Auditor.new(root, mode: :full_matrix)
    missing_case.instance_variable_get(:@summary).fetch('cases').delete(CELL_IDS.last)
    expect_capture_rejection!('missing case summary',
      'expected exactly eight BASIC/COMPACT × MRK3/MRK4 × S0/S1 cells') do
      missing_case.send(:summary_contract!)
    end

    profile_id = CELL_IDS.first
    mode, mark, profile = profile_id.split('_').values_at(2, 3, 4)
    profile_auditor = auditor_with_raw_records(root)
    profile_case = profile_auditor.instance_variable_get(:@summary).fetch('cases').fetch(profile_id)
    report = profile_case.dig('library_stock_read', 'report')
    report['reader_ordinary_profile'] = profile == 's0' ? 's1' : 's0'
    expect_capture_rejection!('reader ordinary-profile flip',
      "#{profile_id} helper report or observed String profile differs") do
      profile_auditor.send(:helper_report!, profile_id, mode, mark, profile, report,
        'read', profile_case.dig('schema_part', 'part', 'path'))
    end

    window_auditor = auditor_with_raw_records(root)
    window_case = window_auditor.instance_variable_get(:@summary).fetch('cases').fetch(profile_id)
    generated = window_case.fetch('library_generated')
    generated.fetch('native_windows').fetch('last').fetch('rows').last.delete('signature')
    target_table = generated.dig('native_target', 'table')
    expect_capture_rejection!('missing last generated window signature',
      "#{profile_id}_attached_values_last summary differs from independent oracle") do
      window_auditor.send(:validate_windows!, profile_id, target_table,
        generated.fetch('native_windows'), true)
    end

    mark_id = CELL_IDS.find { |id| id.include?('_mrk4_') }
    mark_mode, mark_format, mark_profile = mark_id.split('_').values_at(2, 3, 4)
    mark_auditor = auditor_with_raw_records(root)
    mark_case = mark_auditor.instance_variable_get(:@summary).fetch('cases').fetch(mark_id)
    active_part = mark_case.dig('library_generated', 'active_part', 'part')
    raw_capture = active_part.fetch('raw_capture')
    raw_capture['mark_bytes'] = Integer(raw_capture.fetch('mark_bytes')) + 1
    expect_capture_rejection!('MRK4 mark_bytes change',
      "#{mark_id}_attached raw mark seal differs") do
      mark_auditor.send(:validate_part!, "#{mark_id}_attached", mark_format,
        active_part.fetch('path'), raw_capture.fetch('inventory'), raw_capture.fetch('snapshot'),
        raw_capture.fetch('callback_roster'), raw_capture.fetch('serialization_metadata'),
        raw_capture.fetch('serialization_metadata_sha256'), raw_capture.fetch('serialization_metadata_raw_file'),
        raw_capture.fetch('mark_file'), raw_capture.fetch('mark_bytes'), raw_capture.fetch('mark_sha256'), :attached)
    end

    contract_auditor = auditor_with_raw_records(root)
    contract_case = contract_auditor.instance_variable_get(:@summary).fetch('cases').fetch(profile_id)
    contract_case.dig('library_generated', 'attached_inventory_contract')['state'] = 'forged'
    expect_capture_rejection!('generated attached inventory contract forgery',
      "#{profile_id} ATTACH inventory summary claim differs") do
      contract_auditor.send(:validate_full_case!, profile_id, contract_case, mode, mark, profile)
    end

    record_auditor = auditor_with_raw_records(root)
    record_label = "#{profile_id}_create"
    record = record_auditor.instance_variable_get(:@records).fetch(record_label)
    record['stdout_sha256'] = record['stdout_sha256'] == ('0' * 64) ? ('1' * 64) : ('0' * 64)
    expect_capture_rejection!('raw record stdout_sha256 mismatch',
      "#{record_label} summary-stage reference differs from raw record") do
      record_auditor.send(:validate_stage_references!)
    end
    true
  end

  def self.auditor_with_raw_records(root)
    auditor = A::Auditor.new(root, mode: :full_matrix)
    auditor.send(:summary_contract!)
    auditor.send(:pins!)
    auditor.send(:topology!)
    auditor.send(:invocations!)
    auditor
  end

  def self.expect_capture_rejection!(mutation, expected_diagnostic)
    begin
      yield
    rescue StandardError => error
      unless error.message == expected_diagnostic
        raise Error, "#{mutation} reached unintended diagnostic: expected #{expected_diagnostic.inspect}, got #{error.class}: #{error.message}"
      end
      return true
    end
    raise Error, "capture auditor accepted mutation: #{mutation}"
  end

  def self.summary(full_matrix:, cells:)
    probe = PROBE.allocate
    {
      '@full_matrix' => full_matrix,
      '@cases' => cells,
      '@invocations' => [],
      '@root' => '/private/tmp/w283-instrumentation-seed',
      '@binary' => M::BINARY,
      '@binary_sha_before' => M::RUNTIME_PIN.fetch(:sha256),
      '@binary_sha_after' => M::RUNTIME_PIN.fetch(:sha256),
      '@binary_bytes_before' => M::RUNTIME_PIN.fetch(:bytes),
      '@binary_bytes_after' => M::RUNTIME_PIN.fetch(:bytes),
      '@source_root' => M::W280::SOURCE_ROOT,
      '@source_revision_before' => M::W280::SOURCE_REVISION,
      '@source_revision_after' => M::W280::SOURCE_REVISION,
      '@upstream_hashes_before' => {'seed' => 'pinned'},
      '@upstream_hashes_after' => {'seed' => 'pinned'},
      '@helper' => '/private/tmp/w283-helper-seed',
      '@helper_sha_argument' => 'a' * 64,
      '@helper_sha_before' => 'a' * 64,
      '@helper_sha_after' => 'a' * 64,
      '@local_source_hashes_before' => {'probe' => 'pinned'},
      '@local_source_hashes_after' => {'probe' => 'pinned'},
    }.each { |name, value| probe.instance_variable_set(name, value) }
    probe.send(:build_summary)
  end

  def self.stock_cells(status: STOCK_EXACT)
    CELL_IDS.to_h { |id| [id, {case_id: id, status: status}] }
  end

  def self.full_cells(generated_status: GENERATED_EXACT)
    CELL_IDS.to_h do |id|
      [id, {case_id: id, status: STOCK_EXACT,
        library_stock_read: {status: READ_EXACT},
        library_generated: {status: generated_status}}]
    end
  end

  def self.assert_status!(summary, expected)
    actual = summary.fetch(:status)
    raise Error, "expected W283 summary status #{expected}, got #{actual}" unless actual == expected
    true
  end

  def self.reject_audit_status!(summary, mode)
    auditor = A::Auditor.allocate
    begin
      auditor.send(:summary_status!, summary.transform_keys(&:to_s), mode)
    rescue A::Error, VerifyCompactLowCardinalityBulkW282Capture::Error
      return true
    end
    raise Error, "capture auditor accepted non-exact status #{summary[:status]} as #{mode}"
  end

  def self.settings_substitution_checks!
    M::MODES.each do |mode|
      M::MARK_FORMATS.each do |mark|
        M::PROFILES.each do |profile|
          probe = PROBE.allocate
          probe.instance_variable_set(:@active_profile, profile)
          probe.instance_variable_set(:@active_variant_mode, mode)
          settings = probe.send(:settings, mark)
          expected = "use_compact_variant_discriminators_serialization=#{M::MODE_VALUES.fetch(mode)}"
          matches = settings.split(', ').grep(/\Ause_compact_variant_discriminators_serialization=/)
          suspicious = settings.split(', ').grep(/\Aallow_suspicious_low_cardinality_types=/)
          raise Error, "#{mode}/#{mark}/#{profile} mode setting is not exactly substituted" unless matches == [expected]
          raise Error, "#{mode}/#{mark}/#{profile} suspicious LC setting differs" unless suspicious == ['allow_suspicious_low_cardinality_types=1']
        end
      end
    end
    true
  end
end

if $PROGRAM_NAME == __FILE__
  options = {}
  OptionParser.new do |parser|
    parser.on('--evidence-root ROOT', 'audit a pristine W283 full_matrix capture and run in-memory mutants') do |root|
      options[:evidence_root] = root
    end
  end.parse!
  exit(VerifyCompactVariantBulkW283Instrumentation.run(evidence_root: options[:evidence_root]) ? 0 : 1)
end
