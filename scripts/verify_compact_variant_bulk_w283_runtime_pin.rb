#!/usr/bin/env ruby
# Pure-Ruby behavioral checks for W283's separate full-runtime pin.

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'securerandom'
require_relative 'probe_compact_recursive_arrays_w280'
require_relative 'probe_compact_static_bulk_w281_matrix'
require_relative 'probe_compact_low_cardinality_bulk_w282_matrix'
require_relative 'probe_compact_variant_bulk_w283_matrix'
require_relative 'verify_compact_variant_bulk_w283_capture'

module VerifyCompactVariantBulkW283RuntimePin
  W280 = ProbeCompactRecursiveArraysW280
  W281 = ProbeCompactStaticBulkW281Matrix
  W282 = ProbeCompactLowCardinalityBulkW282Matrix
  W283 = ProbeCompactVariantBulkW283Matrix
  AUDITOR = VerifyCompactVariantBulkW283Capture
  SCRATCH_ROOT = '/opt/mldata_ssd/cache'.freeze

  # Independent historical and W283 literals: neither is derived from a probe constant.
  LEGACY_PIN = {sha256: 'bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2'.freeze,
    bytes: 746_226_224, version: '26.10.1.1201'.freeze,
    build: 'd9bcb5ab007f0f6299f7f973f2642245bab3d028'.freeze}.freeze
  FULL_PIN = {sha256: '5bb43958f4c0806cc363b84b9858e7206e56ac80263a24acc704271322e531ae'.freeze,
    bytes: 919_123_095, version: '26.10.1.1201'.freeze,
    build: 'd9bcb5ab007f0f6299f7f973f2642245bab3d028'.freeze}.freeze
  FULL_BINARY = '/opt/mldata_ssd/cache/crystal-click-w283.PDWAiK/recovery/runtime/clickhouse'.freeze
  PROBE_SOURCE = File.expand_path('probe_compact_variant_bulk_w283_matrix.rb', __dir__).freeze
  AUDITOR_SOURCE = File.expand_path('verify_compact_variant_bulk_w283_capture.rb', __dir__).freeze
  W282_AUDITOR_SOURCE = File.expand_path('verify_compact_low_cardinality_bulk_w282_capture.rb', __dir__).freeze

  class Error < StandardError; end

  class RecordingRunner
    attr_reader :call

    def initialize(mutate_after: nil)
      @mutate_after = mutate_after
    end

    def run_process(label, argv, input, process_kind, expected_sha:, binary_path:, store:)
      @call = {label: label, argv: argv, input: input, process_kind: process_kind,
        expected_sha: expected_sha, binary_path: binary_path, store: store}
      File.open(binary_path, 'ab') { |file| file.write('x') } if @mutate_after
      {record: {'expected_binary_sha256' => expected_sha,
        'binary_sha_before' => expected_sha, 'binary_sha_after' => expected_sha}}
    end
  end

  class ProbeHarness < W283::Probe
    def setup_for_test(binary, pin, runner = RecordingRunner.new)
      @binary = binary
      @test_runtime_pin = pin
      @runner = runner
      @expected_processes = {}
    end

    private

    def runtime_pin
      @test_runtime_pin
    end
  end

  def self.run
    raise Error, 'approved SSD cache root is unavailable' unless File.directory?(SCRATCH_ROOT)
    root = create_task_root!
    begin
      selection_checks!
      runtime_boundary_checks!(root)
      summary_checks!(root)
      auditor_checks!(root)
      lineage_checks!(root)
      cli_checks!
      puts 'W283 full runtime pin, propagation, auditor, lineage, and CLI checks passed (Ruby-only; no native execution)'
      true
    ensure
      FileUtils.remove_entry(root) if root && File.exist?(root)
    end
  rescue StandardError => error
    warn "W283 runtime-pin verifier failed: #{error.class}: #{error.message}"
    false
  end

  def self.create_task_root!
    8.times do
      candidate = File.join(SCRATCH_ROOT, "crystal-click-w283.#{SecureRandom.alphanumeric(6)}")
      begin
        Dir.mkdir(candidate, 0o700)
        return candidate
      rescue Errno::EEXIST
        next
      end
    end
    raise Error, 'could not allocate a unique six-character W283 test task root'
  end

  def self.selection_checks!
    assert!(W280::Probe.allocate.send(:runtime_pin) == LEGACY_PIN, 'W280 legacy strict pin changed')
    assert!(W281::Probe.allocate.send(:runtime_pin) == LEGACY_PIN, 'W281 legacy strict pin changed')
    assert!(W282::Probe.allocate.send(:runtime_pin) == LEGACY_PIN, 'W282 legacy strict pin changed')
    assert!(W283::Probe.allocate.send(:runtime_pin) == FULL_PIN, 'W283 did not select the independent full-runtime pin')
    assert!(W283::BINARY == FULL_BINARY, 'W283 CLI default binary path is not the approved full runtime')
  end

  def self.runtime_boundary_checks!(root)
    bytes = "W283 runtime fixture\n".b
    binary = File.join(root, 'runtime-fixture')
    File.binwrite(binary, bytes)
    File.chmod(0o700, binary)
    pin = {sha256: Digest::SHA256.hexdigest(bytes), bytes: bytes.bytesize,
      version: 'fixture-version', build: 'fixture-build'}.freeze
    runner = RecordingRunner.new
    probe = ProbeHarness.allocate
    probe.setup_for_test(binary, pin, runner)

    before = probe.send(:capture_runtime_pin!, :before)
    assert!(before == {sha256: pin.fetch(:sha256), bytes: pin.fetch(:bytes)},
      'runtime prepare boundary did not capture fixture SHA and byte size')
    probe.send(:register_process!, 'seed', [binary, 'local'], 'SELECT 1'.b, File.join(root, 'store'), 'sql')
    expected = probe.instance_variable_get(:@expected_processes).fetch('seed')
    assert!(expected.values_at(:expected_sha256, :expected_bytes) == [pin.fetch(:sha256), pin.fetch(:bytes)],
      'native invocation registration did not inherit selected SHA and byte size')
    result = probe.send(:run_pinned_process!, 'seed', [binary, 'local'], 'SELECT 1'.b, File.join(root, 'store'))
    assert!(runner.call.values_at(:expected_sha, :binary_path) == [pin.fetch(:sha256), binary] &&
      result.fetch(:record).values_at('binary_sha_before', 'binary_sha_after') == [pin.fetch(:sha256), pin.fetch(:sha256)],
      'native invocation boundary did not propagate the selected runtime SHA')
    after = probe.send(:capture_runtime_pin!, :after)
    assert!(after == before && probe.instance_variable_get(:@binary_bytes_before) == pin.fetch(:bytes) &&
      probe.instance_variable_get(:@binary_bytes_after) == pin.fetch(:bytes),
      'post-capture boundary did not retain exact runtime SHA and size')

    mutated = bytes.dup
    mutated[-2] = 'X'
    File.binwrite(binary, mutated)
    expect_failure!('post-capture same-size mutation', 'SHA-256 differs') do
      probe.send(:capture_runtime_pin!, :after)
    end

    File.binwrite(binary, bytes + 'x')
    expect_failure!('wrong runtime byte size', 'byte size differs') do
      probe.send(:capture_runtime_pin!, :before)
    end

    File.binwrite(binary, bytes)
    wrong_hash_probe = ProbeHarness.allocate
    wrong_hash_probe.setup_for_test(binary, pin.merge(sha256: LEGACY_PIN.fetch(:sha256)))
    expect_failure!('same-size wrong runtime hash', 'SHA-256 differs') do
      wrong_hash_probe.send(:capture_runtime_pin!, :before)
    end

    File.binwrite(binary, bytes)
    mutating_runner = RecordingRunner.new(mutate_after: true)
    invocation_probe = ProbeHarness.allocate
    invocation_probe.setup_for_test(binary, pin, mutating_runner)
    expect_failure!('runtime size mutation during native invocation', 'byte size changed during native invocation') do
      invocation_probe.send(:run_pinned_process!, 'mutate', [binary, 'local'], ''.b, root)
    end
  end

  def self.summary_checks!(root)
    probe = W283::Probe.allocate
    {'@binary' => FULL_BINARY, '@cases' => {}, '@full_matrix' => false, '@invocations' => [],
     '@binary_sha_before' => FULL_PIN.fetch(:sha256), '@binary_sha_after' => FULL_PIN.fetch(:sha256),
     '@binary_bytes_before' => FULL_PIN.fetch(:bytes), '@binary_bytes_after' => FULL_PIN.fetch(:bytes),
     '@source_root' => '/fixture/source', '@source_revision_before' => W280::SOURCE_REVISION,
     '@source_revision_after' => W280::SOURCE_REVISION, '@upstream_hashes_before' => {},
     '@upstream_hashes_after' => {}, '@local_source_hashes_before' => {},
     '@local_source_hashes_after' => {}}.each do |name, value|
      probe.instance_variable_set(name, value)
    end
    summary = probe.send(:build_summary)
    runtime = summary.fetch(:runtime_pin)
    assert!(runtime.values_at(:binary, :expected_sha256, :sha256_before, :sha256_after,
      :expected_bytes, :bytes_before, :bytes_after, :version, :build) ==
      [FULL_BINARY, FULL_PIN[:sha256], FULL_PIN[:sha256], FULL_PIN[:sha256], FULL_PIN[:bytes],
        FULL_PIN[:bytes], FULL_PIN[:bytes], FULL_PIN[:version], FULL_PIN[:build]],
      'W283 summary did not preserve its complete full-runtime pin')
    markdown = probe.send(:render_summary, summary)
    assert!(markdown.include?(FULL_PIN.fetch(:sha256)) && markdown.include?(FULL_PIN.fetch(:version)) &&
      markdown.include?(FULL_PIN.fetch(:build)) && markdown.include?(FULL_PIN.fetch(:bytes).to_s),
      'W283 summary rendering omitted full runtime identity')

    inconclusive = File.join(root, 'inconclusive')
    Dir.mkdir(inconclusive, 0o700)
    Dir.mkdir(File.join(inconclusive, 'invocations'), 0o700)
    probe.instance_variable_set(:@root, inconclusive)
    probe.instance_variable_set(:@fatal_error, 'seeded test failure')
    probe.send(:persist_inconclusive, RuntimeError.new('seeded test failure'))
    report = JSON.parse(File.binread(File.join(inconclusive, 'summary.json')))
    assert!(report.dig('runtime_pin', 'binary') == FULL_BINARY &&
      report.dig('runtime_pin', 'expected_sha256') == FULL_PIN.fetch(:sha256) &&
      report.dig('runtime_pin', 'expected_bytes') == FULL_PIN.fetch(:bytes),
      'W283 inconclusive report fell back to the historical runtime pin')
  end

  def self.auditor_checks!(root)
    auditor = AUDITOR::Auditor.allocate
    helper_sha = 'a' * 64
    auditor.instance_variable_set(:@summary, {'helper_pin' => {'expected_sha256' => helper_sha}})
    assert!(auditor.send(:expected_invocation_sha256, 'clickhouse-local') == FULL_PIN.fetch(:sha256),
      'auditor native invocation SHA did not use its independent W283 full literal')
    assert!(auditor.send(:expected_invocation_sha256, 'crystal-helper') == helper_sha,
      'auditor helper invocation SHA stopped using its helper-specific pin')
    native = {'expected_binary_sha256' => FULL_PIN.fetch(:sha256),
      'binary_sha_before' => FULL_PIN.fetch(:sha256), 'binary_sha_after' => FULL_PIN.fetch(:sha256)}
    auditor.send(:invocation_pin!, 'native seed', native, FULL_PIN.fetch(:sha256))
    expect_auditor_failure!('native old hash', 'raw runtime SHA identity differs') do
      auditor.send(:invocation_pin!, 'native seed', native.merge(
        'expected_binary_sha256' => LEGACY_PIN.fetch(:sha256)), FULL_PIN.fetch(:sha256))
    end
    helper = {'expected_binary_sha256' => helper_sha, 'binary_sha_before' => helper_sha,
      'binary_sha_after' => helper_sha}
    auditor.send(:invocation_pin!, 'helper seed', helper, helper_sha)
    expect_auditor_failure!('helper full-runtime substitution', 'raw runtime SHA identity differs') do
      auditor.send(:invocation_pin!, 'helper seed', helper, FULL_PIN.fetch(:sha256))
    end

    short_binary = File.join(root, 'auditor-runtime-fixture')
    File.binwrite(short_binary, "not the 919123095-byte runtime\n")
    File.chmod(0o700, short_binary)
    full_metadata = {'binary' => File.realpath(short_binary), 'expected_sha256' => FULL_PIN[:sha256],
      'sha256_before' => FULL_PIN[:sha256], 'sha256_after' => FULL_PIN[:sha256],
      'expected_bytes' => FULL_PIN[:bytes], 'bytes_before' => FULL_PIN[:bytes],
      'bytes_after' => FULL_PIN[:bytes], 'version' => FULL_PIN[:version], 'build' => FULL_PIN[:build]}
    file_auditor = AUDITOR::Auditor.allocate
    file_auditor.instance_variable_set(:@summary, {'runtime_pin' => full_metadata})
    expect_auditor_failure!('auditor actual runtime byte count', 'W283 native runtime bytes differ from fixed pin') do
      file_auditor.send(:pins!)
    end
  end

  def self.lineage_checks!(root)
    source = File.join(root, 'source-fixture.rb')
    File.binwrite(source, "before\n")
    path = File.realpath(source)
    before_sha = Digest::SHA256.file(path).hexdigest
    auditor = AUDITOR::Auditor.allocate
    auditor.instance_variable_set(:@summary, {'matrix_source_pins' => {
      'sha256_before' => {path => before_sha}, 'sha256_after' => {path => before_sha}}})
    auditor.send(:local_source_pins!, [path])
    File.binwrite(source, "after\n")
    expect_auditor_failure!('local source post-capture mutation', 'W280/W281/W282/W283 matrix, helper, or fixture source seals differ') do
      auditor.send(:local_source_pins!, [path])
    end

    parent = method_body(W282_AUDITOR_SOURCE, 'invocations!')
    child = method_body(AUDITOR_SOURCE, 'invocations!')
    child = child.sub("        expected_sha = expected_invocation_sha256(kind)\n        invocation_pin!(label, record, expected_sha)\n",
      "        expected_sha = kind == 'crystal-helper' ? @summary.dig('helper_pin', 'expected_sha256') : FULL_BINARY_SHA256\n")
    parent = parent.sub(' : W::BINARY_SHA256', ' : FULL_BINARY_SHA256')
    assert!(child == parent, 'W283 invocation auditor drifted from W282 beyond its full-pin substitution and direct pin guard')
  end

  def self.cli_checks!
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, PROBE_SOURCE, '--help')
    help = stdout + stderr
    assert!(status.success? && help.include?('Full pinned ClickHouse runtime file below the owned SSD task root') &&
      help.include?('defaults to the W283 full runtime'),
      'W283 CLI help does not describe the full-runtime default')
  end

  def self.method_body(path, name)
    source = File.read(path)
    match = source.match(/^    def #{Regexp.escape(name)}\n.*?(?=^    def [a-zA-Z0-9_]+\b)/m)
    raise Error, "could not extract #{name} from #{File.basename(path)}" unless match
    match[0]
  end

  def self.assert!(condition, message)
    raise Error, message unless condition
    true
  end

  def self.expect_failure!(label, fragment)
    yield
    raise Error, "#{label}: invalid runtime was accepted"
  rescue StandardError => error
    raise if error.is_a?(Error)
    raise Error, "#{label}: unexpected rejection #{error.message.inspect}" unless error.message.include?(fragment)
    true
  end

  def self.expect_auditor_failure!(label, fragment)
    yield
    raise Error, "#{label}: invalid evidence was accepted"
  rescue StandardError => error
    raise if error.is_a?(Error)
    raise Error, "#{label}: unexpected rejection #{error.class}: #{error.message}" unless error.message.include?(fragment)
    true
  end
end

exit(VerifyCompactVariantBulkW283RuntimePin.run ? 0 : 1) if $PROGRAM_NAME == __FILE__
