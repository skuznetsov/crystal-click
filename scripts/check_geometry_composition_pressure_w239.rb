#!/usr/bin/env ruby
# Pressure-test the W239 raw evidence auditor using isolated copies of a
# genuine stock/paired capture. Original evidence roots remain read-only.

require 'digest'
require 'find'
require 'json'
require 'optparse'
require_relative 'check_geometry_composition_evidence_w239'
require_relative 'check_custom_geo_recursive_pressure_w238'

module CheckGeometryCompositionPressureW239
  P = CheckGeometryCompositionEvidenceW239::P
  W = CheckGeometryCompositionEvidenceW239::W
  A = CheckCustomGeoRecursivePressureW238
  AUDIT = CheckGeometryCompositionEvidenceW239
  TMP_ROOT = File.realpath('/private/tmp').freeze
  PRESSURE_PREFIX = '/private/tmp/crystal-click-w239-pressure.'.freeze

  extend self

  def fail!(message)
    raise ArgumentError, "W239 pressure probe: #{message}"
  end

  def require_true(condition, message)
    fail!(message) unless condition
  end

  def canonical_root(path, prefix, label, empty: false)
    full = File.expand_path(path)
    require_true(File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full,
      "#{label} is absent, symlinked, or noncanonical: #{full}")
    require_true(File.dirname(full) == TMP_ROOT && full.start_with?(prefix),
      "#{label} must be a direct /private/tmp child with its fixed prefix")
    require_true(Dir.children(full).empty?, "#{label} must be a fresh empty directory") if empty
    full
  end

  def canonical_directory!(path, label)
    require_true(File.directory?(path) && !File.symlink?(path) && File.realpath(path) == path,
      "#{label} is absent, symlinked, or noncanonical: #{path}")
  end

  # Native Atomic bookkeeping uses a small, exact set of relative links. Keep
  # these allowed while proving that no link escapes this evidence root.
  def evidence_housekeeping_links!(root, forbidden_root: nil)
    root = File.realpath(root)
    native_root = File.join(root, 'stores', 'native')
    store_root = File.join(native_root, 'store')
    %w[stores stores/native stores/native/store stores/native/data
      stores/native/data/default stores/native/metadata].each do |relative|
      canonical_directory!(File.join(root, relative), relative)
    end

    expected = P::PROFILES.map { |profile| "stores/native/data/default/w239_native_#{profile.fetch('id')}" }
    expected << 'stores/native/metadata/default'
    expected.sort!
    observed = []
    Find.find(root) do |path|
      observed << path[(root.length + 1)..-1] if File.symlink?(path)
    end
    require_true(observed.sort == expected, 'evidence symlink roster differs from the exact native table/metadata links')

    targets = {}
    expected.each do |relative|
      link_path = File.join(root, relative)
      is_metadata = relative == 'stores/native/metadata/default'
      target = File.readlink(link_path)
      pattern = is_metadata ?
        %r{\A\.\./store/([0-9a-f]{3})/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\z} :
        %r{\A\.\./\.\./store/([0-9a-f]{3})/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\z}
      match = pattern.match(target)
      require_true(match, "native housekeeping link has an unexpected relative target: #{relative}")
      shard, uuid = match.captures
      require_true(shard == uuid[0, 3], "native housekeeping shard differs from UUID: #{relative}")
      shard_path = File.join(store_root, shard)
      target_path = File.join(shard_path, uuid)
      canonical_directory!(shard_path, "native store shard for #{relative}")
      canonical_directory!(target_path, "native store target for #{relative}")
      resolved = File.realpath(link_path)
      require_true(resolved == target_path && resolved.start_with?(store_root + File::SEPARATOR),
        "native housekeeping link escapes the evidence store: #{relative}")
      if forbidden_root
        forbidden_store = File.join(forbidden_root, 'stores', 'native', 'store')
        require_true(!resolved.start_with?(forbidden_store + File::SEPARATOR),
          "cloned housekeeping link resolves into the genuine evidence root: #{relative}")
      end
      targets[relative] = target
    end
    targets
  end

  def rebase_sidecars!(evidence_root, old_evidence, new_evidence, old_generated, new_generated)
    Find.find(evidence_root) do |path|
      next unless File.file?(path) && !File.symlink?(path)
      next unless path.end_with?('.json', '.sql', '.stdout', '.stderr')
      original = File.binread(path)
      changed = A.rewrite_path_bytes(original, old_evidence, new_evidence)
      changed = A.rewrite_path_bytes(changed, old_generated, new_generated)
      require_true(original.bytesize == changed.bytesize, "path rebase changed sidecar length: #{path}")
      File.binwrite(path, changed) unless original == changed
    end

    summary_path = File.join(evidence_root, 'summary.json')
    summary = A.read_json(summary_path)
    helper_stdout = File.binread(File.join(evidence_root, 'invocations', 'helper.stdout'))
    summary['helper_stdout_sha256'] = Digest::SHA256.hexdigest(helper_stdout)
    A.write_json(summary_path, summary)
  end

  def disjoint_regular_files!(source, copy, label)
    count = 0
    Find.find(source) do |path|
      next unless File.file?(path) && !File.symlink?(path)
      relative = path[(source.length + 1)..-1]
      copied_path = File.join(copy, relative)
      require_true(File.file?(copied_path) && !File.symlink?(copied_path),
        "#{label} regular-file copy is missing or symlinked: #{relative}")
      source_stat = File.stat(path)
      copy_stat = File.stat(copied_path)
      require_true(source_stat.dev != copy_stat.dev || source_stat.ino != copy_stat.ino,
        "#{label} copy aliases genuine file storage: #{relative}")
      count += 1
    end
    count
  end

  def clone_pair(evidence_root, generated_root)
    original_links = evidence_housekeeping_links!(evidence_root)
    A.no_symlinks!(generated_root)
    cloned_evidence = A.fresh_peer(evidence_root, W::EVIDENCE_PREFIX)
    cloned_generated = A.fresh_peer(generated_root, W::GENERATED_PREFIX)
    canonical_root(cloned_evidence, W::EVIDENCE_PREFIX, 'cloned evidence root')
    canonical_root(cloned_generated, W::GENERATED_PREFIX, 'cloned generated root')
    require_true(disjoint_regular_files!(evidence_root, cloned_evidence, 'evidence').positive?,
      'evidence clone has no regular files')
    require_true(disjoint_regular_files!(generated_root, cloned_generated, 'generated').positive?,
      'generated clone has no regular files')
    cloned_links = evidence_housekeeping_links!(cloned_evidence, forbidden_root: evidence_root)
    require_true(cloned_links == original_links, 'copied evidence changed the relative housekeeping link roster')
    A.no_symlinks!(cloned_generated)
    rebase_sidecars!(cloned_evidence, evidence_root, cloned_evidence, generated_root, cloned_generated)
    [cloned_evidence, cloned_generated]
  end

  def distinct_copy!(original, copy, label)
    original_stat = File.stat(original)
    copy_stat = File.stat(copy)
    require_true(original_stat.dev != copy_stat.dev || original_stat.ino != copy_stat.ino,
      "copy aliases genuine file storage for #{label}")
  end

  def invoke_audit(evidence_root, stock_result)
    AUDIT.audit_paired!(evidence_root, stock_result)
    { 'result' => 'accepted', 'diagnostic' => nil }
  rescue ArgumentError => error
    { 'result' => 'rejected', 'diagnostic' => error.message }
  rescue StandardError => error
    { 'result' => 'error', 'diagnostic' => "#{error.class}: #{error.message}" }
  end

  def passing_control(evidence_root, stock_result, label)
    result = invoke_audit(evidence_root, stock_result)
    { 'label' => label, 'result' => result.fetch('result'), 'diagnostic' => result.fetch('diagnostic') }
  end

  def run_case(stock_result, genuine_evidence, cloned_evidence, name, expected_diagnostic)
    journal = A::Journal.new
    mutation = nil
    probe_error = nil
    restore_error = nil
    begin
      yield journal
      mutation = invoke_audit(cloned_evidence, stock_result)
    rescue StandardError => error
      probe_error = "#{error.class}: #{error.message}"
    ensure
      begin
        journal.restore
      rescue StandardError => error
        restore_error = "#{error.class}: #{error.message}"
      end
    end
    restored_control = passing_control(cloned_evidence, stock_result, 'restored_clone')
    genuine_control = passing_control(genuine_evidence, stock_result, 'genuine_input')
    diagnostic = mutation && mutation.fetch('diagnostic')
    {
      'case' => name,
      'result' => mutation ? mutation.fetch('result') : 'probe_error',
      'diagnostic' => diagnostic,
      'expected_diagnostic' => expected_diagnostic,
      'intended_condition_rejected' => mutation && mutation.fetch('result') == 'rejected' &&
        diagnostic.to_s.include?(expected_diagnostic),
      'probe_error' => probe_error,
      'restore_error' => restore_error,
      'controls' => [restored_control, genuine_control],
      'controls_passed' => restore_error.nil? &&
        [restored_control, genuine_control].all? { |control| control.fetch('result') == 'accepted' },
    }
  end

  def mutate_wrong_rowbinary!(journal, evidence_root)
    summary_path = File.join(evidence_root, 'summary.json')
    summary = journal.json(summary_path)
    profile = summary.fetch('profiles').find { |row| row.fetch('id') == 'geometry' }
    witness = profile.fetch('rowbinary_windows').fetch('full')
    capture = File.expand_path(witness.fetch('path'))
    bytes = File.binread(capture)
    require_true(bytes.bytesize > 8, 'full Geometry RowBinary capture is unexpectedly short')
    changed = bytes.dup
    changed.setbyte(0, changed.getbyte(0) ^ 0x01)
    journal.write(capture, changed)
    witness['bytes'] = changed.bytesize
    witness['observed_hex'] = changed.unpack1('H*')
    witness['sha256'] = Digest::SHA256.hexdigest(changed)
    witness['matches'] = true
    # Keep literal_hex independent; coherently update only the actual-output witness.
    journal.write_json(summary_path, summary)
  end

  def mutate_summary_process_exit!(journal, evidence_root)
    summary_path = File.join(evidence_root, 'summary.json')
    summary = journal.json(summary_path)
    record = summary.fetch('processes').find { |row| row.fetch('label') == 'native-capture-all' }
    require_true(record && record.fetch('classification') == 'process_success' && record.fetch('exitstatus') == 0,
      'native capture summary is not a normal exit-0 baseline')
    record['classification'] = 'process_nonzero_or_signaled_exit'
    record['exitstatus'] = 17
    journal.write_json(summary_path, summary)
  end

  def main(argv)
    options = {}
    parser = OptionParser.new do |opts|
      opts.banner = <<~USAGE
        Usage:
          ruby scripts/check_geometry_composition_pressure_w239.rb --stock-root STOCK_ROOT --evidence-root PAIRED_ROOT --output-root EMPTY_PRESSURE_ROOT
        Audits isolated copies only; no ClickHouse process is run and genuine roots are not mutated.
      USAGE
      opts.on('--stock-root PATH', 'Already-qualified W239 stock capture') { |value| options[:stock_root] = value }
      opts.on('--evidence-root PATH', 'Already-qualified W239 paired capture') { |value| options[:evidence_root] = value }
      opts.on('--output-root EMPTY_DIR', 'Fresh direct /private/tmp report directory') { |value| options[:output_root] = value }
    end
    parser.parse!(argv)
    require_true(argv.empty? && %i[stock_root evidence_root output_root].all? { |key| options.key?(key) }, parser.to_s)

    stock_root = canonical_root(options.fetch(:stock_root), P::OUTPUT_PREFIX, 'stock root')
    evidence_root = canonical_root(options.fetch(:evidence_root), W::EVIDENCE_PREFIX, 'paired evidence root')
    output_root = canonical_root(options.fetch(:output_root), PRESSURE_PREFIX, 'pressure output root', empty: true)
    stock_result = AUDIT.audit_stock!(stock_root)
    genuine_control = passing_control(evidence_root, stock_result, 'genuine_baseline')
    require_true(genuine_control.fetch('result') == 'accepted',
      "genuine paired input did not pass: #{genuine_control.fetch('diagnostic')}")

    summary = A.read_json(File.join(evidence_root, 'summary.json'))
    generated_root = canonical_root(summary.fetch('generated_root'), W::GENERATED_PREFIX, 'generated root')
    cloned_evidence, cloned_generated = clone_pair(evidence_root, generated_root)
    cloned_baseline = passing_control(cloned_evidence, stock_result, 'cloned_baseline')
    require_true(cloned_baseline.fetch('result') == 'accepted',
      "rebased cloned input did not pass: #{cloned_baseline.fetch('diagnostic')}")

    wrong_output_case = run_case(stock_result, evidence_root, cloned_evidence,
      'zero-exit wrong literal RowBinary with matching output witness',
      'captured RowBinary differs from independent literal for geometry/full') do |journal|
      summary_path = File.join(cloned_evidence, 'summary.json')
      row = journal.json(summary_path).fetch('profiles').find { |profile| profile.fetch('id') == 'geometry' }
      capture = File.expand_path(row.fetch('rowbinary_windows').fetch('full').fetch('path'))
      genuine_capture = File.join(evidence_root, 'captures', 'native-rowbinary', 'geometry-full.rowbinary')
      distinct_copy!(genuine_capture, capture, 'full Geometry RowBinary')
      mutate_wrong_rowbinary!(journal, cloned_evidence)
    end
    status_contradiction_case = run_case(stock_result, evidence_root, cloned_evidence,
      'summary process exit contradicts raw status sidecar',
      'summary status differs from raw status sidecar for native-capture-all') do |journal|
      summary_path = File.join(cloned_evidence, 'summary.json')
      distinct_copy!(File.join(evidence_root, 'summary.json'), summary_path, 'summary.json')
      mutate_summary_process_exit!(journal, cloned_evidence)
    end

    cases = [wrong_output_case, status_contradiction_case]
    failures = []
    cases.each do |row|
      failures << "intended mutation was not rejected: #{row.fetch('case')}" unless row.fetch('intended_condition_rejected')
      failures << "restored or genuine baseline failed: #{row.fetch('case')}" unless row.fetch('controls_passed')
      failures << "mutation setup failed: #{row.fetch('case')}" if row.fetch('probe_error')
      failures << "mutation restore failed: #{row.fetch('case')}" if row.fetch('restore_error')
    end
    report = {
      'format' => 'geometry_composition_w239_pressure_v1',
      'scope' => {
        'tests' => 'zero-exit wrong RowBinary against independent literals, and summary/raw exitstatus consistency',
        'native_processes_run' => false,
        'genuine_roots_mutated' => false,
        'copied_baseline_required' => true,
        'execution_provenance' => 'not established; a fully coordinated rewrite of every raw/generated/attached/snapshot copy and all matching witnesses can evade a consistency auditor without an independent immutable anchor',
      },
      'genuine_baseline' => genuine_control,
      'cloned_baseline' => cloned_baseline,
      'cases' => cases,
      'rejected_in_scope_cases' => cases.select { |row| row.fetch('intended_condition_rejected') }.map { |row| row.fetch('case') },
      'cloned_evidence_root' => cloned_evidence,
      'cloned_generated_root' => cloned_generated,
      'failures' => failures,
    }
    A.write_json(File.join(output_root, 'pressure-report.json'), report)
    puts JSON.pretty_generate(report)
    failures.empty? ? 0 : 1
  rescue StandardError => error
    warn "W239 pressure probe failed: #{error.class}: #{error.message}"
    2
  end
end

exit(CheckGeometryCompositionPressureW239.main(ARGV)) if $PROGRAM_NAME == __FILE__
