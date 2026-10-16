#!/usr/bin/env ruby
# Ruby-only W283 path and inherited pin-policy falsifiers. All temporary
# fixtures are confined to one owned external-SSD task root and removed exactly.

require 'digest'
require 'fileutils'
require 'open3'
require 'securerandom'
require_relative 'compact_variant_bulk_w283_paths'
require_relative 'probe_compact_variant_bulk_w283_matrix'
require_relative 'verify_compact_variant_bulk_w283_capture'

module VerifyCompactVariantBulkW283Paths
  M = ProbeCompactVariantBulkW283Matrix
  W = M::W280
  PATHS = CompactVariantBulkW283Paths
  AUDITOR = VerifyCompactVariantBulkW283Capture::Auditor
  SSD_ALIAS = '/opt/mldata_ssd'.freeze
  CACHE_ROOT = File.join(SSD_ALIAS, 'cache').freeze

  class Error < StandardError; end

  class FakeStatus
    def success?
      true
    end
  end

  def self.run
    raise Error, 'approved SSD cache root is unavailable' unless File.directory?(CACHE_ROOT)

    task_root = create_task_root!
    begin
      boundary_checks!(task_root)
      source_pin_checks!(task_root)
      puts 'W283 SSD path policy and inherited source-pin sensitivity checks passed (Ruby-only; no capture claim)'
      true
    ensure
      FileUtils.remove_entry(task_root) if File.exist?(task_root)
    end
  rescue StandardError => error
    warn "W283 SSD path/source-pin falsifier failed: #{error.class}: #{error.message}"
    false
  end

  def self.boundary_checks!(task_root)
    probe = M::Probe.allocate
    canonical_task_root = File.realpath(task_root)
    alias_evidence = File.join(task_root, 'empty-alias')
    Dir.mkdir(alias_evidence, 0o700)
    accepted_alias = probe.send(:validate_root, alias_evidence)
    accepted_canonical = probe.send(:validate_root, File.realpath(alias_evidence))
    assert!(accepted_alias == File.realpath(alias_evidence) && accepted_canonical == accepted_alias,
      'SSD alias and canonical path did not resolve to one summary-root identity')

    nonempty = File.join(task_root, 'nonempty-probe')
    Dir.mkdir(nonempty, 0o700)
    File.write(File.join(nonempty, 'sentinel'), 'occupied')
    expect_rejection!('nonempty probe root', 'already exist and be empty') do
      probe.send(:validate_root, nonempty)
    end

    audit_root = File.join(task_root, 'nonempty-audit')
    Dir.mkdir(audit_root, 0o700)
    File.write(File.join(audit_root, 'summary.json'), "{}\n")
    auditor = AUDITOR.new(audit_root, mode: :stock_only)
    assert!(auditor.instance_variable_get(:@root) == File.realpath(audit_root),
      'auditor did not accept a nonempty root using the same canonical policy')
    canonical_auditor = AUDITOR.new(File.realpath(audit_root), mode: :stock_only)
    assert!(canonical_auditor.instance_variable_get(:@root) == auditor.instance_variable_get(:@root),
      'auditor did not preserve summary-root identity for the canonical SSD path')
    contract_error = nil
    begin
      auditor.send(:summary_contract!)
    rescue StandardError => error
      contract_error = error
    end
    assert!(contract_error && contract_error.message.include?('requires exact stock_only W283 status'),
      'nonempty audit root did not proceed to the expected semantic summary rejection')

    symlink_root = File.join(task_root, 'symlink-root')
    File.symlink(CACHE_ROOT, symlink_root)
    expect_rejection!('symlink evidence root', 'descendant symlink') do
      PATHS.validate_evidence_root(symlink_root, purpose: :audit)
    end

    ancestor_target = File.join(task_root, 'ancestor-target')
    Dir.mkdir(ancestor_target, 0o700)
    Dir.mkdir(File.join(ancestor_target, 'nested'), 0o700)
    File.symlink(ancestor_target, File.join(task_root, 'ancestor-link'))
    expect_rejection!('symlink ancestor', 'descendant symlink') do
      PATHS.validate_evidence_root(File.join(task_root, 'ancestor-link', 'nested'), purpose: :audit)
    end

    expect_rejection!('path escape/unrelated base', 'must be within cache/crystal-click-w283') do
      PATHS.validate_evidence_root(File.join(task_root, 'empty-alias', '..', '..', 'escape'), purpose: :audit)
    end
    expect_rejection!('unrelated /private/tmp base', 'must use /opt/mldata_ssd') do
      PATHS.validate_evidence_root('/private/tmp/w283-unrelated', purpose: :audit)
    end
    expect_rejection!('unrelated cache sibling', 'must be within cache/crystal-click-w283') do
      PATHS.validate_evidence_root(File.join(CACHE_ROOT, 'crystal-click-unrelated.ABC123', 'evidence'), purpose: :audit)
    end

    missing_mount = File.join(task_root, 'not-mounted')
    expect_rejection!('missing mount injection', 'external SSD mount is unavailable') do
      PATHS::Policy.new(alias_root: missing_mount).validate_evidence_root(alias_evidence, purpose: :audit)
    end
    same_device = PATHS::Policy.new(alias_root: SSD_ALIAS, internal_root: File.realpath(SSD_ALIAS))
    expect_rejection!('same-device substitution', 'internal/root device') do
      same_device.validate_evidence_root(alias_evidence, purpose: :audit)
    end

    source_root = File.join(task_root, 'recovery', 'source')
    FileUtils.mkdir_p(source_root, mode: 0o700)
    assert!(PATHS.validate_source_root(source_root) == File.realpath(source_root),
      'W283 source policy rejected a source below its owned task root')
    legacy = W::Probe.allocate
    expect_rejection!('historical W280 default', 'separately pinned upstream checkout') do
      legacy.send(:validate_source_root, source_root)
    end
    assert!(probe.send(:validate_source_root, source_root) == File.realpath(source_root),
      'W283 source override did not accept the approved SSD checkout')

    runtime = File.join(task_root, 'recovery', 'clickhouse-stripped')
    File.write(runtime, "#!/bin/sh\nexit 0\n", mode: 'wb')
    File.chmod(0o700, runtime)
    assert!(probe.send(:validate_executable, runtime, 'test runtime') == File.realpath(runtime),
      'W283 executable validator rejected an owned SSD task file')
    auditor_seed = AUDITOR.allocate
    auditor_seed.instance_variable_set(:@root, File.realpath(audit_root))
    auditor_seed.instance_variable_set(:@binary_path, File.realpath(runtime))
    reconstructed = auditor_seed.send(:native_spec, 'path-policy-seed', "SELECT 1\n", 'unused')
    assert!(reconstructed[0, 2] == ['clickhouse-local', File.realpath(runtime)] &&
      reconstructed.fetch(3).first == File.realpath(runtime),
      'auditor reconstructed native commands with the historical runtime path')
    expect_rejection!('outside runtime', 'must use /opt/mldata_ssd') do
      probe.send(:validate_executable, '/usr/bin/ruby', 'outside runtime')
    end

    assert!(File.realpath(task_root) == canonical_task_root, 'test task root identity changed unexpectedly')
  end

  def self.create_task_root!
    8.times do
      candidate = File.join(CACHE_ROOT, "crystal-click-w283.#{SecureRandom.alphanumeric(6)}")
      begin
        Dir.mkdir(candidate, 0o700)
        return candidate
      rescue Errno::EEXIST
        next
      end
    end
    raise Error, 'could not allocate a unique six-character W283 test task root'
  end

  def self.source_pin_checks!(task_root)
    source = File.join(task_root, 'recovery', 'source-fixture')
    W::SOURCE_FILES.each do |relative|
      path = File.join(source, relative)
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      File.binwrite(path, "fixture source bytes: #{relative}\n")
    end
    binary = File.join(task_root, 'recovery', 'runtime-fixture')
    File.binwrite(binary, "fixture runtime bytes\n")
    File.chmod(0o700, binary)

    wrong_root = File.join(task_root, 'wrong-revision-evidence')
    Dir.mkdir(wrong_root, 0o700)
    wrong = identity_probe(source, binary, wrong_root)
    with_git_revision('wrong-revision') do
      expect_rejection!('wrong HEAD sensitivity', 'pinned upstream revision check failed') do
        wrong.send(:prepare!)
      end
    end

    stable_root = File.join(task_root, 'stable-evidence')
    Dir.mkdir(stable_root, 0o700)
    stable = identity_probe(source, binary, stable_root)
    with_git_revision(W::SOURCE_REVISION) do
      stable.send(:prepare!)
      stable.send(:validate_pins!)
    end

    mutation_root = File.join(task_root, 'mutation-evidence')
    Dir.mkdir(mutation_root, 0o700)
    mutation = identity_probe(source, binary, mutation_root)
    changed_file = File.join(source, W::SOURCE_FILES.first)
    with_git_revision(W::SOURCE_REVISION) do
      mutation.send(:prepare!)
      File.open(changed_file, 'ab') { |file| file.write("changed after inventory\n") }
      expect_rejection!('source byte mutation after inventory', 'source bytes changed during capture') do
        mutation.send(:validate_pins!)
      end
    end
    puts 'W280 pin controls distinguished wrong HEAD from source-byte mutation after inventory; no initial-cleanliness claim'
  end

  def self.identity_probe(source, binary, root)
    probe = W::Probe.allocate
    probe.instance_variable_set(:@source_root, source)
    probe.instance_variable_set(:@binary, binary)
    probe.instance_variable_set(:@root, root)
    probe.define_singleton_method(:sha) do |path|
      path == binary ? W::BINARY_SHA256 : Digest::SHA256.file(path).hexdigest
    end
    probe.define_singleton_method(:runtime_pin) do
      {sha256: W::BINARY_SHA256, bytes: File.size(binary), version: W::VERSION, build: W::BUILD}.freeze
    end
    probe
  end

  def self.with_git_revision(revision)
    original = Open3.method(:capture3)
    Open3.define_singleton_method(:capture3) do |*arguments, **options|
      if arguments[0] == 'git' && arguments[-2, 2] == ['rev-parse', 'HEAD']
        ["#{revision}\n", '', FakeStatus.new]
      else
        original.call(*arguments, **options)
      end
    end
    yield
  ensure
    Open3.define_singleton_method(:capture3, original) if original
  end

  def self.expect_rejection!(label, fragment)
    yield
    raise Error, "#{label}: forbidden input was accepted"
  rescue PATHS::Error, W::Failure => error
    raise Error, "#{label}: wrong rejection #{error.message.inspect}" unless error.message.include?(fragment)
    true
  end

  def self.assert!(condition, message)
    raise Error, message unless condition
    true
  end
end

exit(VerifyCompactVariantBulkW283Paths.run ? 0 : 1) if $PROGRAM_NAME == __FILE__
