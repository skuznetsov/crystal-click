#!/usr/bin/env ruby
# Pressure-test the W238 raw evidence auditor using isolated copies of a
# genuine paired capture. The original evidence and generated parts are never
# modified; every mutation is restored before passing controls are rerun.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'optparse'
require 'securerandom'

module CheckCustomGeoRecursivePressureW238
  EVIDENCE_PREFIX = '/private/tmp/crystal-click-w238-evidence.'.freeze
  GENERATED_PREFIX = '/private/tmp/crystal-click-w238-generated.'.freeze
  TMP_ROOT = File.realpath('/private/tmp').freeze
  ALPHABET = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'.freeze

  extend self

  def fail!(message)
    raise ArgumentError, "W238 pressure probe: #{message}"
  end

  def require_true(condition, message)
    fail!(message) unless condition
  end

  def canonical_root(path, prefix, label)
    full = File.expand_path(path)
    require_true(File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full,
      "#{label} is absent, symlinked, or noncanonical: #{full}")
    require_true(File.dirname(full) == TMP_ROOT && full.start_with?(prefix),
      "#{label} must be a direct /private/tmp child with its fixed prefix")
    full
  end

  def no_symlinks!(root)
    Find.find(root) do |path|
      fail!("input tree contains a symlink: #{path}") if File.symlink?(path)
    end
  end

  def profile_ids
    CustomGeoW238Fixtures.profiles.map { |profile| profile.fetch('id') }
  end

  def canonical_directory!(path, label)
    require_true(File.directory?(path) && !File.symlink?(path) && File.realpath(path) == path,
      "#{label} is absent, symlinked, or noncanonical: #{path}")
  end

  def evidence_housekeeping_links!(root, forbidden_root: nil)
    root = File.realpath(root)
    native_root = File.join(root, 'stores', 'native')
    store_root = File.join(native_root, 'store')
    canonical_directory!(File.join(root, 'stores'), 'stores directory')
    canonical_directory!(native_root, 'native store root')
    canonical_directory!(store_root, 'native data store')
    canonical_directory!(File.join(native_root, 'data'), 'native data directory')
    canonical_directory!(File.join(native_root, 'data', 'default'), 'native default data directory')
    canonical_directory!(File.join(native_root, 'metadata'), 'native metadata directory')

    expected = profile_ids.map do |id|
      "stores/native/data/default/w238_native_#{id}"
    end
    expected << 'stores/native/metadata/default'
    expected.sort!

    observed = []
    Find.find(root) do |path|
      observed << path[(root.length + 1)..-1] if File.symlink?(path)
    end
    require_true(observed.sort == expected,
      "evidence symlink roster differs from the 13 native table links plus metadata/default")

    targets = {}
    expected.each do |relative_path|
      link_path = File.join(root, relative_path)
      require_true(File.symlink?(link_path), "expected Atomic housekeeping link is missing: #{relative_path}")
      target = File.readlink(link_path)
      pattern = relative_path == 'stores/native/metadata/default' ?
        %r{\A\.\./store/([0-9a-f]{3})/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\z} :
        %r{\A\.\./\.\./store/([0-9a-f]{3})/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\z}
      match = pattern.match(target)
      require_true(match, "Atomic link target is not the expected relative store path: #{relative_path}")
      shard, uuid = match.captures
      require_true(shard == uuid[0, 3], "Atomic link shard does not match its UUID: #{relative_path}")

      shard_path = File.join(store_root, shard)
      resolved_path = File.join(shard_path, uuid)
      canonical_directory!(shard_path, "Atomic store shard for #{relative_path}")
      canonical_directory!(resolved_path, "Atomic store target for #{relative_path}")
      resolved = File.realpath(link_path)
      require_true(resolved == resolved_path && resolved.start_with?(store_root + File::SEPARATOR),
        "Atomic link escapes its evidence root's native store: #{relative_path}")
      if forbidden_root
        forbidden_store = File.join(forbidden_root, 'stores', 'native', 'store')
        require_true(!resolved.start_with?(forbidden_store + File::SEPARATOR),
          "cloned Atomic link resolves into the original evidence root: #{relative_path}")
      end
      targets[relative_path] = target
    end
    targets
  end

  def fresh_peer(source, prefix)
    suffix_length = source.bytesize - prefix.bytesize
    require_true(suffix_length.positive?, "root suffix is empty: #{source}")
    loop do
      suffix = Array.new(suffix_length) { ALPHABET[SecureRandom.random_number(ALPHABET.length)] }.join
      target = "#{prefix}#{suffix}"
      next if File.exist?(target) || File.symlink?(target)
      require_true(source.bytesize == target.bytesize, 'clone path must preserve exact byte length')
      FileUtils.cp_r(source, target)
      require_true(File.directory?(target) && !File.symlink?(target) && File.realpath(target) == target,
        "clone did not create a canonical root: #{target}")
      return target
    end
  end

  def rewrite_path_bytes(bytes, old_path, new_path)
    require_true(old_path.bytesize == new_path.bytesize, 'path rebase must preserve sidecar lengths')
    bytes.gsub(old_path.b, new_path.b)
  end

  def read_json(path)
    JSON.parse(File.binread(path).force_encoding(Encoding::UTF_8))
  end

  def write_json(path, object)
    File.binwrite(path, JSON.pretty_generate(object) + "\n")
  end

  def rebase_text_sidecars!(evidence_root, old_evidence, new_evidence, old_generated, new_generated)
    Find.find(evidence_root) do |path|
      next unless File.file?(path) && !File.symlink?(path)
      next unless path.end_with?('.json', '.sql', '.stdout', '.stderr')
      bytes = File.binread(path)
      changed = rewrite_path_bytes(bytes, old_evidence, new_evidence)
      changed = rewrite_path_bytes(changed, old_generated, new_generated)
      require_true(bytes.bytesize == changed.bytesize, "rebased sidecar length changed: #{path}")
      File.binwrite(path, changed) unless changed == bytes
    end

    summary_path = File.join(evidence_root, 'summary.json')
    summary = read_json(summary_path)
    helper_base = File.join(evidence_root, 'invocations', 'helper')
    helper_stdout = File.binread(helper_base + '.stdout')
    helper_status = read_json(helper_base + '.status.json')
    helper_argv = read_json(helper_base + '.argv.json').fetch('argv')
    helper_status['stdout_bytes'] = helper_stdout.bytesize
    write_json(helper_base + '.status.json', helper_status)
    summary['helper_stdout_sha256'] = Digest::SHA256.hexdigest(helper_stdout)
    summary['helper_process'] = helper_status.merge('argv' => helper_argv)
    write_json(summary_path, summary)
  end

  def clone_pair(evidence_root, generated_root)
    original_links = evidence_housekeeping_links!(evidence_root)
    no_symlinks!(generated_root)
    cloned_evidence = fresh_peer(evidence_root, EVIDENCE_PREFIX)
    cloned_generated = fresh_peer(generated_root, GENERATED_PREFIX)
    cloned_links = evidence_housekeeping_links!(cloned_evidence, forbidden_root: evidence_root)
    require_true(cloned_links == original_links,
      'cp_r did not retain the exact relative Atomic housekeeping links')
    no_symlinks!(cloned_generated)
    rebase_text_sidecars!(cloned_evidence, evidence_root, cloned_evidence, generated_root, cloned_generated)
    [cloned_evidence, cloned_generated]
  end

  class Journal
    def initialize
      @originals = {}
    end

    def write(path, bytes)
      @originals[path] ||= File.binread(path)
      File.binwrite(path, bytes)
    end

    def json(path)
      JSON.parse(File.binread(path).force_encoding(Encoding::UTF_8))
    end

    def write_json(path, object)
      write(path, JSON.pretty_generate(object) + "\n")
    end

    def restore
      errors = []
      @originals.each do |path, bytes|
        begin
          File.binwrite(path, bytes)
        rescue StandardError => error
          errors << "#{path}: #{error.class}: #{error.message}"
        end
      end
      @originals.clear
      CheckCustomGeoRecursivePressureW238.fail!("could not restore every mutated file: #{errors.join('; ')}") unless errors.empty?
    end
  end

  def invocation_stem(evidence_root, label)
    Dir.glob(File.join(evidence_root, 'invocations', '*.argv.json')).each do |path|
      metadata = read_json(path)
      return File.basename(path, '.argv.json') if metadata.fetch('label') == label
    end
    fail!("raw invocation not found: #{label}")
  end

  def sync_native_process!(journal, evidence_root, stem)
    base = File.join(evidence_root, 'invocations', stem)
    status = journal.json(base + '.status.json')
    status['stdout_bytes'] = File.binread(base + '.stdout').bytesize
    journal.write_json(base + '.status.json', status)
    summary_path = File.join(evidence_root, 'summary.json')
    summary = journal.json(summary_path)
    label = status.fetch('label')
    index = summary.fetch('processes').index { |record| record.fetch('label') == label }
    fail!("summary process row not found: #{label}") unless index
    summary['processes'][index] = status
    journal.write_json(summary_path, summary)
  end

  def invoke_audit(auditor, evidence_root)
    auditor.audit_paired!(evidence_root)
    { 'result' => 'accepted', 'diagnostic' => nil }
  rescue ArgumentError => error
    raise unless error.message.start_with?('W238 evidence audit failed:')
    { 'result' => 'rejected', 'diagnostic' => error.message }
  end

  def passing_control(auditor, evidence_root, label)
    audit = invoke_audit(auditor, evidence_root)
    {
      'label' => label,
      'result' => audit.fetch('result'),
      'diagnostic' => audit.fetch('diagnostic'),
    }
  rescue StandardError => error
    { 'label' => label, 'result' => 'error', 'diagnostic' => "#{error.class}: #{error.message}" }
  end

  def run_case(auditor, genuine_evidence_root, cloned_evidence_root, name, scope)
    journal = Journal.new
    mutation_audit = nil
    probe_error = nil
    restore_error = nil
    begin
      yield journal
      mutation_audit = invoke_audit(auditor, cloned_evidence_root)
    rescue StandardError => error
      probe_error = "#{error.class}: #{error.message}"
    ensure
      begin
        journal.restore
      rescue StandardError => error
        restore_error = "#{error.class}: #{error.message}"
      end
    end

    restored_clone = passing_control(auditor, cloned_evidence_root, 'restored_clone')
    genuine_control = passing_control(auditor, genuine_evidence_root, 'genuine_input')
    result = mutation_audit ? mutation_audit.fetch('result') : 'probe_error'
    {
      'case' => name,
      'scope' => scope,
      'result' => result,
      'diagnostic' => mutation_audit && mutation_audit.fetch('diagnostic'),
      'probe_error' => probe_error,
      'restore_error' => restore_error,
      'controls' => [restored_clone, genuine_control],
      'controls_passed' => restore_error.nil? &&
        [restored_clone, genuine_control].all? { |control| control.fetch('result') == 'accepted' },
    }
  end

  def change_check_to_zero!(journal, evidence_root)
    stem = invocation_stem(evidence_root, 'native-capture-all')
    stdout_path = File.join(evidence_root, 'invocations', "#{stem}.stdout")
    stdout = File.binread(stdout_path)
    needle = "W238_NATIVE_CHECK_BEGIN_point\nall_1_1_0\t1\t\nW238_NATIVE_CHECK_END_point"
    replacement = needle.sub("\t1\t\n", "\t0\t\n")
    require_true(stdout.scan(needle).length == 1, 'expected one point CHECK block in raw stdout')
    journal.write(stdout_path, stdout.sub(needle, replacement))
    summary_path = File.join(evidence_root, 'summary.json')
    summary = journal.json(summary_path)
    row = summary.fetch('profiles').find { |profile| profile.fetch('id') == 'point' }
    row['native_check_output'] = "all_1_1_0\t0\t\n"
    journal.write_json(summary_path, summary)
    sync_native_process!(journal, evidence_root, stem)
  end

  def change_native_schema!(journal, evidence_root)
    stem = invocation_stem(evidence_root, 'native-capture-all')
    stdout_path = File.join(evidence_root, 'invocations', "#{stem}.stdout")
    stdout = File.binread(stdout_path)
    needle = "payload\tMultiPolygon\n"
    require_true(stdout.scan(needle).length == 1, 'expected one MultiPolygon schema row in raw stdout')
    journal.write(stdout_path, stdout.sub(needle, "payload\tPolygon\n"))
    summary_path = File.join(evidence_root, 'summary.json')
    summary = journal.json(summary_path)
    row = summary.fetch('profiles').find { |profile| profile.fetch('id') == 'multi_polygon' }
    row['native_schema_rows'] = ["pk\tUInt64", "payload\tPolygon"]
    journal.write_json(summary_path, summary)
    sync_native_process!(journal, evidence_root, stem)
  end

  def mutate_rowbinary!(journal, evidence_root)
    summary_path = File.join(evidence_root, 'summary.json')
    summary = journal.json(summary_path)
    row = summary.fetch('profiles').find { |profile| profile.fetch('id') == 'point' }
    witness = row.fetch('rowbinary_windows').fetch('full')
    path = File.expand_path(witness.fetch('path'))
    bytes = File.binread(path)
    require_true(bytes.bytesize > 8, 'point full RowBinary capture is unexpectedly short')
    changed = bytes.dup
    changed.setbyte(8, changed.getbyte(8) ^ 0x01)
    journal.write(path, changed)
    witness['bytes'] = changed.bytesize
    witness['observed_hex'] = changed.unpack1('H*')
    witness['sha256'] = Digest::SHA256.hexdigest(changed)
    witness['matches'] = true
    journal.write_json(summary_path, summary)
  end

  def forge_timeout_status!(journal, evidence_root)
    stem = invocation_stem(evidence_root, 'native-capture-all')
    base = File.join(evidence_root, 'invocations', stem)
    status = journal.json(base + '.status.json')
    status['classification'] = 'process_success'
    status['exitstatus'] = 0
    status['timed_out'] = true
    status['signaled'] = true
    status['termsig'] = 9
    status['spawn_error'] = nil
    journal.write_json(base + '.status.json', status)
    summary_path = File.join(evidence_root, 'summary.json')
    summary = journal.json(summary_path)
    index = summary.fetch('processes').index { |record| record.fetch('label') == status.fetch('label') }
    fail!('native-capture summary process row is missing') unless index
    summary['processes'][index] = status
    journal.write_json(summary_path, summary)
  end

  def remove_helper_profile!(journal, evidence_root)
    base = File.join(evidence_root, 'invocations', 'helper')
    output = JSON.parse(File.binread(base + '.stdout').force_encoding(Encoding::UTF_8))
    require_true(output.fetch('profiles').length == 13, 'helper profile roster is not the expected 13')
    output['profiles'].pop
    stdout = JSON.generate(output) + "\n"
    journal.write(base + '.stdout', stdout)
    status = journal.json(base + '.status.json')
    status['stdout_bytes'] = stdout.bytesize
    journal.write_json(base + '.status.json', status)
    summary_path = File.join(evidence_root, 'summary.json')
    summary = journal.json(summary_path)
    summary['helper_stdout_sha256'] = Digest::SHA256.hexdigest(stdout)
    summary['helper_process'] = status.merge('argv' => summary.fetch('helper_process').fetch('argv'))
    journal.write_json(summary_path, summary)
  end

  def inventory(part)
    CheckCustomGeoRecursiveEvidenceW238.inventory(part)
  end

  def mutate_part_and_match_witnesses!(journal, evidence_root, generated_root)
    summary_path = File.join(evidence_root, 'summary.json')
    summary = journal.json(summary_path)
    row = summary.fetch('profiles').find { |profile| profile.fetch('id') == 'point' }
    generated_part = File.join(generated_root, 'generated', 'point', 'all_1_1_0')
    attached_part = File.join(row.fetch('native_data_path'), 'all_1_1_0')
    snapshot_part = File.join(evidence_root, 'parts', 'native', 'point', 'all_1_1_0')
    entry = inventory(generated_part).find { |item| item.fetch('path').end_with?('.bin') && item.fetch('bytes').positive? }
    fail!('point part has no nonempty binary file to pressure-test') unless entry
    [generated_part, attached_part, snapshot_part].each do |part|
      path = File.join(part, entry.fetch('path'))
      bytes = File.binread(path)
      changed = bytes.dup
      changed.setbyte(0, changed.getbyte(0) ^ 0x01)
      journal.write(path, changed)
    end
    generated_inventory = inventory(generated_part)
    attached_inventory = inventory(attached_part)
    by_generated = generated_inventory.to_h { |item| [item.fetch('path'), item] }
    by_attached = attached_inventory.to_h { |item| [item.fetch('path'), item] }
    comparison = row.fetch('inventory_comparison')
    comparison['generated_inventory'] = generated_inventory
    comparison['attached_inventory'] = attached_inventory
    comparison['removed'] = (by_generated.keys - by_attached.keys).sort
    comparison['changed'] = by_generated.keys.select do |name|
      by_attached.key?(name) && by_generated.fetch(name) != by_attached.fetch(name)
    end.sort
    comparison['added'] = (by_attached.keys - by_generated.keys).sort
    row['detached_inventory_before_attach'] = generated_inventory
    journal.write_json(summary_path, summary)
  end

  def corrupt_detached_snapshot!(journal, evidence_root)
    summary_path = File.join(evidence_root, 'summary.json')
    summary = journal.json(summary_path)
    row = summary.fetch('profiles').find { |profile| profile.fetch('id') == 'point' }
    snapshot = File.expand_path(row.fetch('detached_snapshot_path'))
    entry = inventory(snapshot).find { |item| item.fetch('path').end_with?('.bin') && item.fetch('bytes').positive? }
    fail!('point detached snapshot has no nonempty binary file') unless entry
    path = File.join(snapshot, entry.fetch('path'))
    bytes = File.binread(path)
    changed = bytes.dup
    changed.setbyte(0, changed.getbyte(0) ^ 0x01)
    journal.write(path, changed)
    row['detached_inventory_before_attach'] = inventory(snapshot)
    journal.write_json(summary_path, summary)
  end

  def main(argv)
    options = {}
    parser = OptionParser.new do |opts|
      opts.banner = <<~USAGE
        Usage:
          ruby scripts/check_custom_geo_recursive_pressure_w238.rb --evidence-root PAIRED_ROOT --generated-root GENERATED_ROOT [--repo-root PATH]
        Audits fresh isolated clones. Genuine inputs are read-only; no native process is run.
      USAGE
      opts.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
      opts.on('--generated-root PATH') { |value| options[:generated_root] = value }
      opts.on('--repo-root PATH') { |value| options[:repo_root] = value }
    end
    parser.parse!(argv)
    require_true(argv.empty? && options.key?(:evidence_root) && options.key?(:generated_root), parser.to_s)
    repo_root = File.expand_path(options.fetch(:repo_root, Dir.pwd))
    auditor_path = File.join(repo_root, 'scripts', 'check_custom_geo_recursive_evidence_w238.rb')
    require_true(File.file?(auditor_path) && !File.symlink?(auditor_path), "auditor source is absent: #{auditor_path}")
    require auditor_path

    genuine_evidence = canonical_root(options.fetch(:evidence_root), EVIDENCE_PREFIX, 'paired evidence root')
    genuine_generated = canonical_root(options.fetch(:generated_root), GENERATED_PREFIX, 'generated root')
    auditor = CheckCustomGeoRecursiveEvidenceW238

    genuine_baseline = passing_control(auditor, genuine_evidence, 'genuine_baseline')
    require_true(genuine_baseline.fetch('result') == 'accepted',
      "genuine evidence did not pass: #{genuine_baseline.fetch('diagnostic')}")
    cloned_evidence, cloned_generated = clone_pair(genuine_evidence, genuine_generated)
    cloned_baseline = passing_control(auditor, cloned_evidence, 'cloned_baseline')
    require_true(cloned_baseline.fetch('result') == 'accepted',
      "rebased clone did not pass: #{cloned_baseline.fetch('diagnostic')}")

    required = 'in_scope_false_success'
    informational = 'out_of_scope_provenance_pressure'
    cases = []
    cases << run_case(auditor, genuine_evidence, cloned_evidence, 'CHECK zero despite exit 0', required) do |journal|
      change_check_to_zero!(journal, cloned_evidence)
    end
    cases << run_case(auditor, genuine_evidence, cloned_evidence, 'native nominal schema alias changed', required) do |journal|
      change_native_schema!(journal, cloned_evidence)
    end
    cases << run_case(auditor, genuine_evidence, cloned_evidence, 'RowBinary bytes changed with matching summary witness', required) do |journal|
      mutate_rowbinary!(journal, cloned_evidence)
    end
    cases << run_case(auditor, genuine_evidence, cloned_evidence, 'forged success status masks timeout and signal', required) do |journal|
      forge_timeout_status!(journal, cloned_evidence)
    end
    cases << run_case(auditor, genuine_evidence, cloned_evidence, 'helper roster loss with coherent stdout hashes', required) do |journal|
      remove_helper_profile!(journal, cloned_evidence)
    end
    cases << run_case(auditor, genuine_evidence, cloned_evidence, 'detached snapshot-only corruption with matched witness', required) do |journal|
      corrupt_detached_snapshot!(journal, cloned_evidence)
    end
    cases << run_case(auditor, genuine_evidence, cloned_evidence,
      'coordinated generated, attached, and snapshot bytes with matching inventory witnesses', informational) do |journal|
      mutate_part_and_match_witnesses!(journal, cloned_evidence, cloned_generated)
    end
    required_case_names = [
      'CHECK zero despite exit 0',
      'native nominal schema alias changed',
      'RowBinary bytes changed with matching summary witness',
      'forged success status masks timeout and signal',
      'helper roster loss with coherent stdout hashes',
      'detached snapshot-only corruption with matched witness',
    ]
    observed_required_names = cases.select { |row| row.fetch('scope') == required }.map { |row| row.fetch('case') }
    require_true(observed_required_names == required_case_names, 'required six-case pressure roster differs')

    failures = []
    cases.each do |row|
      if row.fetch('scope') == required && row.fetch('result') != 'rejected'
        failures << "in-scope mutation was not rejected: #{row.fetch('case')}"
      end
      failures << "restored/genuine passing controls failed: #{row.fetch('case')}" unless row.fetch('controls_passed')
      failures << "mutation probe could not produce an audit verdict: #{row.fetch('case')}" if row.fetch('probe_error')
      failures << "mutation restore failed: #{row.fetch('case')}" if row.fetch('restore_error')
    end

    report = {
      'format' => 'custom_geo_recursive_w238_pressure_v1',
      'evidence_scope' => {
        'tests' => 'raw-auditor consistency against recorded argv/status/SQL/streams, independent literals, and on-disk files',
        'not_proven' => 'cryptographic execution provenance or resistance to coordinated alteration of every artifact and matching witness',
        'native_processes_run' => false,
        'genuine_inputs_mutated' => false,
        'coordinated_all_copy_case_is_a_certificate' => false,
      },
      'genuine_baseline' => genuine_baseline,
      'cloned_baseline' => cloned_baseline,
      'required_in_scope_case_count' => required_case_names.length,
      'cases' => cases,
      'in_scope_rejections' => cases.select { |row| row.fetch('scope') == required && row.fetch('result') == 'rejected' }
        .map { |row| row.fetch('case') },
      'accepted_mutations' => cases.select { |row| row.fetch('result') == 'accepted' }
        .map { |row| { 'case' => row.fetch('case'), 'scope' => row.fetch('scope') } },
      'out_of_scope_provenance_observation' => cases.find { |row| row.fetch('scope') == informational },
      'limitations' => [
        'The coordinated generated/attached/snapshot mutation is reported as an out-of-scope provenance observation, whether accepted or rejected.',
        'A fully coordinated rewrite of all copies and all matching summary witnesses has no independent immutable anchor in this raw auditor contract.',
      ],
      'cloned_evidence_root' => cloned_evidence,
      'cloned_generated_root' => cloned_generated,
      'failures' => failures,
    }
    puts JSON.pretty_generate(report)
    failures.empty? ? 0 : 1
  rescue StandardError => error
    warn "W238 pressure probe failed: #{error.class}: #{error.message}"
    2
  end
end

exit(CheckCustomGeoRecursivePressureW238.main(ARGV)) if $PROGRAM_NAME == __FILE__
