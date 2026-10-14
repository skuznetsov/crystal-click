#!/usr/bin/env ruby
# Pure-Ruby falsifiers for W282 summary classification and capture-auditor guards.

require_relative 'probe_compact_low_cardinality_bulk_w282_matrix'
require_relative 'verify_compact_low_cardinality_bulk_w282_capture'

module VerifyCompactLowCardinalityBulkW282Instrumentation
  M = ProbeCompactLowCardinalityBulkW282Matrix
  A = VerifyCompactLowCardinalityBulkW282Capture
  PROBE = M::Probe
  CELL_IDS = M::MARK_FORMATS.flat_map do |mark|
    M::PROFILES.map { |profile| "#{M::CASE}_#{mark}_#{profile}" }
  end.freeze

  STOCK_EXACT = 'exact_native_values'.freeze
  READ_EXACT = 'exact_public_recursive_reads'.freeze
  GENERATED_EXACT = 'exact_generated_native_interop'.freeze
  ADMISSION_RED = 'library_admission_rejection_captured'.freeze
  INFRA_FAILURE = 'helper_infrastructure_failure'.freeze

  class Error < StandardError; end

  def self.run
    raise Error, 'matrix does not expose exactly four stock cells' unless CELL_IDS.size == 4 && CELL_IDS.uniq == CELL_IDS
    checks = []

    stock = summary(full_matrix: false, cells: stock_cells)
    assert_status!(stock, 'stock_native_matrix_exact')
    checks << 'four-cell-stock-success'

    full = summary(full_matrix: true, cells: full_cells)
    assert_status!(full, 'generated_native_interop_matrix_exact')
    checks << 'four-cell-full-success-requires-public-reads-and-generated-writes'

    missing_read_cells = full_cells
    missing_read_cells.fetch(CELL_IDS.first)[:library_stock_read][:status] = 'helper_incomplete'
    assert_status!(summary(full_matrix: true, cells: missing_read_cells), 'incomplete_or_discrepant')
    missing_generated_cells = full_cells
    missing_generated_cells.fetch(CELL_IDS.last)[:library_generated][:status] = 'probe_error'
    assert_status!(summary(full_matrix: true, cells: missing_generated_cells), 'incomplete_or_discrepant')
    checks << 'single-missing-read-or-generated-cell-blocks-full-status'

    red_cells = full_cells(generated_status: ADMISSION_RED)
    red = summary(full_matrix: true, cells: red_cells)
    assert_status!(red, 'generated_admission_rejection_captured')
    reject_audit_status!(red, :full_matrix)
    checks << 'admission-red-is-captured-but-not-compatibility'

    infra_cells = full_cells
    infra_cells.fetch(CELL_IDS.last)[:library_generated][:status] = INFRA_FAILURE
    infra = summary(full_matrix: true, cells: infra_cells)
    assert_status!(infra, 'probe_infrastructure_failure')
    reject_audit_status!(infra, :full_matrix)
    checks << 'infrastructure-failure-cannot-be-promoted'

    omitted = stock_cells
    omitted.delete(CELL_IDS.last)
    assert_status!(summary(full_matrix: false, cells: omitted), 'incomplete_or_discrepant')
    checks << 'omitted-cell-is-incomplete'

    rejected = CELL_IDS.to_h do |id|
      [id, {case_id: id, status: 'create_server_exception'}]
    end
    stock_red = summary(full_matrix: false, cells: rejected)
    assert_status!(stock_red, 'stock_schema_rejection_captured')
    reject_audit_status!(stock_red, :stock_only)
    checks << 'stock-schema-rejection-is-a-blocked-probe'

    unless A::Auditor.self_test!
      raise Error, 'capture auditor pure-Ruby falsifier suite failed'
    end
    checks << 'capture-auditor-raw-sidecar-profile-window-mark-and-prefix-mutants'

    puts "W282 instrumentation Ruby-only checks passed: #{checks.join(',')}; no capture reads, native calls, or subprocesses"
    true
  rescue StandardError => e
    warn "W282 instrumentation check failed: #{e.class}: #{e.message}"
    false
  end

  def self.summary(full_matrix:, cells:)
    probe = PROBE.allocate
    {
      '@full_matrix' => full_matrix,
      '@cases' => cells,
      '@invocations' => [],
      '@root' => '/private/tmp/w282-instrumentation-seed',
      '@binary' => M::W280::BINARY,
      '@binary_sha_before' => M::W280::BINARY_SHA256,
      '@binary_sha_after' => M::W280::BINARY_SHA256,
      '@source_root' => M::W280::SOURCE_ROOT,
      '@source_revision_before' => M::W280::SOURCE_REVISION,
      '@source_revision_after' => M::W280::SOURCE_REVISION,
      '@upstream_hashes_before' => {'seed' => 'pinned'},
      '@upstream_hashes_after' => {'seed' => 'pinned'},
      '@helper' => '/private/tmp/w282-helper-seed',
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
    raise Error, "expected summary status #{expected}, got #{actual}" unless actual == expected
    true
  end

  def self.reject_audit_status!(summary, mode)
    auditor = A::Auditor.allocate
    begin
      auditor.send(:summary_status!, summary.transform_keys(&:to_s), mode)
    rescue A::Error
      return true
    end
    raise Error, "capture auditor accepted non-exact status #{summary[:status]} as #{mode}"
  end
end

if $PROGRAM_NAME == __FILE__
  exit(VerifyCompactLowCardinalityBulkW282Instrumentation.run ? 0 : 1)
end
