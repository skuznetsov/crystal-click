#!/usr/bin/env ruby
# Mutate an authenticated W247 capture and run only its offline Ruby auditor.
# The caller supplies a disposable capture and a separate empty /private/tmp child.
require 'digest'
require 'find'
require 'json'
require 'open3'
require 'optparse'
require 'rbconfig'

module CheckStaticBinaryBulkTableW247Adversary
  class Failure < StandardError; end

  class Harness
    EXTERNALS = %w[clickhouse helper helper-sha256 probe-source probe-source-sha256 helper-source helper-source-sha256 fixture-source fixture-source-sha256 auditor-source auditor-source-sha256].freeze
    CHECK_ONE = "all_1_1_0\t1\t".freeze
    CHECK_ZERO = "all_1_1_0\t0\t".freeze
    # Hex bytes for the JSON substring `"root-string"` and its replacement.
    ROW_BEFORE = '22726F6F742D737472696E6722'.freeze
    ROW_AFTER = '22706F69736F6E2D737472696E6722'.freeze
    STORE_RELATIVE_PREFIX = 'stores/native/'.freeze
    MAX_FILES = 50_000
    MAX_BYTES = 1024 * 1024 * 1024

    def initialize(options)
      @options = options
      @summary = canonical(options.fetch(:summary), 'summary')
      @root = File.dirname(@summary)
      @reports = canonical(options.fetch(:report_root), 'report root', true)
      tmp = File.realpath('/private/tmp')
      fail!('capture root must be a direct canonical /private/tmp child') unless File.realpath(@root) == @root && File.dirname(@root) == tmp
      fail!('report root must be another direct canonical /private/tmp child') unless @reports != @root && File.dirname(@reports) == tmp
      fail!('report root must be empty') unless Dir.children(@reports).empty?
      @summary_sha = options.fetch(:summary_sha256).downcase
      fail!('summary SHA-256 is malformed') unless sha_syntax?(@summary_sha)
      fail!('summary differs from supplied original SHA-256') unless sha_file(@summary) == @summary_sha
      @alias_links = prepare_alias_expectations!
      EXTERNALS.each { |key| fail!("--#{key} is required") unless options[key.to_sym] }
      @auditor = canonical(options.fetch(:'auditor-source'), 'auditor source')
      fail!('auditor source is not the W247 auditor') unless File.basename(@auditor) == 'audit_static_binary_bulk_table_w247.rb'
      @report_path = File.join(@reports, 'adversary_report.json')
      @report = {'format' => 'static_binary_bulk_table_w247_adversary_v1',
                 'scope' => 'Ruby auditor only; no Crystal or ClickHouse launch',
                 'status' => 'running', 'capture_root' => @root, 'summary' => @summary,
                 'audits' => [], 'controls' => []}
    end

    def run
      %w[audits backups].each { |name| Dir.mkdir(File.join(@reports, name), 0o700) }
      @initial_inventory = inventory
      @initial_sha = Digest::SHA256.hexdigest(JSON.generate(@initial_inventory))
      @report['initial_evidence_inventory_sha256'] = @initial_sha
      write_report
      assert_success!(audit('baseline_initial'), 'initial baseline')
      assert_restored!('initial baseline')

      controls = [
        ['summary_only_native_row', 'input semantic row summary/raw stdout differs', 'semantic_only', method(:mutate_summary_row)],
        ['input_check_zero', 'input CHECK TABLE = 1 differs', 'substantive_native_guard', method(:mutate_check)],
        ['native_json_row', 'input exact literal stock rows differs', 'substantive_literal_oracle', method(:mutate_native_row)],
        ['helper_late_window', 'helper inspect public WidePartTable scan differs', 'substantive_consumer_oracle', method(:mutate_helper)],
        ['helper_array_variant_site_type', 'helper inspect Variant column/site identity differs', 'substantive_recursive_type_identity', method(:mutate_helper_site_type)],
        ['generated_stream_corruption', 'pre-attach raw file closure differs', 'integrity_only_not_semantic', method(:mutate_stream)],
      ]
      controls.each { |control| run_control(*control) }
      assert_success!(audit('baseline_final'), 'final baseline')
      assert_restored!('final baseline')
      @report['status'] = 'adversary_controls_passed'
      @report['final_evidence_inventory_sha256'] = Digest::SHA256.hexdigest(JSON.generate(inventory))
      write_report
      @report
    rescue StandardError => error
      @report['status'] = 'failed'
      @report['failure'] = "#{error.class}: #{error.message}"
      write_report
      raise
    end

    private

    def fail!(message); raise Failure, "W247 adversary: #{message}"; end

    def canonical(path, label, directory = false)
      path = File.expand_path(path)
      exists = directory ? File.directory?(path) : File.file?(path)
      fail!("#{label} is absent, symlinked, or noncanonical") unless exists && !File.symlink?(path) && File.realpath(path) == path
      path
    end

    def sha_file(path); Digest::SHA256.file(path).hexdigest; end
    def sha_syntax?(value); value.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(value); end

    def inventory
      rows, total = [], 0
      seen_aliases = []
      Find.find(@root) do |path|
        next if path == @root
        stat = File.lstat(path)
        relative = path.delete_prefix(@root + File::SEPARATOR)
        if stat.symlink?
          store_relative = relative.start_with?(STORE_RELATIVE_PREFIX) ? relative.delete_prefix(STORE_RELATIVE_PREFIX) : nil
          raw = store_relative && @alias_links[store_relative]
          fail!("capture evidence contains an unexpected symlink: #{path}") unless raw && File.readlink(path) == raw
          validate_alias_target!(store_relative, path, raw)
          seen_aliases << relative
          total += raw.bytesize
          fail!('capture inventory exceeds limits') if rows.size >= MAX_FILES || total > MAX_BYTES
          rows << [relative, 'symlink', raw]
          next
        end
        next if stat.directory?
        fail!("capture evidence contains a non-regular file: #{path}") unless stat.file?
        total += stat.size
        fail!('capture inventory exceeds limits') if rows.size >= MAX_FILES || total > MAX_BYTES
        fail!("capture file is not canonical: #{path}") unless File.realpath(path) == path
        rows << [relative, 'file', stat.size, sha_file(path)]
      end
      expected_aliases = @alias_links.keys.map { |role| "#{STORE_RELATIVE_PREFIX}#{role}" }.sort
      fail!('capture Atomic alias closure differs') unless seen_aliases.sort == expected_aliases
      validate_metadata_alias!
      rows.sort_by(&:first)
    end

    def canonical_store_target(path, label)
      store_root = File.join(@root, 'stores', 'native')
      fail!("#{label} is not a canonical absolute path") unless path.is_a?(String) && path.start_with?(File::SEPARATOR) && File.expand_path(path) == path
      relative = path.delete_prefix(store_root + File::SEPARATOR)
      pieces = relative.split(File::SEPARATOR)
      uuid = pieces[2]
      fail!("#{label} is not a direct store/<prefix>/<UUID> path") unless
        path.start_with?(store_root + File::SEPARATOR) && pieces.size == 3 && pieces[0] == 'store' && uuid &&
        /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/.match?(uuid) && pieces[1] == uuid[0, 3]
      current = store_root
      pieces.each do |piece|
        current = File.join(current, piece)
        fail!("#{label} crosses a symlink") if File.symlink?(current)
      end
      fail!("#{label} is absent or noncanonical") unless File.directory?(path) && File.realpath(path) == path
      path
    end

    def metadata_sql(table_uuid, profile)
      schema = [
        ['pk', 'UInt64'],
        ['root_variant', 'Variant(Array(UInt16), String)'],
        ['array_variant', 'Array(Variant(LowCardinality(String), UInt64))'],
        ['named_recursive', 'Tuple(arr Array(Nullable(Int32)), labels LowCardinality(Nullable(String)), choice Variant(Array(UInt16), String))'],
        ['string0', 'String'], ['string1', 'String'],
      ]
      declarations = schema.map { |name, type| "    `#{name}` #{type}" }.join(",\n")
      string_version = profile == 'single' ? 'single_stream' : 'with_size_stream'
      settings = "index_granularity = 2, index_granularity_bytes = 10485760, " \
        "enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0, " \
        "min_bytes_for_wide_part = 0, min_level_for_wide_part = 0, compress_marks = 0, " \
        "compress_primary_key = 0, min_compress_block_size = 0, max_compress_block_size = 4096, " \
        "ratio_of_defaults_for_sparse_serialization = 1., default_compression_codec = 'LZ4', " \
        "serialization_info_version = 'with_types', use_compact_variant_discriminators_serialization = 0, " \
        "propagate_types_serialization_versions_to_nested_types = true, " \
        "string_serialization_version = '#{string_version}'"
      "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n#{declarations}\n)\nENGINE = MergeTree\nORDER BY pk\nSETTINGS #{settings}\n".b
    end

    def prepare_alias_expectations!
      summary = JSON.parse(File.binread(@summary))
      profile = summary.fetch('string_profile')
      fail!('summary String profile is invalid for Atomic alias inventory') unless %w[single sized].include?(profile)
      token = Digest::SHA256.hexdigest(@root)[0, 8]
      input_table = "w247_#{token}_#{profile}_input"
      reemit_table = "w247_#{token}_#{profile}_reemit"
      paths = summary.fetch('paths')
      store_root = File.join(@root, 'stores', 'native')
      input_path = canonical_store_target(paths.fetch('input_data_path'), 'input table data path')
      reemit_path = canonical_store_target(paths.fetch('reemit_data_path'), 're-emission table data path')
      fail!('input/re-emission data paths are not distinct') if input_path == reemit_path
      links = {
        "data/default/#{input_table}" => "../../store/#{File.basename(input_path)[0, 3]}/#{File.basename(input_path)}",
        "data/default/#{reemit_table}" => "../../store/#{File.basename(reemit_path)[0, 3]}/#{File.basename(reemit_path)}",
      }
      metadata_link = File.join(store_root, 'metadata', 'default')
      fail!('expected Atomic metadata alias is absent') unless File.symlink?(metadata_link)
      metadata_raw = File.readlink(metadata_link)
      match = /\A\.\.\/store\/([0-9a-f]{3})\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\z/.match(metadata_raw)
      fail!('Atomic metadata alias text is not the expected relative UUID path') unless match && match[1] == match[2][0, 3]
      links['metadata/default'] = metadata_raw
      @alias_data_paths = {input_table => input_path, reemit_table => reemit_path}
      @metadata_target = File.expand_path(metadata_raw, File.dirname(metadata_link))
      @metadata_profile = profile
      @metadata_files = {
        "#{input_table}.sql" => metadata_sql(File.basename(input_path), profile),
        "#{reemit_table}.sql" => metadata_sql(File.basename(reemit_path), profile),
      }
      validate_metadata_alias!
      links
    rescue KeyError, TypeError, JSON::ParserError => error
      fail!("summary Atomic alias contract is malformed: #{error.class}: #{error.message}")
    end

    def validate_alias_target!(relative, link, raw)
      store_root = File.join(@root, 'stores', 'native')
      case relative
      when 'metadata/default'
        target = @metadata_target
      else
        table_name = @alias_data_paths.keys.find { |name| relative == "data/default/#{name}" }
        fail!("Atomic table alias role is unexpected: #{relative}") unless table_name
        target = @alias_data_paths.fetch(table_name)
        expected = "../../store/#{File.basename(target)[0, 3]}/#{File.basename(target)}"
        fail!("Atomic table alias text differs: #{relative}") unless raw == expected
      end
      canonical_store_target(target, "Atomic alias #{relative}")
      fail!("Atomic alias does not resolve to its authenticated target: #{relative}") unless
        File.expand_path(raw, File.dirname(link)) == target && File.realpath(link) == target
      if relative == 'metadata/default'
        fail!('Atomic metadata alias resolves to a table data directory') if @alias_data_paths.value?(target)
        expected = "../store/#{File.basename(target)[0, 3]}/#{File.basename(target)}"
        fail!('Atomic metadata alias text differs') unless raw == expected
      end
      true
    end

    def validate_metadata_alias!
      store_root = File.join(@root, 'stores', 'native')
      canonical_store_target(@metadata_target, 'Atomic metadata directory')
      fail!('Atomic metadata alias resolves to a table data directory') if @alias_data_paths.value?(@metadata_target)
      link = File.join(store_root, 'metadata', 'default')
      raw = @alias_links ? @alias_links.fetch('metadata/default') : File.readlink(link)
      validate_alias_target!('metadata/default', link, raw)
      fail!('Atomic metadata directory has unexpected SQL children') unless Dir.children(@metadata_target).sort == @metadata_files.keys.sort
      @metadata_files.each do |name, expected|
        path = File.join(@metadata_target, name)
        fail!("Atomic metadata SQL identity differs: #{name}") unless
          File.file?(path) && !File.symlink?(path) && File.realpath(path) == path &&
          File.size(path) <= 64 * 1024 * 1024 && File.binread(path) == expected
      end
      true
    end

    def assert_restored!(label); fail!("#{label} changed capture evidence") unless inventory == @initial_inventory; end
    def write_report; File.binwrite(@report_path, JSON.pretty_generate(@report) + "\n"); end

    def audit_args
      args = ['--summary', @summary, '--summary-sha256', sha_file(@summary)]
      EXTERNALS.each { |key| args.concat(["--#{key}", @options.fetch(key.to_sym)]) }
      args << '--self-test'
    end

    def audit(name)
      out, err, status = Open3.capture3(RbConfig.ruby, @auditor, *audit_args,
                                        chdir: File.expand_path('..', __dir__), stdin_data: ''.b)
      fail!("#{name} auditor output exceeds bound") if out.bytesize > 1_048_576 || err.bytesize > 1_048_576
      %w[stdout stderr].zip([out, err]).each { |kind, bytes| File.binwrite(File.join(@reports, 'audits', "#{name}.#{kind}"), bytes) }
      result = {'name' => name, 'exit' => status.exitstatus, 'signal' => status.termsig,
                'stdout' => {'bytes' => out.bytesize, 'sha256' => Digest::SHA256.hexdigest(out)},
                'stderr' => {'bytes' => err.bytesize, 'sha256' => Digest::SHA256.hexdigest(err)}}
      @report['audits'] << result
      write_report
      result.merge('out' => out, 'err' => err)
    end

    def assert_success!(result, label)
      text = result['out'].dup.force_encoding(Encoding::UTF_8)
      fail!("#{label} auditor did not exit cleanly") unless result['exit'] == 0 && result['signal'].nil? && result['err'].empty?
      fail!("#{label} auditor output is not one JSON line") unless text.valid_encoding? && text.lines.size == 1 && text.end_with?("\n")
      fail!("#{label} did not authenticate capture") unless JSON.parse(text)['status'] == 'raw_capture_authenticated'
    end

    def assert_rejected!(result, expected, name)
      message = result['err'].dup.force_encoding(Encoding::UTF_8).strip
      valid = [result['exit'], result['signal'], result['out'].empty?, message.lines.size] == [1, nil, true, 1] &&
              message.start_with?("W247 audit: #{expected}")
      fail!("#{name} rejected for unrelated reason: exit=#{result['exit']} stderr=#{message.inspect}") unless valid
      message
    end

    def run_control(name, expected, scope, mutator)
      changes = mutator.call
      fail!("#{name} mutation is empty") if changes.empty?
      backups = save_backups(name, changes)
      failure = reason = nil
      restored = false
      begin
        changes.each { |path, bytes| validate_target!(path); File.binwrite(path, bytes) }
        reason = assert_rejected!(audit(name), expected, name)
      rescue StandardError => error
        failure = "#{error.class}: #{error.message}"
      ensure
        backups.each do |path, bytes|
          begin
            validate_target!(path)
            File.binwrite(path, bytes)
          rescue StandardError => error
            failure ||= "restore failed for #{path}: #{error.class}: #{error.message}"
          end
        end
        begin
          restored = inventory == @initial_inventory
          failure ||= 'full capture inventory differs after restore' unless restored
        rescue StandardError => error
          failure ||= "restore inventory failed: #{error.class}: #{error.message}"
        end
      end
      event = {'name' => name, 'claim_scope' => scope, 'expected_rejection' => expected,
               'observed_rejection' => reason, 'restore_verified' => restored,
               'restored_inventory_sha256' => restored ? @initial_sha : nil,
               'backup_files' => backup_manifest(name, backups), 'audit' => name}
      @report['controls'] << event
      write_report
      fail!("#{name} did not meet rejection/restore contract: #{failure}") if failure
    end

    def save_backups(name, changes)
      dir = File.join(@reports, 'backups', name)
      Dir.mkdir(dir, 0o700)
      changes.keys.sort.each_with_index.each_with_object({}) do |(path, index), backups|
        validate_target!(path)
        bytes = File.binread(path)
        File.binwrite(File.join(dir, format('%02d.bin', index)), bytes)
        backups[path] = bytes
      end
    end

    def backup_manifest(name, backups)
      backups.keys.sort.each_with_index.map do |path, index|
        bytes = backups.fetch(path)
        {'target' => path, 'backup' => File.join(@reports, 'backups', name, format('%02d.bin', index)), 'bytes' => bytes.bytesize, 'sha256' => Digest::SHA256.hexdigest(bytes)}
      end
    end

    def validate_target!(path)
      fail!('mutation target is not canonical') unless path.is_a?(String) && File.expand_path(path) == path && path.start_with?(@root + File::SEPARATOR)
      rel = path.delete_prefix(@root + File::SEPARATOR)
      parts = rel.split(File::SEPARATOR)
      allowed = parts == ['summary.json'] || (parts.size == 2 && parts[0] == 'invocations' && safe_name?(parts[1])) ||
                (parts.size == 3 && parts[0] == 'generated' && parts[1] == 'all_1_1_0' && safe_name?(parts[2]))
      fail!("mutation target outside summary/invocations/generated part: #{path}") unless allowed
      current = @root
      parts.each_with_index do |part, index|
        current = File.join(current, part)
        stat = File.lstat(current)
        fail!("mutation target crosses symlink: #{current}") if stat.symlink?
        fail!("mutation target is not a regular file/parent: #{current}") unless index == parts.size - 1 ? stat.file? : stat.directory?
      end
      fail!("mutation target is noncanonical: #{path}") unless File.realpath(path) == path
    end

    def safe_name?(name); name.is_a?(String) && /\A[A-Za-z0-9_.-]+\z/.match?(name); end
    def summary_object; JSON.parse(File.binread(@summary)); end
    def invocation(summary, label); summary.fetch('invocations').find { |row| row.fetch('label') == label } || fail!("missing invocation #{label}"); end

    def artifact(summary, record, field)
      name = record.fetch("#{field}_file")
      fail!("unsafe #{field} artifact name") unless safe_name?(name)
      path = File.join(@root, 'invocations', name)
      validate_target!(path)
      path
    end

    def update_stdout!(summary, label, bytes, changes)
      record = invocation(summary, label)
      path = artifact(summary, record, 'stdout')
      record_path = File.join(@root, 'invocations', "#{label}.json")
      validate_target!(record_path)
      saved = JSON.parse(File.binread(record_path))
      fail!("#{label} invocation binding differs before mutation") unless saved == record
      size, digest = bytes.bytesize, Digest::SHA256.hexdigest(bytes)
      record['stdout_bytes'] = saved['stdout_bytes'] = size
      record['stdout_sha256'] = saved['stdout_sha256'] = digest
      changes[path] = bytes
      changes[record_path] = JSON.pretty_generate(saved) + "\n"
    end

    def replace_once(bytes, before, after, label)
      fail!("#{label} mutation token is not unique") unless bytes.scan(before).size == 1
      bytes.sub(before, after)
    end

    def mutate_summary_row
      summary = summary_object
      row = summary.fetch('native_rows').fetch('attached').fetch(0)
      fail!('summary row baseline differs') unless row.fetch('string1') == ''
      row['string1'] = 'summary-only-poison'
      {@summary => JSON.pretty_generate(summary) + "\n"}
    end

    def mutate_check
      summary = summary_object
      changes = mutate_native_stdout(summary, CHECK_ONE, CHECK_ZERO, 'input CHECK')
      summary.fetch('parts')['input_check'] = [CHECK_ZERO]
      changes[@summary] = JSON.pretty_generate(summary) + "\n"
      changes
    end

    def mutate_native_row
      summary = summary_object
      changes = mutate_native_stdout(summary, ROW_BEFORE, ROW_AFTER, 'native JSON row')
      row = summary.fetch('native_rows').fetch('attached').find { |entry| entry.fetch('pk') == 2 }
      fail!('native row summary baseline differs') unless row.fetch('root_variant') == 'root-string'
      row['root_variant'] = 'poison-string'
      changes[@summary] = JSON.pretty_generate(summary) + "\n"
      changes
    end

    def mutate_native_stdout(summary, before, after, label)
      record = invocation(summary, 'native_attach_check_rows')
      stdout = File.binread(artifact(summary, record, 'stdout'))
      changes = {}
      update_stdout!(summary, 'native_attach_check_rows', replace_once(stdout, before, after, label), changes)
      changes
    end

    def mutate_helper
      summary = summary_object
      record = invocation(summary, 'helper_inspect_reemit')
      helper = JSON.parse(File.binread(artifact(summary, record, 'stdout')))
      scan = helper.fetch('public_typed_scan').fetch('late_window')
      fail!('helper late-window baseline differs') unless scan.fetch('keys') == [5]
      scan['keys'] = [4]
      bytes = JSON.generate(helper) + "\n"
      summary.fetch('helper_reports')['reemit_inspect'] = helper
      changes = {}
      update_stdout!(summary, 'helper_inspect_reemit', bytes, changes)
      changes[@summary] = JSON.pretty_generate(summary) + "\n"
      changes
    end

    def mutate_helper_site_type
      summary = summary_object
      record = invocation(summary, 'helper_inspect_reemit')
      helper = JSON.parse(File.binread(artifact(summary, record, 'stdout')))
      entry = helper.fetch('physical_profile').fetch('variant_discriminators').find do |variant|
        variant.fetch('column') == 'array_variant'
      end
      fail!('helper Array Variant baseline site differs') unless
        entry && entry.fetch('type') == 'Array(Variant(LowCardinality(String), UInt64))'
      entry['type'] = 'Variant(LowCardinality(String), UInt64)'
      bytes = JSON.generate(helper) + "\n"
      summary.fetch('helper_reports')['reemit_inspect'] = helper
      changes = {}
      update_stdout!(summary, 'helper_inspect_reemit', bytes, changes)
      changes[@summary] = JSON.pretty_generate(summary) + "\n"
      changes
    end

    def mutate_stream
      summary = summary_object
      names = summary.fetch('physical_profiles').fetch('generated').fetch('stream_files')
      name = names.find do |file|
        next false unless safe_name?(file) && file.end_with?('.bin')
        candidate = File.join(@root, 'generated', 'all_1_1_0', file)
        validate_target!(candidate)
        File.size(candidate) > 0
      end
      fail!('no non-empty generated .bin stream') unless name && safe_name?(name)
      path = File.join(@root, 'generated', 'all_1_1_0', name)
      validate_target!(path)
      bytes = File.binread(path)
      bytes.setbyte(0, bytes.getbyte(0) ^ 1)
      {path => bytes}
    end
  end
end

def main
  options = {}
  OptionParser.new do |opts|
    opts.banner = 'Usage: check_static_binary_bulk_table_w247_adversary.rb --summary PATH --summary-sha256 SHA --report-root EMPTY_PRIVATE_TMP_CHILD [auditor externals]'
    opts.on('--summary PATH') { |v| options[:summary] = v }
    opts.on('--summary-sha256 SHA') { |v| options[:summary_sha256] = v }
    opts.on('--report-root PATH') { |v| options[:report_root] = v }
    CheckStaticBinaryBulkTableW247Adversary::Harness::EXTERNALS.each { |key| opts.on("--#{key} VALUE") { |v| options[key.to_sym] = v } }
  end.parse!
  %i[summary summary_sha256 report_root].each { |key| raise ArgumentError, "--#{key.to_s.tr('_', '-')} required" unless options[key] }
  result = CheckStaticBinaryBulkTableW247Adversary::Harness.new(options).run
  puts JSON.generate(status: result['status'], report: File.join(options.fetch(:report_root), 'adversary_report.json'))
rescue StandardError => error
  warn error.message
  exit 1
end

main if $PROGRAM_NAME == __FILE__
