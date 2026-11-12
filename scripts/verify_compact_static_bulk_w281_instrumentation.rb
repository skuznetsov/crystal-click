#!/usr/bin/env ruby
# Pure-Ruby regression checks for W281 evidence classification. This script
# fabricates matrix state in memory and never launches the native server/helper.

require_relative 'probe_compact_static_bulk_w281_matrix'

module VerifyCompactStaticBulkW281Instrumentation
  Matrix = ProbeCompactStaticBulkW281Matrix
  Probe = Matrix::Probe

  module_function

  def case_entry(read_status: nil, generated_status: 'library_admission_rejection_captured')
    entry = {status: 'exact_native_values', library_generated: {status: generated_status}}
    entry[:library_stock_read] = {status: read_status} if read_status
    entry
  end

  def probe_for(cases:, full_matrix: true, guard_status: 'rejected_expected_code_370')
    probe = Probe.allocate
    probe.instance_variable_set(:@cases, cases)
    probe.instance_variable_set(:@full_matrix, full_matrix)
    probe.instance_variable_set(:@nothing_guard, {status: guard_status})
    probe.instance_variable_set(:@binary, '/fixture/clickhouse')
    probe.instance_variable_set(:@binary_sha_before, 'fixture-sha')
    probe.instance_variable_set(:@binary_sha_after, 'fixture-sha')
    probe.instance_variable_set(:@source_root, '/fixture/source')
    probe.instance_variable_set(:@source_revision_before, 'fixture-revision')
    probe.instance_variable_set(:@source_revision_after, 'fixture-revision')
    probe.instance_variable_set(:@upstream_hashes_before, {})
    probe.instance_variable_set(:@upstream_hashes_after, {})
    probe.instance_variable_set(:@helper_argument, '/fixture/helper')
    probe.instance_variable_set(:@helper_sha_argument, 'fixture-helper-sha')
    probe.instance_variable_set(:@helper_sha_before, 'fixture-helper-sha')
    probe.instance_variable_set(:@helper_sha_after, 'fixture-helper-sha')
    probe.instance_variable_set(:@local_source_hashes_before, {})
    probe.instance_variable_set(:@local_source_hashes_after, {})
    probe.instance_variable_set(:@invocations, [])
    probe.instance_variable_set(:@root, '/fixture/evidence')
    probe
  end

  def four_cases(read_status: 'exact_public_recursive_and_typed_reads',
                 generated_status: 'library_admission_rejection_captured')
    Matrix::MARK_FORMATS.product(Matrix::PROFILES).to_h do |mark_format, profile|
      ["#{mark_format}_#{profile}", case_entry(read_status: read_status,
        generated_status: generated_status)]
    end
  end

  def summary_status(cases:, full_matrix: true, guard_status: 'rejected_expected_code_370')
    probe_for(cases: cases, full_matrix: full_matrix, guard_status: guard_status).send(:build_summary).fetch(:status)
  end

  def checks
    results = []
    check = lambda do |name, expected, &assertion|
      actual = assertion.call
      results << [name, actual == expected, expected, actual]
    rescue StandardError => error
      results << [name, false, expected, "#{error.class}: #{error.message}"]
    end

    check.call('infrastructure beats partial admission report', 'helper_infrastructure_failure') do
      probe = Probe.allocate
      probe.send(:classify_helper_error, {
        state: 'infrastructure_failure',
        report: {'error_class' => 'UnsupportedFormatError',
          'error' => 'not admitted: fixture shape outside the captured admission'},
        error: 'helper process still running'})
    end

    check.call('omitted stock read cannot be expected RED', 'incomplete_or_discrepant') do
      cases = four_cases
      cases.each_value { |entry| entry.delete(:library_stock_read) }
      summary_status(cases: cases)
    end

    check.call('stock helper infrastructure failure dominates writer RED', 'probe_infrastructure_failure') do
      summary_status(cases: four_cases(read_status: 'helper_infrastructure_failure'))
    end

    check.call('unavailable stock part cannot be expected RED', 'incomplete_or_discrepant') do
      summary_status(cases: four_cases(read_status: 'unavailable_stock_part'))
    end

    check.call('generated helper infrastructure failure dominates', 'probe_infrastructure_failure') do
      summary_status(cases: four_cases(generated_status: 'helper_infrastructure_failure'))
    end

    check.call('empty full-matrix case set is not vacuous success', 'incomplete_or_discrepant') do
      summary_status(cases: {})
    end

    check.call('all stock reads plus all writer admission RED is captured RED only',
      'generated_admission_rejection_captured') do
      status = summary_status(cases: four_cases)
      raise 'captured RED status lost its explicit run-success classification' unless
        Matrix::SUCCESS_STATUSES.include?(status)
      raise 'captured RED was equated with native compatibility' if
        status == 'generated_native_interop_matrix_exact'
      status
    end

    check.call('exact stock-only result remains exact', 'stock_native_matrix_exact') do
      summary_status(cases: four_cases(read_status: nil, generated_status: nil), full_matrix: false)
    end

    check.call('exact generated interop requires exact reads and writes',
      'generated_native_interop_matrix_exact') do
      summary_status(cases: four_cases(generated_status: 'exact_generated_native_interop'))
    end

    results
  end

  results = checks
  failures = results.reject { |_, passed, *_| passed }
  puts "W281 instrumentation assertions: #{results.size - failures.size}/#{results.size} passed; failures=#{failures.size}."
  failures.each do |name, _, expected, actual|
    puts "FAIL #{name}: expected=#{expected.inspect} actual=#{actual.inspect}"
  end
  exit(failures.empty? ? 0 : 1)
end
