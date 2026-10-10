#!/usr/bin/env ruby
# Replay bounded semantic-tamper controls against a fresh W248 capture. This
# script launches only the offline Ruby auditor; it never starts Crystal or
# ClickHouse. Mutations are restored byte-for-byte before the next control.

require 'digest'
require 'json'
require 'open3'
require 'optparse'
require 'rbconfig'

module CheckStaticNestedHandoffW248Adversary
  class Failure < StandardError; end

  EXTERNAL_PINS = %w[
    expected_helper_sha256 expected_probe_sha256 expected_auditor_sha256
    expected_helper_source_sha256 expected_fixture_sha256
  ].freeze
  MAX_ENTRIES = 50_000
  MAX_FILE_BYTES = 64 * 1024 * 1024
  MAX_CAPTURE_BYTES = 1024 * 1024 * 1024
  MAX_AUDITOR_OUTPUT = 1 * 1024 * 1024
  CHECK_BEGIN = '__W248_CHECK_BEGIN__'
  CHECK_END = '__W248_CHECK_END__'
  SCHEMA_TAG = '__W248_SCHEMA__'
  PART_NAME = 'all_1_1_0'
  LINK_NAME = '.w248_adversary_link'
  LINK_TARGET = 'w248-adversary-do-not-follow'

  class Harness
    def initialize(options)
      @options = options
      @root = canonical_root(options.fetch(:evidence_root))
      @summary_path = File.join(@root, 'summary.json')
      @auditor = canonical_file(File.join(__dir__, 'audit_static_nested_handoff_w248.rb'), 'W248 auditor')
      @pins = EXTERNAL_PINS.to_h do |key|
        value = options.fetch(key.to_sym)
        fail!("--#{key.tr('_', '-')} must be a lowercase SHA-256") unless /\A[0-9a-f]{64}\z/.match?(value)
        [key, value]
      end
      @original_summary_bytes = read_regular(@summary_path, 16 * 1024 * 1024, 'summary')
      @original_summary_sha = sha(@original_summary_bytes)
      summary = parse_json(@original_summary_bytes, 'summary')
      fail!('evidence root is not a W248 native capture') unless
        summary.is_a?(Hash) && summary['format'] == 'static_nested_handoff_w248_native_capture_v1'
      @initial_inventory = inventory
      @initial_inventory_sha = sha(JSON.generate(@initial_inventory))
      @audits = []
    end

    def run
      initial = audit('baseline_initial', @original_summary_sha)
      assert_success!(initial, 'initial baseline')
      assert_restored!('initial baseline')

      run_attack('unrebound_native_stdout_digest',
        'native_attach_check_rows raw stdin/stdout/stderr digest or size differs') do |saved|
        record = invocation('native_attach_check_rows')
        path = stdout_path(record)
        bytes = read_regular(path, MAX_AUDITOR_OUTPUT * 16, 'native stdout')
        save!(saved, path)
        fail!('native stdout is empty') if bytes.empty?
        changed = bytes.dup
        changed.setbyte(changed.bytesize - 1, changed.getbyte(changed.bytesize - 1) ^ 1)
        File.binwrite(path, changed)
        false
      end

      run_attack('rebound_check_zero', 'native_attach_check_rows CHECK result differs') do |saved|
        summary = load_summary
        record = record_in(summary, 'native_attach_check_rows')
        bytes = read_regular(stdout_path(record), MAX_AUDITOR_OUTPUT * 16, 'native stdout')
        changed = replace_check_line(bytes)
        rebind_stdout!(summary, record, changed, saved)
        write_summary!(summary, saved)
        true
      end

      run_attack('rebound_native_schema', 'native_attach_check_rows raw schema/order differs') do |saved|
        summary = load_summary
        record = record_in(summary, 'native_attach_check_rows')
        bytes = read_regular(stdout_path(record), MAX_AUDITOR_OUTPUT * 16, 'native stdout')
        old_prefix = "#{SCHEMA_TAG}\troot_nested\t".b
        lines = bytes.lines
        matches = lines.each_index.select { |index| lines[index].start_with?(old_prefix) }
        fail!('expected one root_nested raw schema row') unless matches.size == 1
        line = lines.fetch(matches.first)
        newline = line.end_with?("\n") ? "\n" : ''.b
        lines[matches.first] = "#{old_prefix}Array(Tuple(String, UInt64))#{newline}".b
        rebind_stdout!(summary, record, lines.join.b, saved)
        write_summary!(summary, saved)
        true
      end

      run_attack('rebound_attached_invalidation_marker',
        'ATTACH invalidation metadata differs from the exact pinned marker bytes') do |saved|
        summary = load_summary
        attached = summary.fetch('parts').fetch('native_attached')
        native_store = File.realpath(File.join(@root, 'stores', 'native'))
        part_path = File.expand_path(attached.fetch('path'))
        fail!('native-attached PART path is not canonical beneath the native store') unless
          part_path == attached.fetch('path') && part_path.start_with?(native_store + File::SEPARATOR) &&
          File.basename(part_path) == PART_NAME && File.directory?(part_path) &&
          !File.symlink?(part_path) && File.realpath(part_path) == part_path
        marker_path = File.join(part_path, 'invalidated_system_columns.txt')
        save!(saved, marker_path)
        original_marker = saved.fetch(marker_path)
        fail!('attached marker changed before mutation') unless
          read_regular(marker_path, MAX_FILE_BYTES, 'attached invalidation marker') == original_marker
        changed_marker = "_block_offset\n_block_number_shadow\n".b
        File.binwrite(marker_path, changed_marker)
        marker_entries = attached.fetch('files').select do |entry|
          entry.fetch('path') == 'invalidated_system_columns.txt'
        end
        fail!('native-attached inventory does not contain one marker entry') unless marker_entries.size == 1
        marker_entries.first['size'] = changed_marker.bytesize
        marker_entries.first['sha256'] = sha(changed_marker)
        write_summary!(summary, saved)
        true
      end

      run_helper_report_attack('rebound_nominal_type',
        'helper nominal type/tag differs for root_nested') do |report|
        report.fetch('nominal_binary_columns').fetch('root_nested')['type'] =
          'Array(Tuple(String, Variant(String, UInt64), String))'
      end

      run_helper_report_attack('rebound_variant_prefix', 'Variant BASIC prefix literal differs') do |report|
        entry = report.fetch('variant_discriminator_prefixes').find { |item| item.fetch('column') == 'root_nested' }
        fail!('root_nested Variant prefix witness is absent') unless entry
        entry['prefix_hex'] = '0100000000000000'
      end

      mark_file = nil
      mark_reason = ->(_result) { "reported recursive mark coordinates differ from physical #{mark_file}" }
      run_helper_report_attack('rebound_recursive_mark_coordinate', mark_reason) do |report|
        entry = report.fetch('recursive_nested_site_marks').find do |item|
          item.fetch('role') == 'root.elements.field.0.indexes'
        end
        fail!('recursive Nested LC mark witness is absent') unless entry
        mark_file = entry.fetch('file')
        coordinates = entry.fetch('marks')
        fail!('recursive Nested first mark coordinate is malformed') unless
          coordinates.is_a?(Array) && coordinates.first.is_a?(Array) && coordinates.first.size == 3
        coordinates.first[1] += 1
      end

      run_attack('omitted_invocation', 'invocation roster is incomplete, duplicated, or out of order') do |saved|
        summary = load_summary
        records = summary.fetch('invocations')
        original_count = records.size
        records.reject! { |record| record.fetch('label') == 'helper_inspect_stock_part' }
        fail!('omission did not remove exactly one invocation') unless records.size == original_count - 1
        write_summary!(summary, saved)
        true
      end

      run_symlink_attack

      final = audit('baseline_final', @original_summary_sha)
      assert_success!(final, 'final baseline')
      assert_restored!('final baseline')
      puts JSON.pretty_generate({
        'format' => 'static_nested_handoff_w248_adversary_v1',
        'status' => 'all_controls_rejected_and_capture_restored',
        'evidence_root' => @root,
        'original_summary_sha256' => @original_summary_sha,
        'initial_inventory_sha256' => @initial_inventory_sha,
        'final_inventory_sha256' => sha(JSON.generate(inventory)),
        'entry_count' => @initial_inventory.size,
        'audits' => @audits,
      })
      true
    end

    private

    def fail!(message)
      raise Failure, "W248 adversary: #{message}"
    end

    def canonical_root(path)
      expanded = File.expand_path(path)
      fail!('evidence root is absent, symlinked, or noncanonical') unless
        File.directory?(expanded) && !File.symlink?(expanded) && File.realpath(expanded) == expanded &&
        File.dirname(expanded) == File.realpath('/private/tmp')
      expanded
    rescue SystemCallError => error
      fail!("evidence root cannot be resolved: #{error.message}")
    end

    def canonical_file(path, label)
      expanded = File.expand_path(path)
      fail!("#{label} is absent, symlinked, or noncanonical") unless
        File.file?(expanded) && !File.symlink?(expanded) && File.realpath(expanded) == expanded
      expanded
    rescue SystemCallError => error
      fail!("#{label} cannot be resolved: #{error.message}")
    end

    def sha(bytes)
      Digest::SHA256.hexdigest(bytes)
    end

    def read_regular(path, limit, label)
      stat = File.lstat(path)
      fail!("#{label} is absent, non-regular, symlinked, or oversized") unless stat.file? && !stat.symlink? && stat.size <= limit
      bytes = File.binread(path)
      after = File.lstat(path)
      fail!("#{label} changed while reading") unless after.file? && !after.symlink? && after.size == stat.size && bytes.bytesize == stat.size
      bytes
    rescue SystemCallError => error
      fail!("#{label} cannot be read: #{error.message}")
    end

    def parse_json(bytes, label)
      JSON.parse(bytes)
    rescue JSON::ParserError => error
      fail!("#{label} is invalid JSON: #{error.message}")
    end

    def load_summary
      parse_json(read_regular(@summary_path, 16 * 1024 * 1024, 'summary'), 'summary')
    end

    def inventory
      rows = []
      total = 0
      stack = [[@root, '']]
      until stack.empty?
        directory, relative_parent = stack.pop
        Dir.children(directory).sort.each do |name|
          path = File.join(directory, name)
          relative = relative_parent.empty? ? name : File.join(relative_parent, name)
          stat = File.lstat(path)
          if stat.symlink?
            target = File.readlink(path).b
            total += target.bytesize
            rows << [relative, 'symlink', target.unpack1('H*')]
          elsif stat.directory?
            rows << [relative, 'directory']
            stack << [path, relative]
          elsif stat.file?
            fail!('capture inventory exceeds per-file bound') if stat.size > MAX_FILE_BYTES
            total += stat.size
            rows << [relative, 'file', stat.size, Digest::SHA256.file(path).hexdigest]
          else
            fail!("capture contains unsupported special entry: #{relative}")
          end
          fail!('capture inventory exceeds bounds') if rows.size > MAX_ENTRIES || total > MAX_CAPTURE_BYTES
        end
      end
      rows.sort_by(&:first)
    rescue SystemCallError => error
      fail!("capture inventory cannot be read: #{error.message}")
    end

    def assert_restored!(label)
      fail!("#{label} changed the typed capture inventory") unless inventory == @initial_inventory
    end

    def audit(name, summary_sha)
      args = ['--evidence-root', @root, '--expected-summary-sha256', summary_sha]
      @pins.each { |key, value| args.concat(["--#{key.tr('_', '-')}", value]) }
      out, err, status = Open3.capture3(RbConfig.ruby, @auditor, *args, stdin_data: ''.b)
      fail!("#{name} auditor output exceeded its bound") if out.bytesize > MAX_AUDITOR_OUTPUT || err.bytesize > MAX_AUDITOR_OUTPUT
      record = {
        'name' => name, 'exit' => status.exitstatus, 'signal' => status.termsig,
        'stdout_bytes' => out.bytesize, 'stdout_sha256' => sha(out),
        'stderr_bytes' => err.bytesize, 'stderr_sha256' => sha(err),
      }
      @audits << record
      record.merge('stdout' => out, 'stderr' => err, 'success' => status.success?)
    end

    def assert_success!(result, label)
      fail!("#{label} did not authenticate the original capture: #{result.fetch('stderr')}") unless
        result.fetch('success') && result.fetch('stderr').empty? &&
        result.fetch('stdout').include?('W248 audit=authenticated ')
    end

    def assert_rejection!(result, label, expected)
      err = result.fetch('stderr')
      fail!("#{label} was not rejected by the intended guard; stderr=#{err.inspect}") unless
        result.fetch('exit') == 1 && result.fetch('signal').nil? && result.fetch('stdout').empty? &&
        err.lines.size == 1 && err.include?("W248 audit: #{expected}")
    end

    def run_attack(name, expected, &mutation)
      before = inventory
      saved = {}
      begin
        summary_changed = mutation.call(saved)
        summary_sha = summary_changed ? file_sha(@summary_path) : @original_summary_sha
        result = audit(name, summary_sha)
        expected_reason = expected.respond_to?(:call) ? expected.call(result) : expected
        assert_rejection!(result, name, expected_reason)
      ensure
        restore!(saved)
        assert_restored!(name)
        fail!("#{name} precondition inventory changed unexpectedly") unless before == @initial_inventory
      end
    end

    def run_helper_report_attack(name, expected, &transform)
      run_attack(name, expected) do |saved|
        summary = load_summary
        record = record_in(summary, 'helper_write')
        stdout_path = stdout_path(record)
        stdout = read_regular(stdout_path, MAX_AUDITOR_OUTPUT * 16, 'helper stdout')
        report_lines = stdout.lines.map(&:chomp).reject(&:empty?)
        fail!('helper write report is not exactly one JSON object') unless report_lines.size == 1
        report = parse_json(report_lines.first, 'helper write report')
        transform.call(report)
        summary.fetch('helper_reports')['write'] = report
        rebound = JSON.generate(report) + "\n"
        rebind_stdout!(summary, record, rebound, saved)
        write_summary!(summary, saved)
        true
      end
    end

    def invocation(label)
      record_in(load_summary, label)
    end

    def record_in(summary, label)
      matches = summary.fetch('invocations').select { |record| record['label'] == label }
      fail!("capture does not contain exactly one #{label} invocation") unless matches.size == 1
      matches.first
    end

    def stdout_path(record)
      name = record.fetch('stdout_file')
      fail!('stdout artifact name is unsafe') unless name.is_a?(String) && File.basename(name) == name
      File.join(@root, 'invocations', name)
    end

    def invocation_record_path(label)
      File.join(@root, 'invocations', "#{label}.json")
    end

    def save!(saved, path)
      return if saved.key?(path)
      bytes = read_regular(path, MAX_AUDITOR_OUTPUT * 16, 'mutable capture artifact')
      saved[path] = bytes
    end

    def rebind_stdout!(summary, record, stdout, saved)
      label = record.fetch('label')
      path = stdout_path(record)
      save!(saved, path)
      File.binwrite(path, stdout)
      record['stdout_bytes'] = stdout.bytesize
      record['stdout_sha256'] = sha(stdout)
      record_path = invocation_record_path(label)
      save!(saved, record_path)
      File.binwrite(record_path, JSON.generate(record) + "\n")
    end

    def write_summary!(summary, saved)
      save!(saved, @summary_path)
      File.binwrite(@summary_path, JSON.pretty_generate(summary) + "\n")
    end

    def replace_check_line(bytes)
      lines = bytes.lines
      begins = lines.each_index.select { |index| lines[index].chomp == CHECK_BEGIN }
      ends = lines.each_index.select { |index| lines[index].chomp == CHECK_END }
      fail!('attached CHECK delimiters are not unique and ordered') unless
        begins.size == 1 && ends.size == 1 && begins.first < ends.first
      expected = "#{PART_NAME}\t1\t"
      matches = ((begins.first + 1)...ends.first).select { |index| lines[index].chomp == expected }
      fail!('attached CHECK row is absent or duplicated') unless matches.size == 1
      lines[matches.first] = "#{PART_NAME}\t0\t\n".b
      lines.join.b
    end

    def file_sha(path)
      stat = File.lstat(path)
      fail!('summary is not a regular non-symlink file') unless stat.file? && !stat.symlink?
      Digest::SHA256.file(path).hexdigest
    end

    def restore!(saved)
      errors = []
      saved.each do |path, bytes|
        begin
          stat = File.lstat(path)
          raise Failure, 'restore target is not a regular file' unless stat.file? && !stat.symlink?
          File.binwrite(path, bytes)
          raise Failure, 'restored bytes differ' unless read_regular(path, MAX_FILE_BYTES, 'restored artifact') == bytes
        rescue StandardError => error
          errors << "#{path}: #{error.class}: #{error.message}"
        end
      end
      fail!("capture restoration failed: #{errors.join('; ')}") unless errors.empty?
    end

    def run_symlink_attack
      path = File.join(@root, 'generated', PART_NAME, LINK_NAME)
      fail!('hidden symlink attack path already exists') if File.exist?(path) || File.symlink?(path)
      created = false
      begin
        File.symlink(LINK_TARGET, path)
        created = true
        result = audit('hidden_generated_part_symlink', @original_summary_sha)
        assert_rejection!(result, 'hidden generated PART symlink',
          "Crystal-generated PART must be flat and link-free: #{LINK_NAME}")
      ensure
        if created
          fail!('attack symlink was replaced or retargeted before cleanup') unless
            File.symlink?(path) && File.readlink(path) == LINK_TARGET
          File.unlink(path)
        end
        assert_restored!('hidden generated PART symlink')
      end
    end
  end

  def self.parse_options(argv)
    options = {}
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: ruby scripts/check_static_nested_handoff_w248_adversary.rb --evidence-root DIR --expected-helper-sha256 SHA --expected-probe-sha256 SHA --expected-auditor-sha256 SHA --expected-helper-source-sha256 SHA --expected-fixture-sha256 SHA'
      opts.on('--evidence-root DIR') { |value| options[:evidence_root] = value }
      EXTERNAL_PINS.each do |key|
        opts.on("--#{key.tr('_', '-')} SHA") { |value| options[key.to_sym] = value }
      end
    end
    parser.parse!(argv)
    raise Failure, 'unexpected command-line arguments' unless argv.empty?
    required = [:evidence_root] + EXTERNAL_PINS.map(&:to_sym)
    missing = required.reject { |key| options.key?(key) }
    raise Failure, "missing required option --#{missing.first.to_s.tr('_', '-')}" unless missing.empty?
    options
  end

  def self.main(argv = ARGV)
    Harness.new(parse_options(argv)).run
  rescue StandardError => error
    warn "W248 adversary failed: #{error.class}: #{error.message}"
    false
  end
end

if $PROGRAM_NAME == __FILE__
  exit(CheckStaticNestedHandoffW248Adversary.main ? 0 : 1)
end
