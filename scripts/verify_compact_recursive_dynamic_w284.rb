#!/usr/bin/env ruby
# W284 stock-first discriminator. This is an isolated W284 runner: it does not
# import or inherit W283 policy, defaults, fixtures, or qualification claims.
# At preparation time the Ruby corpus is independent of the Crystal helper.

require 'digest'
require 'find'
require 'json'
require 'open3'
require 'optparse'
require 'rbconfig'
require 'shellwords'

module VerifyCompactRecursiveDynamicW284
  extend self

  FORMAT = 'compact_recursive_dynamic_w284_stock_v1'.freeze
  BINARY = '/opt/mldata_ssd/cache/crystal-click-w283.PDWAiK/recovery/runtime/clickhouse'.freeze
  RUNTIME_PIN = {
    sha256: '5bb43958f4c0806cc363b84b9858e7206e56ac80263a24acc704271322e531ae'.freeze,
    bytes: 919_123_095,
    version: '26.10.1.1201'.freeze,
    build: 'd9bcb5ab007f0f6299f7f973f2642245bab3d028'.freeze,
  }.freeze
  SOURCE_ROOT = '/opt/mldata_ssd/cache/crystal-click-w283.PDWAiK/recovery/source'.freeze
  SOURCE_REVISION = 'ed30948f095ecb70679986d7d60e27ad770ae27a'.freeze
  TASK_ROOT = "/Volumes/Nata's Data/MLData/cache/crystal-click-w284.9Nzwqc".freeze
  SSD_ALIAS = '/opt/mldata_ssd'.freeze
  REPO_ROOT = '/Users/sergey/Projects/Crystal/crystal-click'.freeze
  RUN_SAFE = '/Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh'.freeze
  RUN_SAFE_SHA256 = 'ca3d326eac90731c4915883158d394e72dde766786fadf95a4241acd7f627ea4'.freeze
  OUTER_LAUNCHER = '/opt/mldata_ssd/cache/crystal-click-w283.PDWAiK/regressions/continuation-20261016.QQqwAZ/launch_saved_argv-v2.rb'.freeze
  OUTER_LAUNCHER_SHA256 = 'dab6ee0324614f302e454d89bc32af2ab18e600d1a8eb9b17c659dbb22f2a191'.freeze
  OUTER_LAUNCHER_BYTES = 1_279
  CRYSTAL = '/opt/homebrew/bin/crystal'.freeze
  LINKER = '/usr/bin/ld'.freeze
  BUILD_OUTPUT = "/Volumes/Nata's Data/MLData/cache/crystal-click-w284.9Nzwqc/compact_recursive_dynamic_w284_helper".freeze
  TASK_TMPDIR = "/Volumes/Nata's Data/MLData/cache/crystal-click-w284.9Nzwqc/tmp".freeze
  TASK_CRYSTAL_CACHE = "/Volumes/Nata's Data/MLData/cache/crystal-click-w284.9Nzwqc/crystal-cache".freeze
  MACOS_SDKROOT = '/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk'.freeze

  KEY = 'pk'.freeze
  COLUMN = 'trace'.freeze
  EXPECTED_PART_NAME = 'all_1_1_0'.freeze
  JSON_TYPE = 'JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8)'.freeze
  DYNAMIC_TYPE = 'Dynamic(max_types=1)'.freeze
  TRACE_TYPE = "Array(Tuple(doc #{JSON_TYPE}, sample #{DYNAMIC_TYPE}))".freeze
  MARK_FORMATS = %w[mrk3 mrk4].freeze
  MODES = %w[basic compact].freeze
  PROFILES = %w[s0 s1].freeze
  MODE_VALUES = {'basic' => 0, 'compact' => 1}.freeze
  ROWS_PER_MARK = 2
  ROW_COUNT = 8
  DATA_MARK_COUNT = 4
  MAX_PART_FILES = 256
  MAX_PART_BYTES = 16 * 1024 * 1024
  STREAM_CHUNK_BYTES = 64 * 1024
  PROCESS_TIMEOUT_SECONDS = 60
  WINDOWS = {
    'full' => nil,
    'middle' => 'pk BETWEEN 105 AND 108',
    'last' => 'pk BETWEEN 109 AND 110',
    'eof' => 'pk > 110',
  }.freeze

  # These eight Ruby rows are literal native SQL expectations, not generated
  # from the Crystal fixture or a helper report. The first four preserve W257.
  INPUT_ROWS = [
    {pk: 103, trace: []},
    {pk: 104, trace: [{tag: 14, type: 'UInt64', value: 1040}]},
    {pk: 105, trace: [
      {tag: 15, type: 'String', value: 'child!'},
      {tag: 16, type: 'NULL', value: nil},
    ]},
    {pk: 106, trace: [{tag: 17, type: 'UInt64', value: 1060}]},
    {pk: 107, trace: []},
    {pk: 108, trace: []},
    {pk: 109, trace: [{tag: 18, type: 'NULL', value: nil}]},
    {pk: 110, trace: [{tag: 19, type: 'NULL', value: nil}]},
  ].map(&:freeze).freeze

  # Independently written SQL projection oracle. NULL is not SharedVariant.
  EXPECTED_SIGNATURES = [
    '103|',
    '104|14:UInt64:U1040',
    '105|15:String:S6368696c6421;16:NULL:N',
    '106|17:UInt64:U1060',
    '107|',
    '108|',
    '109|18:NULL:N',
    '110|19:NULL:N',
  ].freeze
  EXPECTED_WINDOWS = {
    'full' => EXPECTED_SIGNATURES,
    'middle' => EXPECTED_SIGNATURES.drop(2).take(4),
    'last' => EXPECTED_SIGNATURES.drop(6).take(2),
    'eof' => [],
  }.freeze
  INPUT_SOURCE_PATHS = [
    File.expand_path(__FILE__),
    File.expand_path('compact_recursive_dynamic_w284_helper.cr', __dir__),
    File.expand_path('support/compact_recursive_dynamic_w284_fixture.cr', __dir__),
  ].freeze
  CASES = MODES.product(MARK_FORMATS, PROFILES).map do |mode, mark, profile|
    {mode: mode, mark: mark, profile: profile, id: "#{mode}_#{mark}_#{profile}".freeze}.freeze
  end.freeze

  class Error < StandardError; end

  class Runner
    def initialize(options)
      @evidence_argument = options.fetch(:evidence_root)
      @source_root_argument = options.fetch(:source_root)
      @binary_argument = options.fetch(:binary)
      @cells = {}
      @processes = []
      @fatal_error = nil
    end

    def print_plan
      planned_cells = CASES.map do |cell|
        id = cell.fetch(:id)
        seed = seed_sql(cell, id)
        reopen = reopen_sql(cell, id)
        case_root = File.join(@evidence_argument, 'cases', id)
        expected_outputs = expected_output_lines
        {
          id: id, mode: cell.fetch(:mode), mark: cell.fetch(:mark), profile: cell.fetch(:profile),
          seed_argv: native_argv(File.join(case_root, 'store')),
          seed_sql_bytes: seed.bytesize,
          seed_sql_sha256: Digest::SHA256.hexdigest(seed),
          reopen_argv: native_argv(File.join(case_root, 'store')),
          reopen_sql_bytes: reopen.bytesize,
          reopen_sql_sha256: Digest::SHA256.hexdigest(reopen),
          expected_normalized_value_output_sha256: expected_outputs.to_h do |window, lines|
            [window, Digest::SHA256.hexdigest(lines.join("\n") + (lines.empty? ? '' : "\n"))]
          end,
          actual_native_stdout_sha256: 'unobserved_until_authorized_capture',
        }
      end
      plan = {
        format: FORMAT,
        status: 'prepared_only',
        source_pin: {root: @source_root_argument, revision: SOURCE_REVISION},
        runtime_pin: RUNTIME_PIN.merge(binary: @binary_argument),
        evidence_root: @evidence_argument,
        admitted_scope: 'one direct Dynamic Bulk leaf at root/array[0]/tuple[1]; actual arms UInt64 and String SharedVariant; no Dynamic/JSON actual arms; no generic Dynamic discovery claim',
        local_input_sha256: INPUT_SOURCE_PATHS.to_h { |path| [path, sha_file(path)] },
        independent_rows_sha256: Digest::SHA256.hexdigest(JSON.generate(INPUT_ROWS)),
        staged_helper_build: staged_helper_build,
        guarded_stock_invocation: guarded_stock_invocation,
        native_stages: planned_cells,
        exact_native_dynamic_prefix_parser: 'not_implemented',
        raw_native_part_inventory: 'implemented_for_later_capture; not_observed',
        generated_interop: 'not_implemented',
        actual_capture_negative_controls: 'not_implemented',
      }
      puts JSON.pretty_generate(plan)
      true
    end

    def staged_helper_build
      output = BUILD_OUTPUT
      environment = {
        'CRYSTAL_WORKERS' => '1',
        'TMPDIR' => TASK_TMPDIR,
        'CRYSTAL_CACHE_DIR' => TASK_CRYSTAL_CACHE,
        'SDKROOT' => MACOS_SDKROOT,
      }
      argv = [CRYSTAL, 'build', INPUT_SOURCE_PATHS.fetch(1), '--single-module', '--threads', '1',
        "--link-flags=-fuse-ld=#{LINKER}", '--error-trace', '--no-color', '-o', output]
      {
        status: 'staged_command_not_authorized_or_run',
        environment: environment,
        argv: argv,
        argv_sha256: Digest::SHA256.hexdigest(JSON.generate(argv)),
        linker: {path: LINKER, sha256: 'b8763cf250e607a778bb4603cecb5b90338814d0a3dfcba0d57b1de242f610e9'},
        output: output,
      }
    end

    def guarded_stock_invocation
      script = File.expand_path(__FILE__)
      evidence_root = File.join(TASK_ROOT, 'stock-first')
      environment = {
        'COGNI_RUN_SAFE_MIN_FREE_PCT' => '50',
        'RUN_SAFE_PASSTHROUGH_STDIO' => '1',
        'CRYSTAL_WORKERS' => '1',
        'TMPDIR' => TASK_TMPDIR,
        'CRYSTAL_CACHE_DIR' => TASK_CRYSTAL_CACHE,
        'SDKROOT' => MACOS_SDKROOT,
      }
      argv = [RUN_SAFE, '/usr/bin/ruby', '600', '12288', script,
        '--stock-only', '--execute', '--evidence-root', evidence_root]
      report_root = File.join(TASK_ROOT, 'reports')
      command_file = File.join(report_root, 'w284-recursive-dynamic-stock-first.argv')
      stdout_file = File.join(report_root, 'w284-recursive-dynamic-stock-first.stdout')
      stderr_file = File.join(report_root, 'w284-recursive-dynamic-stock-first.stderr')
      command_argv = ['/usr/bin/time', '-l', '/usr/bin/env',
        *environment.map { |key, value| "#{key}=#{value}" }, *argv]
      command_file_contents = Shellwords.join(command_argv) + "\n"
      launcher_argv = ['/usr/bin/ruby', OUTER_LAUNCHER, command_file, stdout_file, stderr_file]
      {
        status: 'prepared_not_run',
        launcher: {
          path: OUTER_LAUNCHER, sha256: OUTER_LAUNCHER_SHA256, bytes: OUTER_LAUNCHER_BYTES,
          argv: launcher_argv, argv_sha256: Digest::SHA256.hexdigest(JSON.generate(launcher_argv)),
          process_spawn: 'direct argv, no shell; command and log files are opened with exclusive creation',
          command_file: command_file, command_file_contents: command_file_contents,
          command_file_bytes: command_file_contents.bytesize,
          command_file_sha256: Digest::SHA256.hexdigest(command_file_contents),
          saved_command_argv: command_argv,
          saved_command_argv_sha256: Digest::SHA256.hexdigest(JSON.generate(command_argv)),
        },
        process_group_policy: {
          clickhouse_child: 'inherits the outer run_safe process group; no new process group is created',
          child_timeout: 'PID-specific TERM then KILL; this alone does not guarantee descendant termination',
          outer_guard: 'unchanged run_safe watchdog owns whole-job process-group cleanup',
        },
        cwd: REPO_ROOT,
        evidence_root_precondition: {
          status: 'absent_at_preparation; must be created empty with mode 0700 after capture authorization',
          argv: ['/bin/mkdir', '-m', '700', evidence_root],
        },
        environment: environment,
        run_safe_sha256: RUN_SAFE_SHA256,
        argv: argv,
        argv_sha256: Digest::SHA256.hexdigest(JSON.generate(argv)),
        invocation_sha256: Digest::SHA256.hexdigest(JSON.generate(
          cwd: REPO_ROOT, environment: environment, argv: command_argv,
          launcher_argv: launcher_argv
        )),
        timeout_seconds: 600,
        memory_limit_mib: 12_288,
        minimum_system_free_percent: 50,
        outer_capture: {
          command_file: command_file,
          stdout: stdout_file,
          stderr: stderr_file,
        },
      }
    end

    def run
      prepare!
      CASES.each do |cell|
        @cells[cell.fetch(:id)] = capture_stock_cell!(cell)
      end
      validate_end_state!
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      puts "W284 stock SQL/value and part-inventory matrix captured; cells=#{@cells.size}; evidence=#{@root}"
      @cells.values.all? { |cell| cell.fetch(:status) == 'stock_sql_values_exact_prefix_unparsed' }
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      persist_inconclusive(error)
      warn "W284 stock-first capture inconclusive (not native format evidence): #{@fatal_error}"
      false
    end

    private

    def prepare!
      raise Error, 'this runner supports only the W284 stock-only preparation boundary' unless
        @stock_only && !@generated
      @root = validate_evidence_root(@evidence_argument)
      @source_root = validate_source_root(@source_root_argument)
      @binary = validate_runtime!
      @source_revision_before = git_revision(@source_root)
      raise Error, 'pinned ClickHouse source checkout revision differs from the separate W284 source pin' unless
        @source_revision_before == SOURCE_REVISION
      @source_hashes_before = source_hashes
      validate_literals!
      @runtime_sha_before = sha_file(@binary)
      raise Error, 'full pinned ClickHouse runtime SHA-256 differs' unless
        @runtime_sha_before == RUNTIME_PIN.fetch(:sha256)
      @runtime_bytes_before = File.size(@binary)
      raise Error, 'full pinned ClickHouse runtime byte size differs' unless
        @runtime_bytes_before == RUNTIME_PIN.fetch(:bytes)
      write_new(File.join(@root, 'input_manifest.json'), JSON.pretty_generate(input_manifest) + "\n")
    end

    def validate_literals!
      raise Error, 'W284 exact recursive declaration changed' unless
        KEY == 'pk' && COLUMN == 'trace' &&
        JSON_TYPE == 'JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8)' &&
        DYNAMIC_TYPE == 'Dynamic(max_types=1)' &&
        TRACE_TYPE == "Array(Tuple(doc #{JSON_TYPE}, sample #{DYNAMIC_TYPE}))"
      raise Error, 'W284 Ruby corpus must retain the eight exact W257-plus-zero-Q/NULL rows' unless
        ROWS_PER_MARK == 2 && ROW_COUNT == 8 && DATA_MARK_COUNT == 4 &&
        INPUT_ROWS.map { |row| row.fetch(:pk) } == (103..110).to_a &&
        INPUT_ROWS.map { |row| row.fetch(:trace).size } == [0, 1, 2, 1, 0, 0, 1, 1] &&
        EXPECTED_SIGNATURES == [
          '103|', '104|14:UInt64:U1040',
          '105|15:String:S6368696c6421;16:NULL:N', '106|17:UInt64:U1060',
          '107|', '108|', '109|18:NULL:N', '110|19:NULL:N',
        ] && EXPECTED_SIGNATURES.uniq.size == ROW_COUNT &&
        EXPECTED_WINDOWS.keys.sort == %w[eof full last middle]
      raise Error, 'W284 matrix must retain all BASIC/COMPACT × MRK3/MRK4 × S0/S1 cells' unless
        MODES == %w[basic compact] && MARK_FORMATS == %w[mrk3 mrk4] && PROFILES == %w[s0 s1] &&
        CASES.size == 8 && CASES.map { |cell| cell.fetch(:id) }.uniq.size == 8
      true
    end

    def validate_evidence_root(path)
      raise Error, 'W284 evidence root is required' unless path.is_a?(String) && !path.empty?
      mount = File.realpath(SSD_ALIAS)
      task_root = File.realpath(TASK_ROOT)
      raise Error, 'W284 task root is not the expected direct child of SSD cache' unless
        File.dirname(task_root) == File.join(mount, 'cache') &&
        File.basename(task_root) == 'crystal-click-w284.9Nzwqc'
      raise Error, 'W284 task root must be on the approved external SSD' if
        File.stat(task_root).dev == File.stat('/').dev
      expanded = File.expand_path(path)
      evidence = File.realpath(expanded)
      stat = File.lstat(expanded)
      raise Error, 'W284 evidence root may not be a symlink' if stat.symlink?
      raise Error, 'W284 evidence root must be a direct child of the task-owned SSD root' unless
        File.dirname(evidence) == task_root
      raise Error, 'W284 evidence root must be a directory owned by the current user' unless
        stat.directory? && stat.uid == Process.uid && stat.dev == File.stat(task_root).dev
      raise Error, 'W284 evidence root must already exist and be empty' unless Dir.children(evidence).empty?
      evidence
    rescue Errno::ENOENT
      raise Error, 'W284 evidence root, task root, or approved SSD mount is missing'
    end

    def validate_source_root(path)
      raise Error, 'pinned W283 source root argument differs' unless File.expand_path(path) == SOURCE_ROOT
      real = File.realpath(path)
      raise Error, 'pinned ClickHouse source root is not a directory' unless File.directory?(real)
      real
    rescue Errno::ENOENT
      raise Error, 'pinned ClickHouse source root is missing'
    end

    def validate_runtime!
      real = File.realpath(@binary_argument)
      raise Error, 'pinned ClickHouse runtime path differs from the fixed full-build path' unless
        File.expand_path(@binary_argument) == BINARY
      stat = File.stat(real)
      raise Error, 'pinned ClickHouse runtime must be executable regular file' unless stat.file? && File.executable?(real)
      real
    rescue Errno::ENOENT
      raise Error, 'pinned full ClickHouse runtime is missing'
    end

    def git_revision(root)
      stdout, stderr, status = Open3.capture3(
        {'GIT_NO_LAZY_FETCH' => '1'},
        'git', '-C', root, 'rev-parse', 'HEAD',
      )
      raise Error, "source git rev-parse failed: #{stderr.strip}" unless status.success? && stderr.empty?
      stdout.strip
    end

    def source_hashes
      INPUT_SOURCE_PATHS.to_h do |path|
        raise Error, "W284 input source is missing or symlinked: #{path}" unless File.file?(path) && !File.symlink?(path)
        [path, sha_file(path)]
      end
    end

    def capture_stock_cell!(cell)
      id = cell.fetch(:id)
      cell_root = File.join(@root, 'cases', id)
      Dir.mkdir(File.join(@root, 'cases'), 0o700) unless Dir.exist?(File.join(@root, 'cases'))
      Dir.mkdir(cell_root, 0o700)
      store = File.join(cell_root, 'store')
      seed_sql = seed_sql(cell, id)
      seed = run_stage!(id, 'seed', store, seed_sql, cell_root)
      validate_pin_output!(id, seed.fetch(:stdout))
      validate_schema_output!(id, seed.fetch(:stdout))
      part = validate_part_output!(id, seed.fetch(:stdout), store)
      validate_check_result!(id, 'seed', seed.fetch(:stdout), part.fetch(:name))
      part_snapshot = inventory_part(part.fetch(:path))

      reopen_sql = reopen_sql(cell, id)
      reopened = run_stage!(id, 'reopen', store, reopen_sql, cell_root)
      validate_pin_output!(id, reopened.fetch(:stdout))
      validate_check_result!(id, 'reopen', reopened.fetch(:stdout), part.fetch(:name))
      windows = validate_windows!(id, reopened.fetch(:stdout))
      part_snapshot_after = inventory_part(part.fetch(:path))
      raise Error, "#{id} stock part bytes changed during reopen/CHECK" unless part_snapshot_after == part_snapshot

      {
        case_id: id, mode: cell.fetch(:mode), mark_format: cell.fetch(:mark),
        string_profile: cell.fetch(:profile), schema: TRACE_TYPE,
        status: 'stock_sql_values_exact_prefix_unparsed',
        data_mark_count_expected: DATA_MARK_COUNT,
        dynamic_occurrences_by_mark: [1, 3, 0, 2],
        dynamic_nonnull_by_mark: [1, 2, 0, 0],
        dynamic_null_by_mark: [0, 1, 0, 2],
        shared_string_by_mark: [0, 1, 0, 0],
        uint64_by_mark: [1, 1, 0, 0],
        structure_candidate: {
          serialization: 'Dynamic V3', ordinary_roster: ['UInt64'],
          canonical_variant_roster: ['SharedVariant', 'UInt64'],
          full_statistics_counts_canonical_order: [1, 2],
          shared_statistics: [{'name' => 'String', 'count' => 1}],
          first_vs_later_mark_statistics_placement: 'unobserved',
        },
        null_vs_shared_variant: 'NULL is distinct; NULL is not a SharedVariant arm',
        part: part.merge(snapshot: part_snapshot),
        windows: windows,
        native_processes: [seed.fetch(:record), reopened.fetch(:record)],
        native_output: {
          seed_stdout_sha256: seed.fetch(:record).fetch(:stdout_sha256),
          reopen_stdout_sha256: reopened.fetch(:record).fetch(:stdout_sha256),
        },
        parser_capture: 'not_implemented: raw prefix byte boundaries/statistics not decoded',
      }
    end

    def seed_sql(cell, id)
      table = table_name(id)
      [
        'SET flatten_nested=0;',
        'SET allow_suspicious_low_cardinality_types=1;',
        'SET use_variant_as_common_type=1;',
        pin_sql,
        "CREATE TABLE default.#{table} (",
        "  #{KEY} UInt64,",
        "  #{COLUMN} #{TRACE_TYPE}",
        ") ENGINE=MergeTree ORDER BY #{KEY} SETTINGS #{table_settings(cell)};",
        "INSERT INTO default.#{table} VALUES #{INPUT_ROWS.map { |row| sql_row(row) }.join(', ')};",
        "SELECT '__W284_SCHEMA__', name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw;",
        "SELECT '__W284_PART__', name, toString(rows), toString(marks), part_type, path FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw;",
        check_sql(table, 'seed'),
      ].join("\n") + "\n"
    end

    def reopen_sql(cell, id)
      table = table_name(id)
      [
        'SET flatten_nested=0;',
        'SET allow_suspicious_low_cardinality_types=1;',
        pin_sql,
        check_sql(table, 'reopen'),
        *WINDOWS.map { |window, predicate| window_sql(table, window, predicate) },
      ].join("\n") + "\n"
    end

    def expected_output_lines
      WINDOWS.to_h do |window, _predicate|
        if window == 'eof'
          [window, ["__W284_EOF__\t0"]]
        else
          marker = "__W284_VALUES_#{window}__"
          lines = EXPECTED_WINDOWS.fetch(window).map do |signature|
            key, value = signature.split('|', 2)
            [marker, key, value].join("\t")
          end
          [window, lines]
        end
      end
    end

    def table_settings(cell)
      string = cell.fetch(:profile) == 's1' ? 'with_size_stream' : 'single_stream'
      mark_stream = cell.fetch(:mark) == 'mrk4' ? 1 : 0
      [
        'index_granularity=2', 'index_granularity_bytes=10485760', 'enable_mixed_granularity_parts=1',
        'min_rows_for_wide_part=1000000', 'min_bytes_for_wide_part=104857600', 'min_level_for_wide_part=0',
        'compress_marks=0', "marks_compression_codec='LZ4'", 'compress_primary_key=0', 'write_final_mark=1',
        "write_marks_for_substreams_in_compact_parts=#{mark_stream}", 'min_compress_block_size=0',
        'max_compress_block_size=4096', 'ratio_of_defaults_for_sparse_serialization=1.0',
        "default_compression_codec='LZ4'", "serialization_info_version='with_types'",
        'propagate_types_serialization_versions_to_nested_types=1', "string_serialization_version='#{string}'",
        "object_serialization_version='v3'", "object_shared_data_serialization_version='map'",
        "object_shared_data_serialization_version_for_zero_level_parts='map'", 'object_shared_data_buckets_for_compact_part=1',
        'object_shared_data_target_chunk_rows=1', "dynamic_serialization_version='v3'",
        "use_compact_variant_discriminators_serialization=#{MODE_VALUES.fetch(cell.fetch(:mode))}",
        'allow_suspicious_low_cardinality_types=1',
      ].join(', ')
    end

    def sql_row(row)
      "(#{row.fetch(:pk)}, #{trace_sql(row.fetch(:trace))})"
    end

    def trace_sql(items)
      return "CAST([], '#{TRACE_TYPE}')" if items.empty?
      tuples = items.map do |item|
        json = JSON.generate({'t' => item.fetch(:tag)})
        "tuple(CAST(#{sql_quote(json)}, '#{JSON_TYPE}'), #{dynamic_sql(item)})"
      end
      "CAST([#{tuples.join(', ')}], '#{TRACE_TYPE}')"
    end

    def dynamic_sql(item)
      case item.fetch(:type)
      when 'NULL'
        "CAST(NULL, '#{DYNAMIC_TYPE}')"
      when 'UInt64'
        "CAST(toUInt64(#{Integer(item.fetch(:value))}), '#{DYNAMIC_TYPE}')"
      when 'String'
        "CAST(#{sql_quote(item.fetch(:value))}, '#{DYNAMIC_TYPE}')"
      else
        raise Error, "unknown W284 Dynamic literal type #{item.fetch(:type).inspect}"
      end
    end

    def sql_quote(value)
      "'#{value.to_s.gsub(/[\\'\0]/) { |character| character == "\0" ? '\\0' : "\\#{character}" }}'"
    end

    def pin_sql
      "SELECT '__W284_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;"
    end

    def check_sql(table, stage)
      [
        "SELECT '__W284_CHECK_BEGIN__#{stage}__' FORMAT TSVRaw;",
        "CHECK TABLE default.#{table} FORMAT TSV;",
        "SELECT '__W284_CHECK_END__#{stage}__' FORMAT TSVRaw;",
      ].join("\n")
    end

    def window_sql(table, window, predicate)
      if window == 'eof'
        return "SELECT '__W284_EOF__', toString(count()) FROM default.#{table} WHERE #{predicate} FORMAT TSVRaw;"
      end
      where = predicate ? " WHERE #{predicate}" : ''
      "SELECT '__W284_VALUES_#{window}__', toString(#{KEY}), #{trace_signature_sql} " \
        "FROM default.#{table}#{where} ORDER BY #{KEY} FORMAT TSVRaw;"
    end

    def trace_signature_sql
      value = 'w284_item.2'
      dynamic_value = "if(isNull(#{value}), 'N', if(dynamicType(#{value}) = 'UInt64', " \
        "concat('U', toString(dynamicElement(#{value}, 'UInt64'))), " \
        "if(dynamicType(#{value}) = 'String', concat('S', lower(hex(dynamicElement(#{value}, 'String')))), " \
        "concat('OTHER:', dynamicType(#{value})))) )"
      item_signature = "concat(toString(toUInt8(w284_item.1.t)), ':', " \
        "if(isNull(w284_item.2), 'NULL', dynamicType(w284_item.2)), ':', #{dynamic_value})"
      "arrayStringConcat(arrayMap(w284_item -> #{item_signature}, #{COLUMN}), ';')"
    end

    def validate_pin_output!(id, stdout)
      rows = stdout.lines(chomp: true).select { |line| line.start_with?("__W284_PIN__\t") }
      expected = "__W284_PIN__\t#{RUNTIME_PIN.fetch(:version)}\t#{RUNTIME_PIN.fetch(:build)}"
      raise Error, "#{id} native runtime version/build output differs" unless rows == [expected]
    end

    def validate_schema_output!(id, stdout)
      rows = stdout.lines(chomp: true).select { |line| line.start_with?("__W284_SCHEMA__\t") }
      expected = [
        "__W284_SCHEMA__\t#{KEY}\tUInt64",
        "__W284_SCHEMA__\t#{COLUMN}\t#{TRACE_TYPE}",
      ]
      unless rows.map { |line| line.split("\t", -1) }.map { |row| row.map { |field| field.gsub(/\s+/, ' ').strip } } ==
             expected.map { |line| line.split("\t", -1) }.map { |row| row.map { |field| field.gsub(/\s+/, ' ').strip } }
        raise Error, "#{id} native schema output differs from the exact W257 declaration"
      end
    end

    def validate_part_output!(id, stdout, store)
      rows = stdout.lines(chomp: true).select { |line| line.start_with?("__W284_PART__\t") }
      raise Error, "#{id} does not expose exactly one active native part" unless rows.size == 1
      fields = rows.first.split("\t", -1)
      raise Error, "#{id} native part row has an unexpected field count" unless fields.size == 6
      _tag, name, row_text, marks_text, part_type, raw_path = fields
      raise Error, "#{id} native part is not Compact or does not contain eight rows" unless
        name == EXPECTED_PART_NAME && row_text == ROW_COUNT.to_s && part_type == 'Compact'
      marks = Integer(marks_text)
      raise Error, "#{id} native system.parts marks count is implausible" unless marks.between?(DATA_MARK_COUNT, DATA_MARK_COUNT + 1)
      store_path = File.realpath(store)
      path = validate_part_path!(id, name, raw_path, store_path)
      path = File.realpath(path)
      unless path != store_path && path.start_with?("#{store_path}#{File::SEPARATOR}") &&
          File.basename(path) == name
        raise Error, "#{id} native part path escaped its W284-owned case store"
      end
      raise Error, "#{id} native part path is not a directory" unless File.directory?(path)
      {name: name, rows: Integer(row_text), system_marks: marks, part_type: part_type, path: path}
    rescue ArgumentError, Errno::ENOENT => error
      raise Error, "#{id} native part metadata is malformed: #{error.message}"
    end

    def validate_part_path!(id, name, raw_path, store)
      raise Error, "#{id} native part name differs from the exact unpartitioned part" unless
        name == EXPECTED_PART_NAME
      raise Error, "#{id} native part path is missing" unless raw_path.is_a?(String) && !raw_path.empty?
      store_path = File.expand_path(store)
      path = File.expand_path(raw_path, store_path)
      unless path != store_path && path.start_with?("#{store_path}#{File::SEPARATOR}") &&
          File.basename(path) == name
        raise Error, "#{id} native part path is not the named part strictly below its W284-owned case store"
      end
      path
    end

    def validate_check_result!(id, stage, stdout, part_name)
      begin_marker = "__W284_CHECK_BEGIN__#{stage}__"
      end_marker = "__W284_CHECK_END__#{stage}__"
      text = stdout.dup.force_encoding(Encoding::UTF_8)
      raise Error, "#{id}/#{stage} stdout is not valid UTF-8" unless text.valid_encoding?
      raise Error, "#{id}/#{stage} stdout is not newline terminated" unless text.empty? || text.end_with?("\n")
      lines = text.lines(chomp: true)
      begin_positions = lines.each_index.select { |index| lines[index] == begin_marker }
      end_positions = lines.each_index.select { |index| lines[index] == end_marker }
      raise Error, "#{id}/#{stage} CHECK TABLE markers are missing, duplicated, or malformed" unless
        begin_positions.size == 1 && end_positions.size == 1
      begin_index = begin_positions.first
      end_index = end_positions.first
      raise Error, "#{id}/#{stage} CHECK TABLE markers are out of order" unless begin_index < end_index
      expected = ["#{part_name}\t1\t"]
      rows = lines[(begin_index + 1)...end_index]
      raise Error, "#{id}/#{stage} CHECK TABLE result differs from exact healthy row" unless rows == expected
      true
    end

    def validate_windows!(id, stdout)
      result = {}
      WINDOWS.each do |window, _predicate|
        marker = window == 'eof' ? '__W284_EOF__' : "__W284_VALUES_#{window}__"
        rows = stdout.lines(chomp: true).select { |line| line.start_with?("#{marker}\t") }
        expected = EXPECTED_WINDOWS.fetch(window)
        if window == 'eof'
          raise Error, "#{id}/EOF native count differs" unless rows == [[marker, '0'].join("\t")]
          result[window] = {signatures: [], expected_signatures: [], native_count: 0}
          next
        end
        actual = rows.map do |line|
          fields = line.split("\t", -1)
          raise Error, "#{id}/#{window} native value row is malformed" unless fields.size == 3 && fields[0] == marker
          "#{Integer(fields[1])}|#{fields[2]}"
        end
        raise Error, "#{id}/#{window} native values differ from independent Ruby literals" unless actual == expected
        result[window] = {signatures: actual, expected_signatures: expected, native_count: actual.size}
      end
      result
    end

    def run_stage!(id, stage, store, sql, cell_root)
      stage_root = File.join(cell_root, stage)
      Dir.mkdir(stage_root, 0o700)
      sql_path = File.join(stage_root, 'input.sql')
      write_new(sql_path, sql)
      argv = native_argv(store)
      record = run_process!("#{id}_#{stage}", argv, sql, sql_path, stage_root)
      raise Error, "#{id}/#{stage} ClickHouse process failed: exit=#{record[:exitstatus].inspect}, signal=#{record[:termsig].inspect}" unless
        record.fetch(:exitstatus) == 0 && record.fetch(:termsig).nil? && !record.fetch(:timed_out)
      unless !record.fetch(:stdout_truncated) && !record.fetch(:stderr_truncated) &&
          record.fetch(:stdout_read_error).nil? && record.fetch(:stderr_read_error).nil? &&
          record.fetch(:stdin_write_error).nil?
        raise Error, "#{id}/#{stage} bounded stream capture was truncated or failed"
      end
      {stdout: File.binread(File.join(stage_root, 'stdout.bin')), record: record}
    end

    def native_argv(store)
      [@binary || @binary_argument, 'local', '--path', store, '--session_timezone=UTC', '--max_threads=1',
       '--max_memory_usage=536870912', '--multiquery']
    end

    def run_process!(label, argv, input, sql_path, stage_root)
      stdout_capture = nil
      stderr_capture = nil
      stdin_write_error = nil
      timed_out = false
      status = nil
      Open3.popen3(*argv) do |stdin, stdout, stderr, waiter|
        stdin.binmode
        stdout.binmode
        stderr.binmode
        stdout_reader = Thread.new { read_bounded_stream(stdout) }
        stderr_reader = Thread.new { read_bounded_stream(stderr) }
        stdin_writer = Thread.new do
          write_error = nil
          begin
            stdin.write(input)
          rescue IOError, SystemCallError => error
            write_error = "#{error.class}: #{error.message}"
          ensure
            begin
              stdin.close unless stdin.closed?
            rescue IOError, SystemCallError => error
              write_error ||= "#{error.class}: #{error.message}"
            end
          end
          write_error
        end
        unless waiter.join(PROCESS_TIMEOUT_SECONDS)
          timed_out = true
          stop_process(waiter.pid, 'TERM')
          unless waiter.join(5)
            stop_process(waiter.pid, 'KILL')
            waiter.join(5)
          end
        end
        status = waiter.value
        stdin_write_error = stdin_writer.value
        stdout_capture = stdout_reader.value
        stderr_capture = stderr_reader.value
      end
      raise Error, "#{label} process produced no stdout capture result" unless stdout_capture
      raise Error, "#{label} process produced no stderr capture result" unless stderr_capture
      write_new(File.join(stage_root, 'stdout.bin'), stdout_capture.fetch(:bytes))
      write_new(File.join(stage_root, 'stderr.bin'), stderr_capture.fetch(:bytes))
      record = {
        label: label, argv: argv, input_sql: sql_path, input_sql_sha256: sha_file(sql_path),
        timed_out: timed_out, exitstatus: status&.exitstatus, termsig: status&.termsig,
        stdin_write_error: stdin_write_error,
        stdout_bytes: stdout_capture.fetch(:bytes).bytesize,
        stdout_observed_bytes: stdout_capture.fetch(:observed_bytes),
        stdout_truncated: stdout_capture.fetch(:truncated),
        stdout_read_error: stdout_capture.fetch(:error),
        stdout_sha256: Digest::SHA256.hexdigest(stdout_capture.fetch(:bytes)),
        stderr_bytes: stderr_capture.fetch(:bytes).bytesize,
        stderr_observed_bytes: stderr_capture.fetch(:observed_bytes),
        stderr_truncated: stderr_capture.fetch(:truncated),
        stderr_read_error: stderr_capture.fetch(:error),
        stderr_sha256: Digest::SHA256.hexdigest(stderr_capture.fetch(:bytes)),
      }
      write_new(File.join(stage_root, 'invocation.json'), JSON.pretty_generate(record) + "\n")
      @processes << record
      record
    rescue IOError, SystemCallError => error
      raise Error, "#{label} native invocation failed: #{error.class}: #{error.message}"
    end

    def read_bounded_stream(stream, limit = MAX_PART_BYTES)
      raise ArgumentError, 'stream capture limit must be nonnegative' if limit.negative?
      captured = ''.b
      observed = 0
      truncated = false
      loop do
        chunk = stream.readpartial(STREAM_CHUNK_BYTES)
        observed += chunk.bytesize
        remaining = limit - captured.bytesize
        captured << chunk.byteslice(0, remaining) if remaining.positive?
        truncated ||= chunk.bytesize > remaining
      end
    rescue EOFError
      {bytes: captured, observed_bytes: observed, truncated: truncated, error: nil}
    rescue IOError, SystemCallError => error
      {bytes: captured, observed_bytes: observed, truncated: truncated,
       error: "#{error.class}: #{error.message}"}
    end

    def stop_process(pid, signal)
      Process.kill(signal, pid)
    rescue Errno::ESRCH
      nil
    end

    def inventory_part(path)
      files = []
      total = 0
      Find.find(path) do |entry|
        stat = File.lstat(entry)
        raise Error, "native part inventory contains a symlink: #{entry}" if stat.symlink?
        next if stat.directory?
        raise Error, "native part inventory contains a non-file: #{entry}" unless stat.file?
        total += stat.size
        raise Error, 'native part inventory exceeds the byte cap' if total > MAX_PART_BYTES
        files << {
          relative_path: entry.delete_prefix("#{path}#{File::SEPARATOR}"),
          bytes: stat.size, sha256: sha_file(entry),
        }
        raise Error, 'native part inventory exceeds the file-count cap' if files.size > MAX_PART_FILES
      end
      {files: files.sort_by { |file| file.fetch(:relative_path) }, total_bytes: total,
       file_count: files.size, sha256: Digest::SHA256.hexdigest(files.sort_by { |file| file.fetch(:relative_path) }.map { |file| "#{file[:relative_path]}\0#{file[:bytes]}\0#{file[:sha256]}\n" }.join)}
    end

    def validate_end_state!
      @source_revision_after = git_revision(@source_root)
      raise Error, 'pinned ClickHouse source revision changed during capture' unless
        @source_revision_after == @source_revision_before
      @source_hashes_after = source_hashes
      raise Error, 'W284 local input source bytes changed during native capture' unless
        @source_hashes_after == @source_hashes_before
      @runtime_sha_after = sha_file(@binary)
      @runtime_bytes_after = File.size(@binary)
      raise Error, 'pinned ClickHouse runtime bytes changed during capture' unless
        @runtime_sha_after == @runtime_sha_before && @runtime_bytes_after == @runtime_bytes_before
      raise Error, 'W284 stock matrix is incomplete' unless
        @cells.size == CASES.size && @cells.keys.sort == CASES.map { |cell| cell.fetch(:id) }.sort
      true
    end

    def input_manifest
      {
        format: 'compact_recursive_dynamic_w284_inputs_v1',
        source_pin: {root: @source_root, revision: @source_revision_before},
        runtime_pin: RUNTIME_PIN.merge(binary: @binary, sha256_before: @runtime_sha_before,
          bytes_before: @runtime_bytes_before),
        local_source_sha256: @source_hashes_before,
        independent_ruby_input_rows: INPUT_ROWS,
        independent_expected_signatures: EXPECTED_SIGNATURES,
        dynamic_occurrence_q_by_mark: [1, 3, 0, 2],
        dynamic_nonnull_by_mark: [1, 2, 0, 0],
        null_occurrences_by_mark: [0, 1, 0, 2],
        actual_arm_q_by_mark: {shared_string: [0, 1, 0, 0], uint64: [1, 1, 0, 0]},
        admitted_dynamic_scope: 'one direct Dynamic Bulk leaf at root/array[0]/tuple[1]; actual arms UInt64 and String SharedVariant; no Dynamic/JSON actual arms; no generic Dynamic discovery claim',
        candidate_dynamic_v3_structure: {
          ordinary_roster: ['UInt64'], canonical_variants: ['SharedVariant', 'UInt64'],
          full_statistics_counts: [1, 2], shared_statistics: [{'name' => 'String', 'count' => 1}],
        },
        capture_boundary: 'stock SQL values and immutable raw-part inventory; DynamicStructure prefix boundaries/statistics are not parsed',
      }
    end

    def summary
      {
        format: FORMAT,
        status: @cells.values.all? { |cell| cell.fetch(:status) == 'stock_sql_values_exact_prefix_unparsed' } ?
          'stock_sql_values_and_raw_part_inventory_exact_prefix_unparsed' : 'inconclusive',
        claim_boundary: 'Exact native SQL schema/values, CHECK/reopen, and immutable part inventory only; not Compact Dynamic prefix parse/interop qualification.',
        source_pin: {root: @source_root, revision_expected: SOURCE_REVISION,
          revision_before: @source_revision_before, revision_after: @source_revision_after},
        runtime_pin: RUNTIME_PIN.merge(binary: @binary, sha256_before: @runtime_sha_before,
          sha256_after: @runtime_sha_after, bytes_before: @runtime_bytes_before, bytes_after: @runtime_bytes_after),
        local_source_sha256_before: @source_hashes_before,
        local_source_sha256_after: @source_hashes_after,
        cells: @cells,
        invocations: @processes,
        dynamic_prefix_capture: 'not_implemented',
        generated_interop: 'not_implemented',
        actual_capture_negative_controls: 'not_implemented',
        first_vs_later_compact_mark_statistics: 'empirical discriminator; unobserved',
      }
    end

    def persist_inconclusive(error)
      return unless @root && File.directory?(@root)
      path = File.join(@root, 'inconclusive.json')
      return if File.exist?(path)
      details = {
        format: FORMAT, status: 'inconclusive',
        error: "#{error.class}: #{error.message}",
        cells_completed: @cells.keys.sort,
        invocations: @processes,
        runtime_sha256_after: (sha_file(@binary) rescue nil),
        source_revision_after: (git_revision(@source_root) rescue nil),
      }
      write_new(path, JSON.pretty_generate(details) + "\n")
    rescue StandardError
      nil
    end

    def table_name(id)
      "w284_#{id}"
    end

    def sha_file(path)
      Digest::SHA256.file(path).hexdigest
    end

    def write_new(path, bytes)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(bytes) }
    end

    public

    def stock_only!
      @stock_only = true
      @generated = false
    end
  end

  def self.run(argv = ARGV)
    options = {
      stock_only: false,
      execute: false,
      evidence_root: File.join(TASK_ROOT, 'stock-first'),
      source_root: SOURCE_ROOT,
      binary: BINARY,
    }
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: ruby scripts/verify_compact_recursive_dynamic_w284.rb --stock-only [--execute] [--evidence-root PATH]'
      opts.on('--stock-only', 'select the W284 stock-only discriminator') { options[:stock_only] = true }
      opts.on('--execute', 'run pinned ClickHouse stock captures; omission prints a plan only') { options[:execute] = true }
      opts.on('--evidence-root PATH', 'existing empty direct child under the W284 SSD task root') { |v| options[:evidence_root] = v }
      opts.on('--source-root PATH', 'pinned ClickHouse source checkout (W283 source revision)') { |v| options[:source_root] = v }
      opts.on('--binary PATH', 'pinned full ClickHouse runtime; must equal the fixed path') { |v| options[:binary] = v }
    end
    parser.parse!(argv)
    raise Error, 'unexpected positional arguments' unless argv.empty?
    raise Error, '--stock-only is required' unless options.fetch(:stock_only)

    runner = Runner.new(options)
    runner.stock_only!
    return runner.print_plan unless options.fetch(:execute)
    runner.run
  rescue OptionParser::ParseError, Error => error
    warn "W284 runner rejected request: #{error.class}: #{error.message}"
    false
  end

  exit(run ? 0 : 1) if $PROGRAM_NAME == __FILE__
end
