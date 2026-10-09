#!/usr/bin/env ruby
# Paired public Object-part roundtrip and native ATTACH evidence for W234.
# This runner consumes the separately captured stock parts; it never mutates them.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'optparse'
require_relative 'recheck_aggregate_recursive_w224'
require_relative 'recheck_object_qbit_recursive_stock_w234'

module RecheckObjectRecursiveQBitEvidenceW234
  extend self

  R = RecheckAggregateRecursiveW224
  S = RecheckObjectQBitRecursiveStockW234
  Q = S::Q
  REPO_ROOT = '/Users/sergey/Projects/Crystal/crystal-click'.freeze
  SOURCE_ROOT = S::SOURCE_ROOT
  SOURCE_REVISION = S::SOURCE_REVISION
  CLICKHOUSE_BIN = S::CLICKHOUSE_BIN
  CLICKHOUSE_SHA256 = S::CLICKHOUSE_SHA256
  CLICKHOUSE_VERSION = S::CLICKHOUSE_VERSION
  CLICKHOUSE_BUILD = S::CLICKHOUSE_BUILD
  EVIDENCE_PREFIX = 'crystal-click-w234-evidence.'.freeze
  HELPER_INPUT_FORMAT = 'object_recursive_qbit_w234_input_v1'.freeze
  HELPER_OUTPUT_FORMAT = 'object_recursive_qbit_w234_helper_v1'.freeze
  RESULT_FORMAT = 'object_recursive_qbit_evidence_w234_v1'.freeze
  PROFILE_IDS = %w[typed_dynamic inferred_dynamic forced_shared].freeze
  ROW_KEYS = [1, 2, 3, 4, 5, 6].freeze
  MARK_ROWS = [2, 2, 2].freeze
  SYSTEM_MARKS = 4
  MEMORY_LIMIT_BYTES = 1_073_741_824
  PROCESS_TIMEOUT_SECONDS = 90
  HELPER_TIMEOUT_SECONDS = 600
  MAX_PROCESSES = 40
  MAX_FILES = 4096
  MAX_TOTAL_BYTES = 64 * 1024 * 1024
  MAX_TREE_ENTRIES = 4096
  MAX_TREE_BYTES = 64 * 1024 * 1024
  INVALIDATED_FILE = 'invalidated_system_columns.txt'.freeze
  INVALIDATED_NAMES = %w[_block_number _block_offset].freeze
  UUID_RE = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/.freeze
  CODE_PATHS = %w[
    scripts/recheck_object_qbit_recursive_stock_w234.rb
    scripts/recheck_object_recursive_qbit_evidence_w234.rb
    scripts/check_object_recursive_qbit_evidence_w234.rb
    scripts/check_object_recursive_qbit_w234.cr
    scripts/recheck_recursive_qbit_dynamic_w233.rb
    scripts/recheck_aggregate_recursive_w224.rb
  ].freeze

  def fail!(message)
    raise ArgumentError, "W234 paired evidence failed: #{message}"
  end

  def assert!(condition, message)
    fail!(message) unless condition
  end

  def plain_file!(path, label, executable: false)
    full = File.expand_path(path)
    assert!(File.file?(full) && !File.symlink?(full) && File.realpath(full) == full,
      "#{label} is absent, symlinked, or noncanonical: #{full}")
    assert!(!executable || File.executable?(full), "#{label} is not executable")
    full
  end

  def plain_dir!(path, label)
    full = File.expand_path(path)
    assert!(File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full,
      "#{label} is absent, symlinked, or noncanonical: #{full}")
    full
  end

  def sha256_file(path)
    Digest::SHA256.file(plain_file!(path, 'hashed file')).hexdigest
  end

  def validate_root(path, fresh: false)
    full = plain_dir!(path, fresh ? 'fresh evidence root' : 'stock root')
    assert!(File.dirname(full) == File.realpath('/private/tmp'), 'capture root must be a direct /private/tmp child')
    if fresh
      assert!(File.basename(full).start_with?(EVIDENCE_PREFIX) && Dir.children(full).empty?,
        "evidence root must be fresh and named #{EVIDENCE_PREFIX}*")
    else
      assert!(File.basename(full).start_with?(S::ROOT_PREFIX), 'stock root has an unexpected fixed prefix')
    end
    full
  end

  def validate_runtime(path)
    full = plain_file!(path, 'ClickHouse runtime', executable: true)
    assert!(full == CLICKHOUSE_BIN && sha256_file(full) == CLICKHOUSE_SHA256,
      'ClickHouse path/SHA differs from the fixed W234 pin')
    full
  end

  def write_json(path, value)
    R.write_new(path, JSON.pretty_generate(value) + "\n")
  end

  def make_dir(path)
    R.make_dir(path)
  end

  def part_inventory(path)
    root = plain_dir!(path, 'part directory')
    files = []
    count = 0
    bytes = 0
    Find.find(root) do |entry|
      next if entry == root
      count += 1
      assert!(count <= MAX_TREE_ENTRIES && !File.symlink?(entry), 'part inventory exceeds bound or contains a symlink')
      next if File.directory?(entry)
      assert!(File.file?(entry), "part contains a non-regular entry: #{entry}")
      bytes += File.size(entry)
      assert!(bytes <= MAX_TREE_BYTES, 'part inventory exceeds byte bound')
      files << { 'path' => entry[(root.length + 1)..-1], 'size' => File.size(entry), 'sha256' => sha256_file(entry) }
    end
    files.sort_by { |item| item.fetch('path') }
  end

  def atomic_alias!(root, entry, stores)
    relative = entry[(root.length + 1)..-1]
    store_name = nil
    table_name = nil
    target_depth = nil
    if (match = /\Astores\/(typed_dynamic|inferred_dynamic|forced_shared)\/metadata\/default\z/.match(relative))
      store_name = match[1]
      target_depth = 1
    elsif (match = /\Astores\/(typed_dynamic|inferred_dynamic|forced_shared)\/data\/default\/(w234_json_(?:typed_dynamic|inferred_dynamic|forced_shared)|w234_native_(?:typed_dynamic|inferred_dynamic|forced_shared))\z/.match(relative))
      store_name, table_name = match[1], match[2]
      expected_table = if table_name.start_with?('w234_native_')
                         "w234_native_#{store_name}"
                       else
                         S::PROFILES.find { |profile| profile.fetch('id') == store_name }.fetch('table')
                       end
      assert!(table_name == expected_table, "Atomic data alias table/profile mismatch: #{relative}")
      target_depth = 2
    else
      fail!("unsupported directory symlink in evidence root: #{relative}")
    end
    store = stores.fetch(store_name)
    raw = File.readlink(entry)
    grammar = target_depth == 1 ? /\A\.\.\/store\/([0-9a-f]{3})\/([0-9a-f-]{36})\z/ : /\A\.\.\/\.\.\/store\/([0-9a-f]{3})\/([0-9a-f-]{36})\z/
    match = grammar.match(raw)
    assert!(match && UUID_RE.match?(match[2]) && match[1] == match[2][0, 3],
      "Atomic directory alias target does not match bounded grammar: #{relative}")
    physical = File.join(store, 'store')
    target = File.join(physical, match[1], match[2])
    assert!(File.expand_path(raw, File.dirname(entry)) == target, "Atomic alias escapes its isolated store: #{relative}")
    [physical, File.join(physical, match[1]), target].each do |path|
      assert!(File.directory?(path) && !File.symlink?(path) && File.realpath(path) == path,
        "Atomic alias target is missing/noncanonical/chained: #{path}")
    end
    assert!(File.directory?(entry) && File.realpath(entry) == target,
      "Atomic alias does not resolve to its local canonical directory: #{relative}")
    { 'path' => relative, 'target' => raw, 'resolved_target' => target }
  end

  def root_inventory(path, ignore_capture_inventory: true)
    root = plain_dir!(path, 'capture root')
    stores = PROFILE_IDS.to_h { |id| [id, File.join(root, 'stores', id)] }
    files = []
    aliases = []
    count = 0
    bytes = 0
    Find.find(root) do |entry|
      next if entry == root
      if File.symlink?(entry)
        aliases << atomic_alias!(root, entry, stores)
        Find.prune
        next
      end
      next if File.directory?(entry)
      assert!(File.file?(entry), "capture has unsupported filesystem entry: #{entry}")
      count += 1
      bytes += File.size(entry)
      assert!(count <= MAX_FILES && bytes <= MAX_TOTAL_BYTES, 'capture exceeds file/byte bounds')
      next if ignore_capture_inventory && entry == File.join(root, 'capture_inventory.json')
      files << { 'path' => entry[(root.length + 1)..-1], 'size' => File.size(entry), 'sha256' => sha256_file(entry) }
    end
    { 'files' => files.sort_by { |item| item.fetch('path') }, 'directory_aliases' => aliases.sort_by { |item| item.fetch('path') } }
  end

  def tsv_row!(bytes, columns, label)
    text = bytes.dup.force_encoding(Encoding::UTF_8)
    assert!(text.valid_encoding?, "#{label} is not valid UTF-8 TSV")
    lines = text.lines.map { |line| line.chomp.sub(/\r\z/, '') }
    assert!(lines.length == 1, "#{label} must have one TSV row")
    fields = lines.first.split("\t", -1)
    assert!(fields.length == columns, "#{label} TSV field count differs")
    fields
  end

  def expected_stock_labels
    ['runtime-version', 'runtime-build'] + S::PROFILES.flat_map do |profile|
      id = profile.fetch('id')
      ["#{id}-create", "#{id}-insert-rowbinary", "#{id}-check", "#{id}-schema",
        "#{id}-actual-roster", "#{id}-part", *%w[full middle zero].map { |w| "#{id}-direct-path-rowbinary-#{w}" }]
    end
  end

  def raw_record(root, label, sequence, expected_store:, expected_sql:, expected_input: nil, helper: nil, helper_input: nil, helper_output: nil, binary: CLICKHOUSE_BIN)
    base = File.join(root, 'invocations', format('%04d-%s', sequence, label))
    %w[argv.json status.json sql stdout stderr].each do |suffix|
      plain_file!("#{base}.#{suffix}", "#{label} #{suffix}")
    end
    argv_record = JSON.parse(File.binread(base + '.argv.json').force_encoding(Encoding::UTF_8))
    status = JSON.parse(File.binread(base + '.status.json').force_encoding(Encoding::UTF_8))
    sql = File.binread(base + '.sql')
    stdout = File.binread(base + '.stdout')
    stderr = File.binread(base + '.stderr')
    assert!(argv_record.fetch('label') == label && status.fetch('label') == label, "#{label} raw label mismatch")
    expected_sql_bytes = ((expected_sql || '').end_with?("\n") ? (expected_sql || '') : (expected_sql || '') + "\n").b
    assert!(sql == expected_sql_bytes, "#{label} raw SQL bytes differ")
    assert!(argv_record.fetch('environment') == { 'TZ' => 'UTC' }, "#{label} environment differs")
    timeout = helper ? HELPER_TIMEOUT_SECONDS : PROCESS_TIMEOUT_SECONDS
    assert!(argv_record.fetch('timeout_seconds') == timeout, "#{label} timeout differs")
    expected_argv = if helper
                      [helper, helper_input, helper_output]
                    else
                      Q.clickhouse_argv(binary, expected_store, expected_sql)
                    end
    assert!(argv_record.fetch('argv') == expected_argv, "#{label} raw argv differs")
    if expected_input
      stdin_path = plain_file!(base + '.stdin.bin', "#{label} stdin")
      stdin = File.binread(stdin_path)
      assert!(stdin == expected_input.b && argv_record.fetch('stdin_bytes') == stdin.bytesize &&
        argv_record.fetch('stdin_sha256') == Digest::SHA256.hexdigest(stdin), "#{label} stdin bytes/digest differ")
    else
      assert!(!File.exist?(base + '.stdin.bin') && argv_record['stdin_bytes'].nil? && argv_record['stdin_sha256'].nil?,
        "#{label} unexpectedly has stdin")
    end
    success = status.fetch('classification') == 'process_success' && status.fetch('exitstatus') == 0 &&
      status.fetch('signaled') == false && status.fetch('timed_out') == false && status.fetch('spawn_error').nil?
    assert!(success, "#{label} raw child status is not successful")
    assert!(status.fetch('stdout_bytes') == stdout.bytesize && status.fetch('stderr_bytes') == stderr.bytesize,
      "#{label} raw status byte census differs")
    { 'base' => base, 'label' => label, 'status' => status, 'argv' => argv_record,
      'sql' => sql, 'stdout' => stdout, 'stderr' => stderr }
  rescue JSON::ParserError, KeyError => error
    fail!("malformed raw invocation #{label}: #{error.message}")
  end

  def expected_stock_action(profile, label)
    id = profile.fetch('id')
    store = nil
    sql = nil
    input = nil
    case label
    when 'create' then sql = S.create_sql(profile)
    when 'insert-rowbinary'
      sql = "INSERT INTO default.#{profile.fetch('table')} SETTINGS input_format_binary_read_json_as_string=0 FORMAT RowBinary"
      input = S.object_rowbinary_input
    when 'check' then sql = S.check_sql(profile)
    when 'schema' then sql = S.schema_sql(profile)
    when 'actual-roster' then sql = S.actual_roster_sql(profile)
    when 'part' then sql = S.part_sql(profile)
    else
      window = label.sub('direct-path-rowbinary-', '')
      sql = S.window_sql(profile, window)
    end
    [sql, input]
  end

  def verify_stock!(root)
    expected_labels = expected_stock_labels
    stores = PROFILE_IDS.to_h { |id| [id, File.join(root, 'stores', id)] }
    allowed_stores = stores.to_h { |id, path| [File.realpath(path), S::PROFILES.find { |profile| profile.fetch('id') == id }.fetch('table')] }
    initial_inventory = S.inventory_tree(root, allowed_stores: allowed_stores)
    captured_inventory = JSON.parse(File.binread(File.join(root, 'capture_inventory.json')).force_encoding(Encoding::UTF_8))
    assert!(captured_inventory == initial_inventory, 'stock raw file/Atomic-alias inventory differs before reading evidence')
    plain_file!(File.join(root, 'witnesses.json'), 'stock witness')
    plain_file!(File.join(root, 'part_inventories.json'), 'stock part inventory')
    files = JSON.parse(File.binread(File.join(root, 'witnesses.json')).force_encoding(Encoding::UTF_8))
    assert!(files.fetch('format') == 'object_qbit_recursive_stock_w234_v1' &&
      files.fetch('source_reference') == "#{SOURCE_ROOT}@#{SOURCE_REVISION}", 'stock witness source/format differs')
    runtime = files.fetch('runtime')
    assert!(runtime.fetch('version') == CLICKHOUSE_VERSION && runtime.fetch('build_hash') == CLICKHOUSE_BUILD &&
      runtime.fetch('path') == CLICKHOUSE_BIN && runtime.fetch('sha256') == CLICKHOUSE_SHA256 &&
      runtime.fetch('source_revision_is_separately_pinned_not_asserted_as_runtime_lineage') == true,
      'stock witness runtime metadata differs')
    assert!(files.fetch('profiles').map { |p| p.fetch('id') } == PROFILE_IDS, 'stock witness profile roster differs')
    assert!(files.fetch('settings') == S::STOCK_SETTINGS, 'stock settings witness differs')

    records = {}
    version = raw_record(root, 'runtime-version', 1, expected_store: stores.fetch(PROFILE_IDS.first),
      expected_sql: 'SELECT version() FORMAT TSVRaw')
    build_sql = "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw"
    build = raw_record(root, 'runtime-build', 2, expected_store: stores.fetch(PROFILE_IDS.first), expected_sql: build_sql)
    assert!(version.fetch('stdout') == "#{CLICKHOUSE_VERSION}\n" &&
      build.fetch('stdout') == "VERSION_GITHASH=#{CLICKHOUSE_BUILD}\n", 'raw stock runtime pins differ')
    records['runtime-version'] = version
    records['runtime-build'] = build

    all_parts = JSON.parse(File.binread(File.join(root, 'part_inventories.json')).force_encoding(Encoding::UTF_8)).fetch('parts')
    assert!(all_parts.map { |p| p.fetch('id') } == PROFILE_IDS, 'stock part inventory roster differs')
    stock_profiles = []
    sequence = 3
    S::PROFILES.each do |profile|
      id = profile.fetch('id')
      store = stores.fetch(id)
      labels = ["#{id}-create", "#{id}-insert-rowbinary", "#{id}-check", "#{id}-schema",
        "#{id}-actual-roster", "#{id}-part", *%w[full middle zero].map { |w| "#{id}-direct-path-rowbinary-#{w}" }]
      per_label = {}
      labels.each do |label|
        suffix = label.delete_prefix("#{id}-")
        sql, input = expected_stock_action(profile, suffix)
        per_label[label] = raw_record(root, label, sequence, expected_store: store, expected_sql: sql, expected_input: input)
        sequence += 1
      end
      check = per_label.fetch("#{id}-check")
      schema = per_label.fetch("#{id}-schema")
      roster = per_label.fetch("#{id}-actual-roster")
      part = per_label.fetch("#{id}-part")
      assert!(check.fetch('stdout') == "all_1_1_0\t1\t\n", "stock raw CHECK differs for #{id}")
      assert!(schema.fetch('stdout') == S.expected_schema(profile), "stock exact nominal schema differs for #{id}")
      assert!(roster.fetch('stdout') == S.actual_roster_expected(profile), "stock actual type/route roster differs for #{id}")
      fields = part.fetch('stdout').force_encoding(Encoding::UTF_8).lines.map { |line| line.chomp.split("\t", -1) }
      assert!(fields.length == 1 && fields.first.length == 5 &&
        fields.first[0, 4] == ['all_1_1_0', '6', S::PART_MARKS.to_s, 'Wide'], "stock Wide part grid differs for #{id}")
      part_path = File.expand_path(fields.first.fetch(4))
      assert!(part_path.start_with?(store + File::SEPARATOR) && File.directory?(part_path) &&
        !File.symlink?(part_path) && File.realpath(part_path) == part_path, "stock part escaped store for #{id}")
      measured = part_inventory(part_path)
      expected_part = all_parts.find { |item| item.fetch('id') == id }
      assert!(expected_part && expected_part.fetch('part_path') == part_path && expected_part.fetch('files') == measured,
        "stock persisted part inventory differs for #{id}")
      input = S.object_rowbinary_input
      input_file = File.binread(File.join(root, 'literal_rowbinary', "#{id}-input.rowbin"))
      assert!(input_file == input && File.binread(per_label.fetch("#{id}-insert-rowbinary").fetch('base') + '.stdin.bin') == input,
        "stock literal RowBinary input differs for #{id}")
      literal_rows = S.direct_path_expected_rows
      { 'full' => literal_rows.join.b, 'middle' => literal_rows[2, 2].join.b, 'zero' => ''.b }.each do |window, expected|
        output = per_label.fetch("#{id}-direct-path-rowbinary-#{window}")
        assert!(output.fetch('stdout') == expected, "stock #{window} RowBinary differs from independent literal for #{id}")
        expected_file = File.binread(File.join(root, 'literal_rowbinary', "#{id}-#{window}-expected.rowbin"))
        assert!(expected_file == expected, "stock #{window} literal file differs for #{id}")
      end
      stock_profiles << { 'id' => id, 'table' => profile.fetch('table'), 'type' => profile.fetch('type'),
        'part_path' => part_path, 'part_inventory' => measured }
      records.merge!(per_label)
    end
    assert!(records.keys == expected_labels, 'stock raw action roster differs')
    actual_capture = S.inventory_tree(root, allowed_stores: allowed_stores)
    assert!(initial_inventory == actual_capture, 'stock capture changed during paired verification')
    { 'records' => records, 'profiles' => stock_profiles, 'capture_inventory' => actual_capture,
      'source_part_inventory' => stock_profiles.to_h { |p| [p.fetch('id'), p.fetch('part_inventory')] } }
  rescue JSON::ParserError, KeyError => error
    fail!("malformed stock capture: #{error.message}")
  end

  def evidence_clickhouse_argv(binary, store, sql)
    Q.clickhouse_argv(binary, store, sql)
  end

  class Probe
    def initialize(options)
      @binary = RecheckObjectRecursiveQBitEvidenceW234.validate_runtime(options.fetch(:clickhouse))
      @helper = RecheckObjectRecursiveQBitEvidenceW234.plain_file!(options.fetch(:helper), 'prebuilt Crystal helper', executable: true)
      @helper_sha = options.fetch(:helper_sha256)
      RecheckObjectRecursiveQBitEvidenceW234.assert!(/\A[0-9a-f]{64}\z/.match?(@helper_sha), 'helper SHA must be lowercase 64-hex')
      RecheckObjectRecursiveQBitEvidenceW234.assert!(RecheckObjectRecursiveQBitEvidenceW234.sha256_file(@helper) == @helper_sha,
        'prebuilt helper differs from exact CLI hash pin')
      @stock_root = RecheckObjectRecursiveQBitEvidenceW234.validate_root(options.fetch(:stock_root))
      @root = RecheckObjectRecursiveQBitEvidenceW234.validate_root(options.fetch(:evidence_root), fresh: true)
      @stock = RecheckObjectRecursiveQBitEvidenceW234.verify_stock!(@stock_root)
      @recorder = R::Recorder.new(@root, @binary)
      @stores = {}
      @native_records = []
      @library_inventories = {}
    end

    def run
      prepare_layout
      runtime_pin = pin_runtime
      helper_output = run_helper
      helper_by_id = helper_output.fetch('profiles').to_h { |item| [item.fetch('id'), item] }
      S::PROFILES.each do |profile|
        target = create_native(profile)
        @native_records << attach_native(profile, target, helper_by_id.fetch(profile.fetch('id')))
      end
      assert!(stock_unchanged?, 'stock part files changed during paired phase')
      code_pins = CODE_PATHS.to_h do |relative|
        [relative, RecheckObjectRecursiveQBitEvidenceW234.sha256_file(File.join(REPO_ROOT, relative))]
      end
      helper_input = File.join(@root, 'generated', 'helper-input.json')
      helper_record = raw_record('helper-public-object-roundtrip', @helper_sequence,
        expected_store: File.join(@root, 'generated'), expected_sql: nil, helper: @helper,
        helper_input: helper_input, helper_output: File.join(@root, 'generated'), binary: @binary)
      result = {
        'format' => RESULT_FORMAT, 'classification' => 'object_recursive_qbit_paired_profiles_observed', 'success' => true,
        'stock_root' => @stock_root, 'evidence_root' => @root,
        'source_pin' => { 'root' => SOURCE_ROOT, 'revision' => SOURCE_REVISION },
        'runtime_pin' => runtime_pin, 'helper_path' => @helper, 'helper_sha256' => @helper_sha,
        'helper_sha256_after' => RecheckObjectRecursiveQBitEvidenceW234.sha256_file(@helper),
        'helper_input_path' => helper_input, 'helper_input_sha256' => RecheckObjectRecursiveQBitEvidenceW234.sha256_file(helper_input),
        'helper_stdout_sha256' => Digest::SHA256.hexdigest(helper_record.fetch('stdout')),
        'code_pins' => code_pins, 'profiles' => S::PROFILES,
        'stock_profiles' => @stock.fetch('profiles'), 'helper_output' => helper_output,
        'library_inventories' => @library_inventories, 'native_profiles' => @native_records,
        'evidence_process_count' => @recorder.records.length,
        'evidence_process_labels' => @recorder.records.map { |record| record.fetch('label') },
        'scope' => 'three fixed Object runtime profiles: typed Dynamic q, inferred Dynamic q, and forced-shared q; six-row/three-mark actuals Array(QBit), named Tuple(QBit, UInt8), and Map(String, QBit); public read/write, native ATTACH/CHECK, and literal direct-path RowBinary windows; no all-types or performance claim',
      }
      write_json(File.join(@root, 'result.json'), result)
      write_json(File.join(@root, 'capture_inventory.json'), RecheckObjectRecursiveQBitEvidenceW234.root_inventory(@root))
      check_budget!
      puts "W234 paired Object evidence: 3 fixed profiles; #{result.fetch('evidence_process_count')} raw child invocations; #{@root}"
      true
    rescue StandardError => error
      warn "W234 paired evidence stopped with raw captures preserved: #{error.class}: #{error.message}"
      false
    end

    private

    def assert!(condition, message)
      RecheckObjectRecursiveQBitEvidenceW234.assert!(condition, message)
    end

    def write_json(path, value)
      RecheckObjectRecursiveQBitEvidenceW234.write_json(path, value)
    end

    def prepare_layout
      %w[invocations generated generated/parts literal_rowbinary cases stores].each do |relative|
        make_dir(File.join(@root, relative))
      end
      S::PROFILES.each do |profile|
        store = File.join(@root, 'stores', profile.fetch('id'))
        make_dir(store)
        make_dir(File.join(@root, 'generated', 'parts', profile.fetch('id')))
        @stores[profile.fetch('id')] = store
      end
    end

    def make_dir(path)
      RecheckObjectRecursiveQBitEvidenceW234.make_dir(path)
    end

    def run_clickhouse(label, store, sql, input: nil)
      assert!(@recorder.records.length < MAX_PROCESSES, 'paired process cap exceeded')
      result = @recorder.run(label, store, sql, input: input, timeout: PROCESS_TIMEOUT_SECONDS,
        argv: Q.clickhouse_argv(@binary, store, sql))
      success = result.fetch('classification') == 'process_success' && result.fetch('exitstatus') == 0 &&
        !result.fetch('signaled') && !result.fetch('timed_out') && result.fetch('spawn_error').nil?
      assert!(success, "#{label} failed; raw invocation preserved at #{result.fetch('path')}")
      result
    end

    def pin_runtime
      store = @stores.fetch(PROFILE_IDS.first)
      version = run_clickhouse('runtime-version-pin', store, 'SELECT version() FORMAT TSVRaw')
      build_sql = "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw"
      build = run_clickhouse('runtime-build-pin', store, build_sql)
      assert!(version.fetch('stdout') == "#{CLICKHOUSE_VERSION}\n" &&
        build.fetch('stdout') == "VERSION_GITHASH=#{CLICKHOUSE_BUILD}\n", 'raw paired runtime pin differs')
      { 'binary' => @binary, 'sha256' => CLICKHOUSE_SHA256, 'version' => CLICKHOUSE_VERSION,
        'build_hash' => CLICKHOUSE_BUILD,
        'source_revision_is_separately_pinned_not_asserted_as_runtime_lineage' => true,
        'version_capture' => File.basename(version.fetch('path')), 'build_capture' => File.basename(build.fetch('path')) }
    end

    def helper_input
      {
        'format' => HELPER_INPUT_FORMAT, 'stock_root' => @stock_root,
        'profiles' => S::PROFILES.map do |profile|
          stock = @stock.fetch('profiles').find { |item| item.fetch('id') == profile.fetch('id') }
          { 'id' => profile.fetch('id'), 'source_part' => stock.fetch('part_path'),
            'library_part' => File.join(@root, 'generated', 'parts', profile.fetch('id'), 'all_1_1_0') }
        end,
      }
    end

    def run_helper
      input_path = File.join(@root, 'generated', 'helper-input.json')
      manifest = helper_input
      write_json(input_path, manifest)
      manifest.fetch('profiles').each do |profile|
        part = profile.fetch('library_part')
        assert!(!File.exist?(part) && !File.symlink?(part), 'library part destination is not fresh')
      end
      assert!(RecheckObjectRecursiveQBitEvidenceW234.sha256_file(@helper) == @helper_sha, 'helper changed before execution')
      @helper_input_sha = RecheckObjectRecursiveQBitEvidenceW234.sha256_file(input_path)
      @helper_sequence = @recorder.records.length + 1
      output_dir = File.join(@root, 'generated')
      record = @recorder.run('helper-public-object-roundtrip', output_dir, nil,
        timeout: HELPER_TIMEOUT_SECONDS, argv: [@helper, input_path, output_dir])
      success = record.fetch('classification') == 'process_success' && record.fetch('exitstatus') == 0 &&
        !record.fetch('signaled') && !record.fetch('timed_out') && record.fetch('spawn_error').nil?
      assert!(success, "public helper failed; raw invocation preserved at #{record.fetch('path')}")
      output = JSON.parse(record.fetch('stdout').force_encoding(Encoding::UTF_8))
      assert!(output.fetch('format') == HELPER_OUTPUT_FORMAT && output.fetch('profile_ids') == PROFILE_IDS,
        'public helper output format/profile roster differs')
      helper_profiles = output.fetch('profiles')
      assert!(helper_profiles.map { |item| item.fetch('id') } == PROFILE_IDS, 'public helper profile order differs')
      helper_profiles.zip(S::PROFILES).each do |item, profile|
        assert!(item.fetch('column') == 'j' && item.fetch('declared_type') == profile.fetch('type'),
          "public helper nominal type differs for #{profile.fetch('id')}")
        %w[source library].each do |side|
          scan = item.fetch(side)
          rows = S.direct_path_expected_rows.map { |row| row.byteslice(8..) }
          assert!(scan.fetch('row_count') == 6 && scan.fetch('mark_row_counts') == MARK_ROWS &&
            scan.fetch('schema_declaration') == profile.fetch('type') && scan.fetch('exact_nominal_and_qbit_literal_checks') == true,
            "public helper grid/type/QBit assertions differ for #{profile.fetch('id')}/#{side}")
          assert!(scan.fetch('windows').fetch('full') == rows.map { |v| v.unpack1('H*') } &&
            scan.fetch('windows').fetch('middle') == rows[2, 2].map { |v| v.unpack1('H*') } &&
            scan.fetch('windows').fetch('zero') == [] && scan.fetch('windows').fetch('eof_returned_marks') == 0,
            "public helper full/middle/zero/EOF direct RowBinary differs for #{profile.fetch('id')}/#{side}")
          assert!(scan.fetch('physical_stream_names').is_a?(Array) &&
            scan.fetch('physical_stream_names').uniq == scan.fetch('physical_stream_names'),
            "public helper physical stream roster is malformed for #{profile.fetch('id')}/#{side}")
        end
        expected_part = manifest.fetch('profiles').find { |p| p.fetch('id') == profile.fetch('id') }.fetch('library_part')
        assert!(item.fetch('library_part_path') == expected_part, "public helper output path differs for #{profile.fetch('id')}")
        @library_inventories[profile.fetch('id')] = RecheckObjectRecursiveQBitEvidenceW234.part_inventory(expected_part)
        assert!(item.fetch('source') == item.fetch('library'), "public reader source/library results differ for #{profile.fetch('id')}")
      end
      write_json(File.join(output_dir, 'helper-output.json'), output)
      write_json(File.join(output_dir, 'library-inventories.json'), {
        'profiles' => S::PROFILES.map { |p| { 'id' => p.fetch('id'), 'path' => helper_profiles.find { |h| h.fetch('id') == p.fetch('id') }.fetch('library_part_path'), 'files' => @library_inventories.fetch(p.fetch('id')) } },
      })
      assert!(RecheckObjectRecursiveQBitEvidenceW234.sha256_file(@helper) == @helper_sha &&
        RecheckObjectRecursiveQBitEvidenceW234.sha256_file(input_path) == @helper_input_sha,
        'helper binary or input manifest changed during execution')
      output
    rescue JSON::ParserError, KeyError => error
      fail!("public helper stdout/evidence malformed: #{error.message}")
    end

    def create_native(profile)
      id = profile.fetch('id')
      table = "w234_native_#{id}"
      store = @stores.fetch(id)
      sql = "CREATE TABLE default.#{table} (id UInt64, j #{profile.fetch('type')}) ENGINE=MergeTree ORDER BY id SETTINGS #{S::STOCK_SETTINGS.join(', ')}"
      create = run_clickhouse("native-create-#{id}", store, sql)
      path_sql = "SELECT arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw"
      path_record = run_clickhouse("native-data-path-#{id}", store, path_sql)
      data_path = File.expand_path(path_record.fetch('stdout').strip)
      assert!(data_path.start_with?(store + File::SEPARATOR) && File.directory?(data_path) &&
        !File.symlink?(data_path) && File.realpath(data_path) == data_path,
        "native data path escaped isolated store for #{id}")
      detached = File.join(data_path, 'detached')
      assert!(File.directory?(detached) && !File.symlink?(detached) && File.realpath(detached) == detached,
        "native detached directory is absent/noncanonical for #{id}")
      { 'id' => id, 'table' => table, 'store' => store, 'data_path' => data_path,
        'detached_part_path' => File.join(detached, 'all_1_1_0'), 'create' => create, 'data_path_record' => path_record }
    end

    def native_roster_sql(profile, table)
      S.actual_roster_sql(profile).sub("default.#{profile.fetch('table')}", "default.#{table}")
    end

    def native_part_sql(profile, table)
      S.part_sql(profile).sub("table='#{profile.fetch('table')}'", "table='#{table}'")
    end

    def native_window_sql(profile, table, window)
      S.window_sql(profile, window).sub("default.#{profile.fetch('table')}", "default.#{table}")
    end

    def attach_native(profile, target, helper_profile)
      id = profile.fetch('id')
      library = helper_profile.fetch('library_part_path')
      before = RecheckObjectRecursiveQBitEvidenceW234.part_inventory(library)
      assert!(before == @library_inventories.fetch(id), "library part changed before ATTACH for #{id}")
      detached = target.fetch('detached_part_path')
      assert!(!File.exist?(detached) && !File.symlink?(detached), "native ATTACH destination is not fresh for #{id}")
      FileUtils.cp_r(library, detached)
      assert!(RecheckObjectRecursiveQBitEvidenceW234.part_inventory(detached) == before,
        "detached library part copy differs for #{id}")
      attach = run_clickhouse("native-attach-#{id}", target.fetch('store'),
        "ALTER TABLE default.#{target.fetch('table')} ATTACH PART 'all_1_1_0'")
      check = run_clickhouse("native-check-#{id}", target.fetch('store'),
        "CHECK TABLE default.#{target.fetch('table')} FORMAT TSVRaw")
      assert!(check.fetch('stdout') == "all_1_1_0\t1\t\n", "native persisted CHECK raw result differs for #{id}")
      schema_sql = "SELECT name, type FROM system.columns WHERE database='default' AND table='#{target.fetch('table')}' ORDER BY position FORMAT TSVRaw"
      schema = run_clickhouse("native-schema-#{id}", target.fetch('store'), schema_sql)
      assert!(schema.fetch('stdout') == "id\tUInt64\nj\t#{profile.fetch('type')}\n", "native exact nominal schema differs for #{id}")
      roster = run_clickhouse("native-roster-#{id}", target.fetch('store'), native_roster_sql(profile, target.fetch('table')))
      assert!(roster.fetch('stdout') == S.actual_roster_expected(profile), "native actual type/route roster differs for #{id}")
      part = run_clickhouse("native-part-#{id}", target.fetch('store'), native_part_sql(profile, target.fetch('table')))
      fields = RecheckObjectRecursiveQBitEvidenceW234.tsv_row!(part.fetch('stdout'), 5, "native part #{id}")
      attached = File.join(target.fetch('data_path'), 'all_1_1_0')
      assert!(fields[0, 4] == ['all_1_1_0', '6', SYSTEM_MARKS.to_s, 'Wide'] &&
        File.expand_path(fields.fetch(4)) == attached && File.directory?(attached) && !File.symlink?(attached),
        "native attached part grid/path differs for #{id}")
      after = RecheckObjectRecursiveQBitEvidenceW234.part_inventory(attached)
      first = before.to_h { |item| [item.fetch('path'), item] }
      second = after.to_h { |item| [item.fetch('path'), item] }
      removed = (first.keys - second.keys).sort
      changed = first.keys.select { |path| second.key?(path) && first.fetch(path) != second.fetch(path) }.sort
      added = (second.keys - first.keys).sort
      assert!(removed.empty? && changed.empty? && [[], [INVALIDATED_FILE]].include?(added),
        "native ATTACH changed library part beyond the one optional invalidated file for #{id}")
      if added == [INVALIDATED_FILE]
        names = File.binread(File.join(attached, INVALIDATED_FILE)).split("\n", -1)
        assert!(names.pop == '' && names.sort == INVALIDATED_NAMES.sort, "native invalidated system columns differ for #{id}")
      end
      columns = File.binread(File.join(attached, 'columns.txt'))
      expected_columns = "columns format version: 1\n2 columns:\n`id` UInt64\n`j` #{profile.fetch('type')}\n".b
      assert!(columns == expected_columns, "native attached columns metadata differs for #{id}")
      codec = File.binread(File.join(attached, 'default_compression_codec.txt')).strip
      metadata = File.binread(File.join(attached, 'metadata_version.txt')).strip
      assert!(codec == 'CODEC(LZ4)' && metadata == '0', "native codec/metadata version differs for #{id}")
      expected_rows = S.direct_path_expected_rows
      windows = {}
      %w[full middle zero].each do |window|
        output = run_clickhouse("native-rowbinary-#{id}-#{window}", target.fetch('store'),
          native_window_sql(profile, target.fetch('table'), window))
        expected = { 'full' => expected_rows.join.b, 'middle' => expected_rows[2, 2].join.b, 'zero' => ''.b }.fetch(window)
        assert!(output.fetch('stdout') == expected, "native #{window} direct-path RowBinary differs for #{id}")
        expected_file = File.join(@root, 'literal_rowbinary', "native-#{id}-#{window}-expected.rowbin")
        R.write_new(expected_file, expected)
        windows[window] = { 'bytes' => expected.bytesize, 'sha256' => Digest::SHA256.hexdigest(expected),
          'expected_literal' => File.basename(expected_file), 'capture' => File.basename(output.fetch('path')) }
      end
      record = {
        'id' => id, 'table' => target.fetch('table'), 'declared_type' => profile.fetch('type'),
        'library_part_path' => library, 'attached_part_path' => attached,
        'library_inventory' => before, 'attached_inventory' => after,
        'removed_paths' => removed, 'changed_paths' => changed, 'added_paths' => added,
        'check_output' => check.fetch('stdout'), 'schema_output' => schema.fetch('stdout'),
        'roster_output' => roster.fetch('stdout'), 'columns_sha256' => Digest::SHA256.hexdigest(columns),
        'default_compression_codec' => codec, 'metadata_version' => metadata, 'windows' => windows,
      }
      write_json(File.join(@root, 'cases', "#{id}.json"), record)
      record
    end

    def raw_record(label, sequence, expected_store:, expected_sql:, expected_input: nil, helper: nil, helper_input: nil, helper_output: nil, binary: @binary)
      RecheckObjectRecursiveQBitEvidenceW234.raw_record(@root, label, sequence, expected_store: expected_store,
        expected_sql: expected_sql, expected_input: expected_input, helper: helper, helper_input: helper_input,
        helper_output: helper_output, binary: binary)
    end

    def stock_unchanged?
      @stock.fetch('profiles').all? do |profile|
        RecheckObjectRecursiveQBitEvidenceW234.part_inventory(profile.fetch('part_path')) == profile.fetch('part_inventory')
      end
    end

    def check_budget!
      inventory = RecheckObjectRecursiveQBitEvidenceW234.root_inventory(@root)
      assert!(@recorder.records.length <= MAX_PROCESSES, 'paired process budget exceeded')
      assert!(inventory.fetch('files').length <= MAX_FILES, 'paired file count exceeded')
    end
  end

  def main(argv)
    options = { clickhouse: CLICKHOUSE_BIN }
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: ruby scripts/recheck_object_recursive_qbit_evidence_w234.rb --stock-root ROOT --evidence-root EMPTY_ROOT --helper BIN --helper-sha256 SHA [--clickhouse PINNED_BIN]'
      opts.on('--stock-root PATH') { |value| options[:stock_root] = value }
      opts.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
      opts.on('--helper PATH') { |value| options[:helper] = value }
      opts.on('--helper-sha256 SHA') { |value| options[:helper_sha256] = value }
      opts.on('--clickhouse PATH') { |value| options[:clickhouse] = value }
    end
    parser.parse!(argv)
    assert!(argv.empty? && %i[stock_root evidence_root helper helper_sha256].all? { |key| options.key?(key) }, parser.to_s)
    Probe.new(options).run
  rescue StandardError => error
    warn "W234 paired runner setup stopped: #{error.class}: #{error.message}"
    false
  end
end

exit(RecheckObjectRecursiveQBitEvidenceW234.main(ARGV) ? 0 : 1) if $PROGRAM_NAME == __FILE__
