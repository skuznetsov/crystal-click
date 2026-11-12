#!/usr/bin/env ruby
# Bounded W286 stock-source -> Compact callback transform -> native attach witness.
# This consumes only supplied prebuilt executables; it never builds either.

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require_relative 'verify_materialized_view_transform_w257'
require_relative 'verify_compact_recursive_dynamic_w284'

module VerifyMaterializedViewCompactTransformW286
  W257 = VerifyMaterializedViewTransformW257
  W284 = VerifyCompactRecursiveDynamicW284
  FORMAT = 'materialized_view_compact_transform_w286_native_v1'.freeze
  TASK_CACHE = '/opt/mldata_ssd/cache'.freeze
  TASK_DIR_PREFIX = 'crystal-click-w286.'.freeze
  BINARY = W284::BINARY
  RUNTIME_PIN = W284::RUNTIME_PIN
  VERSION = W284::RUNTIME_PIN.fetch(:version)
  BUILD = W284::RUNTIME_PIN.fetch(:build)
  DATABASE_UUID = 'f2860000-7b7f-4e2f-9e44-dc13a87b8801'.freeze
  SOURCE_UUID = 'f2860000-7b7f-4e2f-9e44-dc13a87b8802'.freeze
  TARGET_UUID = 'f2860000-7b7f-4e2f-9e44-dc13a87b8803'.freeze
  VIEW_UUID = 'f2860000-7b7f-4e2f-9e44-dc13a87b8804'.freeze
  SOURCE_PART = 'all_1_1_0'.freeze
  ATTACHED_PART = 'all_1_1_0'.freeze
  SIDE_CAR = 'invalidated_system_columns.txt'.freeze
  SIDE_CAR_BYTES = "_block_offset\n_block_number\n".b.freeze
  SIDE_CAR_SHA256 = '7409424ab45090c1261e622f7423393905102e7e8cba36a6db88eb513ce1e06c'.freeze
  NATIVE_TARGETS = [
    {id: 'mrk3_s0', mark: 'mrk3', profile: 's0', part: 'all_9_9_0'},
    {id: 'mrk3_s1', mark: 'mrk3', profile: 's1', part: 'all_10_10_0'},
    {id: 'mrk4_s0', mark: 'mrk4', profile: 's0', part: 'all_11_11_0'},
    {id: 'mrk4_s1', mark: 'mrk4', profile: 's1', part: 'all_12_12_0'},
  ].map(&:freeze).freeze
  SOURCE_COLUMNS = W257::COLUMNS.map(&:first).freeze
  TARGET_SETTINGS = W257::TARGET_SETTINGS
  SOURCE_SETTINGS = W257::SOURCE_SETTINGS
  COLUMN_DDL = W257::COLUMNS.map { |name, type| "`#{name}` #{type}" }.join(', ').freeze
  PROFILE_NAMES = {'s0' => 'single_stream', 's1' => 'with_size_stream'}.freeze
  OUTPUT_TYPES = W257::COLUMNS.freeze
  EXPECTED_TARGET_ROWS = W257::EXPECTED_TARGET_ROWS
  EXPECTED_SOURCE_ROWS = W257::SOURCE_ROWS
  W257_PROBE = W257::Probe.allocate
  SCRIPT_INPUTS = %w[
    scripts/verify_materialized_view_compact_transform_w286.rb
    scripts/check_materialized_view_compact_transform_w286.cr
    scripts/support/materialized_view_compact_transform_w286_fixture.cr
    scripts/verify_materialized_view_transform_w257.rb
    scripts/support/materialized_view_transform_w257_fixture.cr
    scripts/verify_compact_recursive_dynamic_w284.rb
  ].freeze
  SOURCE_INPUTS = %w[
    src/crystal_click.cr
    src/crystal_click/compact_part_transform_output.cr
    src/crystal_click/compact_part_writer.cr
    src/crystal_click/compact_part_writer/compact_part_operation.cr
    src/crystal_click/compact_static_callback_plan.cr
    src/crystal_click/offline_catalog.cr
    src/crystal_click/offline_materialized_view_part_transform.cr
    src/crystal_click/part_schema_binding.cr
    src/crystal_click/wide_part_transform_output.cr
    src/crystal_click/wide_part_writer/wide_part_schema_binding.cr
  ].freeze

  class Error < StandardError; end

  class Driver
    def initialize(options)
      @options = options
      @evidence_argument = options.fetch(:evidence_root)
      @binary_argument = options.fetch(:binary)
      @helper_argument = options.fetch(:helper)
      @helper_mode = options.fetch(:helper_mode)
      @cells = {}
      @native_paths = {}
      @native_parts = {}
      @generated_parts = {}
      @fatal_error = nil
      @root = nil
      @native_store = nil
      @catalog_root = nil
      @source_part_path = nil
      @source_inventory = nil
      @runtime_sha_before = nil
      @runtime_sha_after = nil
      @helper_sha_before = nil
      @helper_sha_after = nil
      @input_hashes_before = nil
      @input_hashes_after = nil
      @source_revision = nil
      @auditor_negative = nil
    end

    def run
      prepare!
      initial = run_native('stock_source_and_empty_targets', initial_sql)
      initial_state = parse_markers(initial.fetch(:stdout))
      assert_initial!(initial_state)

      source_rowbinary = run_native('stock_source_rowbinary', rowbinary_sql('source'))
      W257.validate_rowbinary!(source_rowbinary.fetch(:stdout), EXPECTED_SOURCE_ROWS)
      @source_rowbinary_before = source_rowbinary.fetch(:stdout)

      prepare_offline_catalog!
      NATIVE_TARGETS.each { |cell| @cells[cell.fetch(:id)] = run_publish_cell!(cell) }
      run_refusal_probe!
      copy_all_to_detached!

      attached = run_native('attach_check_and_inventory', attach_sql)
      attached_state = parse_markers(attached.fetch(:stdout))
      assert_consumed_targets!(attached_state, 'attach')
      NATIVE_TARGETS.each { |cell| @cells.fetch(cell.fetch(:id))[:attach_read] = read_target!(cell, 'attach') }
      run_auditor_negative_control!(NATIVE_TARGETS.last)

      reopened = run_native('fresh_process_reopen_check', reopen_sql)
      reopened_state = parse_markers(reopened.fetch(:stdout))
      assert_consumed_targets!(reopened_state, 'reopen')
      NATIVE_TARGETS.each { |cell| @cells.fetch(cell.fetch(:id))[:reopen_read] = read_target!(cell, 'reopen') }

      source_after = run_native('source_rows_after_reopen', rowbinary_sql('source'))
      W257.validate_rowbinary!(source_after.fetch(:stdout), EXPECTED_SOURCE_ROWS)
      fail!('source RowBinary bytes changed during transform/attach/reopen') unless
        source_after.fetch(:stdout) == @source_rowbinary_before

      validate_end_state!
      write_summary(
        status: 'all_four_mrk3_mrk4_string_profile_lanes_observed',
        initial_native: initial_state,
        attached_native: attached_state,
        reopened_native: reopened_state,
        source_rowbinary: {
          count: EXPECTED_SOURCE_ROWS.size,
          initial_sha256: Digest::SHA256.hexdigest(@source_rowbinary_before),
          after_reopen_sha256: Digest::SHA256.hexdigest(source_after.fetch(:stdout)),
          literals_exact: true,
          bytes_unchanged: true,
        },
        native_data_paths: @native_paths,
        source_part: {path: @source_part_path, inventory: @source_inventory},
        generated_parts: @generated_parts,
        cells: @cells,
        expected_refusal: @refusal_result,
        auditor_negative_control: @auditor_negative,
      )
      puts "W286 Compact callback + native ATTACH/CHECK/RowBinary/reopen observed; helper_mode=#{@helper_mode}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      @runtime_sha_after = sha_file(@binary_argument) rescue nil
      @helper_sha_after = sha_file(@helper_argument) rescue nil
      @input_hashes_after = input_hashes rescue nil
      write_summary(status: 'runner_failure_or_observations_differ', fatal_error: @fatal_error) rescue nil
      warn "W286 probe failure (process failure is not native format evidence): #{@fatal_error}"
      false
    end

    private

    def prepare!
      @root = validate_evidence_root(@evidence_argument)
      validate_marker_parser!
      @binary = validate_runtime!(@binary_argument)
      @helper = validate_helper!(@helper_argument)
      @runtime_sha_before = sha_file(@binary)
      @helper_sha_before = sha_file(@helper)
      @input_hashes_before = input_hashes
      @source_revision = git_revision
      %w[native catalog generated invocations mutants tmp].each do |name|
        Dir.mkdir(File.join(@root, name), 0o700)
      end
      ENV['TMPDIR'] = File.join(@root, 'tmp')
      ENV['TMP'] = ENV['TMPDIR']
      ENV['TEMP'] = ENV['TMPDIR']
      @native_store = File.join(@root, 'native', 'store')
      @catalog_root = File.join(@root, 'catalog', 'offline_catalog')
      @native_runner = W284::Runner.new(
        evidence_root: @root,
        source_root: W284::SOURCE_ROOT,
        binary: @binary,
      )
      @native_runner.instance_variable_set(:@binary, @binary)
      @native_runner.instance_variable_set(:@processes, [])
      write_new(File.join(@root, 'input_manifest.json'), JSON.pretty_generate(input_manifest) + "\n")
    end

    def validate_evidence_root(path)
      fail!('evidence root is required') unless path && !path.empty?
      cache_root = File.realpath(TASK_CACHE)
      expanded = File.expand_path(path)
      resolved = File.realpath(expanded)
      stat = File.lstat(expanded)
      task_root = File.dirname(resolved)
      task_stat = File.lstat(task_root)
      fail!('evidence task root must be a unique direct-child mktemp directory under canonical /opt/mldata_ssd/cache') unless
        File.dirname(task_root) == cache_root && File.basename(task_root).match?(/\A#{Regexp.escape(TASK_DIR_PREFIX)}[A-Za-z0-9_-]+\z/)
      fail!('evidence task root must be owned by this user and not be a symlink') unless
        task_stat.directory? && !task_stat.symlink? && task_stat.uid == Process.uid
      fail!('evidence root must be a direct child of its task root, owned by this user, and not be a symlink') unless
        File.dirname(resolved) == task_root && stat.directory? && !stat.symlink? && stat.uid == Process.uid
      fail!('evidence root must live on the canonical SSD cache filesystem') unless
        stat.dev == File.stat(task_root).dev && task_stat.dev == File.stat(cache_root).dev && stat.dev != File.stat('/').dev
      fail!('evidence root must already be empty') unless Dir.children(resolved).empty?
      resolved
    rescue Errno::ENOENT
      fail!('the canonical /opt/mldata_ssd/cache, allocated W286 task directory, or empty evidence child is missing')
    end

    def validate_runtime!(path)
      fail!('ClickHouse path differs from the W283-pinned runtime') unless File.expand_path(path) == BINARY
      fail!('ClickHouse runtime is absent, non-executable, or symlinked') unless
        File.file?(path) && File.executable?(path) && !File.symlink?(path)
      fail!('ClickHouse runtime size differs from the pinned artifact') unless File.size(path) == RUNTIME_PIN.fetch(:bytes)
      fail!('ClickHouse runtime SHA-256 differs from the pinned artifact') unless sha_file(path) == RUNTIME_PIN.fetch(:sha256)
      path
    end

    def validate_helper!(path)
      fail!('prebuilt Crystal helper path is required') unless path && !path.empty?
      full = File.expand_path(path)
      fail!('prebuilt Crystal helper is absent, non-executable, or symlinked') unless
        File.file?(full) && File.executable?(full) && !File.symlink?(full)
      full
    end

    def initial_sql
      target_tables = NATIVE_TARGETS.map { |cell| native_table_name(cell) }
      tables = ['source', 'target'] + target_tables
      statements = [
        'SET flatten_nested=0;',
        'SET allow_suspicious_low_cardinality_types=1;',
        'SET use_variant_as_common_type=1;',
        pin_sql,
        "CREATE DATABASE lab UUID '#{DATABASE_UUID}' ENGINE=Atomic;",
        table_ddl('source', SOURCE_UUID, SOURCE_SETTINGS),
        table_ddl('target', TARGET_UUID, TARGET_SETTINGS),
      ]
      target_tables.each do |name|
        statements << "CREATE TABLE lab.#{name} (#{COLUMN_DDL}) ENGINE=MergeTree ORDER BY pk SETTINGS #{TARGET_SETTINGS};"
      end
      source_values = EXPECTED_SOURCE_ROWS.map { |row| W257_PROBE.send(:source_sql_row, row) }.join(', ')
      statements << "INSERT INTO lab.source VALUES #{source_values};"
      statements << "CREATE MATERIALIZED VIEW lab.view UUID '#{VIEW_UUID}' TO lab.target (#{COLUMN_DDL}) AS SELECT pk, score, payload, doc, trace FROM lab.source WHERE pk >= 3;"
      statements << check_sql('source')
      statements << schema_sql(tables)
      statements << data_paths_sql(tables)
      statements << parts_sql(tables)
      statements.concat(tables.map { |table| row_count_sql(table) })
      statements.join("\n") + "\n"
    end

    def table_ddl(name, uuid, settings)
      W257_PROBE.send(:table_ddl, name, uuid, settings)
    end

    def column_ddl
      COLUMN_DDL
    end

    def pin_sql
      "SELECT '__W286_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;"
    end

    def schema_sql(tables)
      names = tables.map { |name| "'#{name}'" }.join(',')
      "SELECT '__W286_SCHEMA__', table, name, type FROM system.columns WHERE database='lab' AND table IN (#{names}) ORDER BY table,position FORMAT TSVRaw;"
    end

    def data_paths_sql(tables)
      names = tables.map { |name| "'#{name}'" }.join(',')
      "SELECT '__W286_DATA_PATH__', name, arrayElement(data_paths,1) FROM system.tables WHERE database='lab' AND name IN (#{names}) ORDER BY name FORMAT TSVRaw;"
    end

    def parts_sql(tables)
      names = tables.map { |name| "'#{name}'" }.join(',')
      "SELECT '__W286_PART__', table, name, toString(rows), toString(marks), part_type, path FROM system.parts WHERE database='lab' AND table IN (#{names}) AND active ORDER BY table,name FORMAT TSVRaw;"
    end

    def row_count_sql(table)
      "SELECT '__W286_ROWCOUNT__', '#{table}', toString(count()) FROM lab.#{table} FORMAT TSVRaw;"
    end

    def check_sql(table)
      [
        "SELECT '__W286_CHECK_BEGIN__', '#{table}' FORMAT TSVRaw;",
        "CHECK TABLE lab.#{table} FORMAT TSV;",
        "SELECT '__W286_CHECK_END__', '#{table}' FORMAT TSVRaw;",
      ].join("\n")
    end

    def rowbinary_sql(table)
      W257_PROBE.send(:rowbinary_select, table)
    end

    def parse_markers(stdout)
      lines = stdout.dup.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
      known = %w[
        __W286_PIN__ __W286_SCHEMA__ __W286_DATA_PATH__ __W286_PART__ __W286_ROWCOUNT__
        __W286_CHECK_BEGIN__ __W286_CHECK_END__
      ]
      unknown = lines.select { |line| line.start_with?('__W286_') }.map { |line| line.split("\t", 2).first }.uniq - known
      fail!("unknown native marker tags: #{unknown.inspect}") unless unknown.empty?
      pins = lines.select { |line| line.start_with?("__W286_PIN__\t") }
      schemas = marker_rows(lines, '__W286_SCHEMA__', 4).map { |row| row.drop(1) }
      path_rows = marker_rows(lines, '__W286_DATA_PATH__', 3)
      fail!('duplicate native data path marker') unless path_rows.map { |row| row.fetch(1) }.uniq.size == path_rows.size
      paths = path_rows.to_h do |row|
        fail!('duplicate native data path row') if row.size != 3
        [row.fetch(1), row.fetch(2)]
      end
      parts = marker_rows(lines, '__W286_PART__', 7).group_by { |row| row.fetch(1) }.transform_values do |rows|
        rows.map do |row|
          fail!('native active part marker width differs') unless row.size == 7
          {name: row.fetch(2), rows: row.fetch(3), marks: row.fetch(4), type: row.fetch(5), path: row.fetch(6)}
        end
      end
      count_rows = marker_rows(lines, '__W286_ROWCOUNT__', 3)
      fail!('duplicate native row-count marker') unless count_rows.map { |row| row.fetch(1) }.uniq.size == count_rows.size
      row_counts = count_rows.to_h do |row|
        fail!('native row-count marker width differs') unless row.size == 3
        [row.fetch(1), row.fetch(2)]
      end
      checks = parse_checks(lines)
      fail!('runtime pin must occur exactly once') unless pins.size == 1 && pins.first.split("\t", -1).size == 3
      {
        pin: pins.first,
        schemas: schemas,
        data_paths: paths,
        parts: parts,
        row_counts: row_counts,
        checks: checks,
      }
    end

    def marker_rows(lines, marker, width)
      lines.select { |line| line.start_with?("#{marker}\t") }.map do |line|
        fields = line.split("\t", -1)
        fail!("#{marker} row width differs") unless fields.size == width
        fields
      end
    end

    def parse_checks(lines)
      checks = {}
      active = nil
      lines.each do |line|
        if line.start_with?("__W286_CHECK_BEGIN__\t")
          fields = line.split("\t", -1)
          fail!('malformed, nested, or duplicate CHECK start') unless
            fields.size == 2 && active.nil? && !checks.key?(fields[1])
          active = fields[1]
          checks[active] = []
        elsif line.start_with?("__W286_CHECK_END__\t")
          fields = line.split("\t", -1)
          fail!('malformed or mismatched CHECK end') unless fields.size == 2 && active == fields[1]
          active = nil
        elsif active
          checks.fetch(active) << line
        end
      end
      fail!('unterminated CHECK capture') unless active.nil?
      checks
    end

    def validate_marker_parser!
      lines = [
        "__W286_PIN__\t#{VERSION}\t#{BUILD}",
        "__W286_CHECK_BEGIN__\tsource",
        "#{SOURCE_PART}\t1\t",
        "__W286_CHECK_END__\tsource",
      ]
      parsed = parse_markers(lines.join("\n") + "\n")
      fail!('synthetic native CHECK marker self-test failed') unless
        parsed.fetch(:checks) == {'source' => ["#{SOURCE_PART}\t1\t"]}
      true
    end

    def assert_initial!(native)
      assert_pin!(native)
      tables = (['source', 'target'] + NATIVE_TARGETS.map { |cell| native_table_name(cell) }).sort
      expected_schemas = tables.flat_map { |table| OUTPUT_TYPES.map { |name, type| [table, name, type] } }
      fail!('initial schema differs from exact source/target DDL') unless native.fetch(:schemas) == expected_schemas
      fail!('native data paths do not cover every source and empty target') unless native.fetch(:data_paths).keys.sort == tables
      @native_paths = native.fetch(:data_paths).to_h { |table, path| [table, validate_store_path!(path)] }
      fail!('stock source CHECK result differs') unless native.fetch(:checks) == {'source' => ["#{SOURCE_PART}\t1\t"]}
      fail!('initial active part roster differs') unless native.fetch(:parts).keys == ['source']
      source = only_part!(native, 'source')
      fail!('native source part is not the expected six-row Wide source') unless
        source.fetch(:name) == SOURCE_PART && source.fetch(:type) == 'Wide' &&
        source.fetch(:rows) == EXPECTED_SOURCE_ROWS.size.to_s && source.fetch(:marks) == '4'
      fail!('source row count differs') unless native.fetch(:row_counts).fetch('source') == EXPECTED_SOURCE_ROWS.size.to_s
      targets = ['target'] + NATIVE_TARGETS.map { |cell| native_table_name(cell) }
      fail!('one or more ClickHouse targets held rows before copy/ATTACH') unless
        targets.all? { |table| native.fetch(:row_counts).fetch(table) == '0' }
      fail!('offline metadata target unexpectedly has an active part') if native.fetch(:parts).key?('target')
      @source_part_path = validate_part_path!(source.fetch(:path))
      @source_inventory = inventory_part(@source_part_path)
    end

    def assert_pin!(native)
      expected = "__W286_PIN__\t#{VERSION}\t#{BUILD}"
      fail!("runtime version/build differs: #{native.fetch(:pin).inspect}") unless native.fetch(:pin) == expected
    end

    def prepare_offline_catalog!
      catalog = @catalog_root
      database_dir = File.join(catalog, 'store', DATABASE_UUID[0, 3], DATABASE_UUID)
      source_dir = File.join(catalog, 'store', SOURCE_UUID[0, 3], SOURCE_UUID)
      target_dir = File.join(catalog, 'store', TARGET_UUID[0, 3], TARGET_UUID)
      FileUtils.mkdir_p(File.join(catalog, 'metadata'), mode: 0o700)
      FileUtils.mkdir_p([database_dir, source_dir, target_dir], mode: 0o700)
      FileUtils.mkdir_p(File.join(target_dir, 'detached'), mode: 0o700)
      write_new(File.join(catalog, 'metadata', 'lab.sql'), "ATTACH DATABASE _ UUID '#{DATABASE_UUID}'\nENGINE = Atomic\n")
      write_new(File.join(source_dir, 'format_version.txt'), "1\n")
      write_new(File.join(target_dir, 'format_version.txt'), "1\n")
      source_tail = "ENGINE = MergeTree\nORDER BY pk\nSETTINGS #{SOURCE_SETTINGS}"
      target_tail = "ENGINE = MergeTree\nORDER BY pk\nSETTINGS #{TARGET_SETTINGS}"
      write_new(File.join(database_dir, 'source.sql'), attach_table_ddl(SOURCE_UUID, source_tail))
      write_new(File.join(database_dir, 'target.sql'), attach_table_ddl(TARGET_UUID, target_tail))
      write_new(File.join(database_dir, 'view.sql'), <<~DDL)
        ATTACH MATERIALIZED VIEW _ UUID '#{VIEW_UUID}' TO lab.target
        (
            #{COLUMN_DDL}
        )
        AS SELECT pk, score, payload, doc, trace FROM lab.source WHERE pk >= 3
      DDL
      source_destination = File.join(source_dir, SOURCE_PART)
      fail!('refusing an existing offline source part') if File.exist?(source_destination) || File.symlink?(source_destination)
      FileUtils.cp_r(@source_part_path, source_destination, preserve: true)
      fail!('offline source part bytes differ from stock source') unless inventory_part(source_destination) == @source_inventory
      @catalog_source_path = source_destination
      @catalog_target_detached = File.join(target_dir, 'detached')
    end

    def attach_table_ddl(uuid, tail)
      <<~DDL
        ATTACH TABLE _ UUID '#{uuid}'
        (
            #{COLUMN_DDL}
        )
        #{tail}
      DDL
    end

    def run_publish_cell!(cell)
      output_name = cell.fetch(:part)
      before_detached = inventory_tree(@catalog_target_detached)
      helper = run_helper(cell, output_name, 'publish')
      report = helper.fetch(:data)
      assert_helper_report!(report, cell, output_name)
      destination = report.fetch('destination')
      expected_path = File.join(@catalog_target_detached, output_name)
      fail!('helper destination escaped the resolved target detached directory') unless File.expand_path(destination) == expected_path
      generated = inventory_part(destination)
      fail!('generated output includes the ClickHouse ATTACH invalidation sidecar') if
        generated.fetch(:files).any? { |entry| entry.fetch(:relative_path) == SIDE_CAR }
      fail!('helper top-level file roster differs from the generated part') unless
        report.fetch('part_files') == generated.fetch(:files).map { |entry| entry.fetch(:relative_path) }
      mark_files = generated.fetch(:files).map { |entry| entry.fetch(:relative_path) }.select { |name| mark_file?(name) }
      fail!('generated mark-file layout differs from requested format') unless
        !mark_files.empty? && mark_files.all? { |name| name.end_with?(".#{cell.fetch(:mark)}") } && report.fetch('mark_files') == mark_files
      fail!('offline source part changed during callback') unless inventory_part(@catalog_source_path) == @source_inventory
      after_detached = inventory_tree(@catalog_target_detached)
      fail!('positive helper call left unexpected files in detached output directory') unless
        after_detached.keys.sort == (before_detached.keys + [output_name]).sort
      @generated_parts[cell.fetch(:id)] = {path: destination, inventory: generated, mark_files: mark_files}
      {helper: helper.fetch(:record), report: report, output_path: destination,
       output_inventory: generated, mark_files: mark_files, detached_before: before_detached}
    end

    def run_helper(cell, output_name, action)
      label = "helper_#{cell.fetch(:id)}_#{action}"
      stage_root = File.join(@root, 'generated', label)
      Dir.mkdir(stage_root, 0o700)
      args = [@catalog_root, SOURCE_PART, output_name, cell.fetch(:mark), cell.fetch(:profile), action]
      argument_path = File.join(stage_root, 'arguments.json')
      write_new(argument_path, JSON.pretty_generate({argv: [@helper] + args}) + "\n")
      before = sha_file(@helper)
      record = @native_runner.send(:run_process!, label, [@helper] + args, ''.b, argument_path, stage_root)
      fail!("#{label} process did not exit cleanly") unless
        record.fetch(:exitstatus) == 0 && record.fetch(:termsig).nil? && !record.fetch(:timed_out)
      fail!("#{label} output capture was truncated or failed") unless
        !record.fetch(:stdout_truncated) && !record.fetch(:stderr_truncated) &&
        record.fetch(:stdout_read_error).nil? && record.fetch(:stderr_read_error).nil? &&
        record.fetch(:stdin_write_error).nil?
      fail!("#{label} emitted stderr") unless File.size(File.join(stage_root, 'stderr.bin')).zero?
      fail!("#{label} helper executable changed during invocation") unless sha_file(@helper) == before
      stdout = read_bounded_file(File.join(stage_root, 'stdout.bin'), W284::MAX_PART_BYTES, label)
      lines = stdout.lines.reject(&:empty?)
      fail!("#{label} must emit exactly one JSON record") unless lines.size == 1
      data = JSON.parse(lines.fetch(0))
      {data: data, record: record, stdout_sha256: Digest::SHA256.hexdigest(stdout)}
    end

    def assert_helper_report!(report, cell, output_name)
      keys = %w[
        action destination format mark_files mark_format output_mark_rows output_part_name output_row_count
        output_rows part_files part_type source_part_name source_row_count source_selected_columns
        source_types status string_profile
      ]
      fail!('helper report keys/format/action differ') unless report.keys.sort == keys.sort &&
        report.fetch('format') == 'materialized_view_compact_transform_w286_helper_v1' &&
        report.fetch('action') == 'publish' && report.fetch('status') == 'ok'
      fail!('helper did not bind the expected source/output identity') unless
        report.fetch('source_part_name') == SOURCE_PART && report.fetch('output_part_name') == output_name
      fail!('helper source roster or declarations differ') unless
        report.fetch('source_selected_columns') == SOURCE_COLUMNS &&
        report.fetch('source_types') == OUTPUT_TYPES.map { |name, type| {'name' => name, 'type' => type} }
      fail!('helper source/output row counts differ') unless
        report.fetch('source_row_count') == EXPECTED_SOURCE_ROWS.size && report.fetch('output_row_count') == EXPECTED_TARGET_ROWS.size
      fail!('helper Compact mark/profile settings differ') unless
        report.fetch('mark_format') == cell.fetch(:mark) && report.fetch('string_profile') == cell.fetch(:profile) &&
        report.fetch('part_type') == 'Compact' && report.fetch('output_mark_rows') == [2, 2]
      expected_rows = W257_PROBE.send(:json_rows, EXPECTED_TARGET_ROWS)
      fail!('helper output differs from independently authored transformed literals') unless report.fetch('output_rows') == expected_rows
    end

    def run_refusal_probe!
      before = inventory_tree(@catalog_target_detached)
      catalog_before = inventory_part(@catalog_root)
      refusal_cell = {id: 'refusal', mark: 'mrk4', profile: 's1'}
      helper = run_helper(refusal_cell, 'all_13_13_0', 'refuse')
      report = helper.fetch(:data)
      fail!('invalid output roster was not refused after a complete callback scan') unless
        report['status'] == 'rejected_after_complete_scan' && report['callback_calls'] == 1 &&
        report['source_row_count'] == EXPECTED_SOURCE_ROWS.size &&
        report['error_class'] == 'CrystalClick::UnsupportedFormatError' &&
        report['error_message'] == 'prepared Compact columns do not match the bound target schema' &&
        report['destination_absent'] == true && !File.exist?(report['destination']) && !File.symlink?(report['destination'])
      after = inventory_tree(@catalog_target_detached)
      fail!('refused publication left a detached artifact or stage residue') unless after == before
      fail!('refused publication changed any offline catalog artifact') unless inventory_part(@catalog_root) == catalog_before
      @refusal_result = {helper: helper.fetch(:record), report: report, detached_unchanged: true,
                         catalog_unchanged: true, catalog_before: catalog_before}
    end

    def copy_all_to_detached!
      NATIVE_TARGETS.each do |cell|
        id = cell.fetch(:id)
        generated = @generated_parts.fetch(id)
        target = native_table_name(cell)
        detached_root = File.join(@native_paths.fetch(target), 'detached')
        if File.exist?(detached_root) || File.symlink?(detached_root)
          stat = File.lstat(detached_root)
          fail!("#{target} detached directory is unsafe") unless stat.directory? && !stat.symlink? && Dir.children(detached_root).empty?
        else
          Dir.mkdir(detached_root, 0o700)
        end
        destination = File.join(detached_root, cell.fetch(:part))
        fail!("#{target} detached part name is occupied") if File.exist?(destination) || File.symlink?(destination)
        FileUtils.cp_r(generated.fetch(:path), destination, preserve: true)
        copied = inventory_part(destination)
        fail!("#{target} detached bytes differ from the library part") unless copied == generated.fetch(:inventory)
        write_new(File.join(@root, 'native', "copy_#{id}.json"), JSON.pretty_generate({
          generated_path: generated.fetch(:path), detached_path: destination,
          generated_inventory: generated.fetch(:inventory), copied_inventory: copied,
          byte_identical: true,
        }) + "\n")
        @cells.fetch(id)[:detached_copy] = {path: destination, inventory: copied, byte_identical: true}
      end
    end

    def attach_sql
      statements = [
        'SET flatten_nested=0;',
        'SET allow_suspicious_low_cardinality_types=1;',
        pin_sql,
      ]
      NATIVE_TARGETS.each do |cell|
        table = native_table_name(cell)
        statements << "ALTER TABLE lab.#{table} ATTACH PART '#{cell.fetch(:part)}';"
      end
      statements << check_sql('source')
      NATIVE_TARGETS.each { |cell| statements << check_sql(native_table_name(cell)) }
      statements << schema_sql(['source', 'target'] + NATIVE_TARGETS.map { |cell| native_table_name(cell) })
      statements << data_paths_sql(['source', 'target'] + NATIVE_TARGETS.map { |cell| native_table_name(cell) })
      statements << parts_sql(['source', 'target'] + NATIVE_TARGETS.map { |cell| native_table_name(cell) })
      statements.concat((['source'] + NATIVE_TARGETS.map { |cell| native_table_name(cell) }).map { |table| row_count_sql(table) })
      statements.join("\n") + "\n"
    end

    def reopen_sql
      statements = [
        'SET flatten_nested=0;',
        'SET allow_suspicious_low_cardinality_types=1;',
        pin_sql,
      ]
      statements << check_sql('source')
      NATIVE_TARGETS.each { |cell| statements << check_sql(native_table_name(cell)) }
      statements << schema_sql(['source', 'target'] + NATIVE_TARGETS.map { |cell| native_table_name(cell) })
      statements << data_paths_sql(['source', 'target'] + NATIVE_TARGETS.map { |cell| native_table_name(cell) })
      statements << parts_sql(['source', 'target'] + NATIVE_TARGETS.map { |cell| native_table_name(cell) })
      statements.concat((['source'] + NATIVE_TARGETS.map { |cell| native_table_name(cell) }).map { |table| row_count_sql(table) })
      statements.join("\n") + "\n"
    end

    def assert_consumed_targets!(native, stage)
      assert_pin!(native)
      tables = (['source', 'target'] + NATIVE_TARGETS.map { |cell| native_table_name(cell) }).sort
      expected_schemas = tables.flat_map { |table| OUTPUT_TYPES.map { |name, type| [table, name, type] } }
      fail!("#{stage} schema differs from native target/source DDL") unless native.fetch(:schemas) == expected_schemas
      canonical_paths = native.fetch(:data_paths).to_h do |table, path|
        [table, validate_store_path!(path)]
      end
      fail!("#{stage} native table data paths changed") unless canonical_paths == @native_paths
      expected_checks = {'source' => ["#{SOURCE_PART}\t1\t"]}
      NATIVE_TARGETS.each do |cell|
        expected_checks[native_table_name(cell)] = ["#{ATTACHED_PART}\t1\t"]
      end
      fail!("#{stage} CHECK results differ") unless native.fetch(:checks) == expected_checks
      expected_parts = ['source'] + NATIVE_TARGETS.map { |cell| native_table_name(cell) }
      fail!("#{stage} active part roster differs") unless native.fetch(:parts).keys.sort == expected_parts.sort
      expected_counts = {'source' => EXPECTED_SOURCE_ROWS.size.to_s}
      expected_counts.merge!(NATIVE_TARGETS.to_h { |cell| [native_table_name(cell), EXPECTED_TARGET_ROWS.size.to_s] })
      fail!("#{stage} target row counts differ") unless native.fetch(:row_counts) == expected_counts
      source = only_part!(native, 'source')
      fail!("#{stage} source part identity/layout changed") unless
        source.fetch(:name) == SOURCE_PART && source.fetch(:type) == 'Wide' &&
        source.fetch(:rows) == EXPECTED_SOURCE_ROWS.size.to_s && source.fetch(:marks) == '4'
      fail!("#{stage} source part path changed") unless validate_part_path!(source.fetch(:path)) == @source_part_path

      NATIVE_TARGETS.each do |cell|
        table = native_table_name(cell)
        part = only_part!(native, table)
        fail!("#{stage} #{table} did not retain the attached Compact part/grid") unless
          part.fetch(:name) == ATTACHED_PART && part.fetch(:type) == 'Compact' &&
          part.fetch(:rows) == EXPECTED_TARGET_ROWS.size.to_s && part.fetch(:marks) == '3'
        part_path = validate_native_part_path!(part.fetch(:path), table, ATTACHED_PART)
        inventory = inventory_part(part_path)
        generated_inventory = @generated_parts.fetch(cell.fetch(:id)).fetch(:inventory)
        sidecar_bytes = read_bounded_file(File.join(part_path, SIDE_CAR), SIDE_CAR_BYTES.bytesize, "#{stage} sidecar")
        sidecar = assert_attached_inventory_contract!(generated_inventory, inventory, sidecar_bytes)
        @native_parts[cell.fetch(:id)] ||= {}
        @native_parts[cell.fetch(:id)][stage.to_sym] = {
          name: part.fetch(:name), rows: Integer(part.fetch(:rows)), marks: Integer(part.fetch(:marks)),
          part_type: part.fetch(:type), path: part_path, inventory: inventory, sidecar: sidecar,
        }
      end
      true
    end

    def read_target!(cell, stage)
      label = "#{stage}_rowbinary_#{cell.fetch(:id)}"
      result = run_native(label, rowbinary_sql(native_table_name(cell)))
      W257.validate_rowbinary!(result.fetch(:stdout), EXPECTED_TARGET_ROWS)
      {row_count: EXPECTED_TARGET_ROWS.size, stdout_sha256: Digest::SHA256.hexdigest(result.fetch(:stdout)),
       independent_literals_exact: true, invocation: result.fetch(:record)}
    end

    def assert_attached_inventory_contract!(generated, attached, sidecar_bytes)
      old_files = generated.fetch(:files).to_h { |entry| [entry.fetch(:relative_path), entry] }
      new_files = attached.fetch(:files).to_h { |entry| [entry.fetch(:relative_path), entry] }
      fail!('ATTACH removed or changed a generated source file') unless old_files.all? { |path, entry| new_files[path] == entry }
      extras = new_files.keys - old_files.keys
      fail!('ATTACH added files other than the one server-created sidecar') unless extras == [SIDE_CAR]
      sidecar = new_files.fetch(SIDE_CAR)
      fail!('ATTACH sidecar size/hash differs') unless
        sidecar.fetch(:bytes) == SIDE_CAR_BYTES.bytesize && sidecar.fetch(:sha256) == SIDE_CAR_SHA256
      fail!('ATTACH sidecar bytes differ') unless sidecar_bytes == SIDE_CAR_BYTES
      fail!('ATTACH file count differs') unless attached.fetch(:file_count) == generated.fetch(:file_count) + 1
      {path: SIDE_CAR, bytes: sidecar_bytes.bytesize, sha256: Digest::SHA256.hexdigest(sidecar_bytes),
       original_files_preserved: true, extra_files: extras}
    end

    def run_auditor_negative_control!(cell)
      id = cell.fetch(:id)
      original = @native_parts.fetch(id).fetch(:attach).fetch(:path)
      mutant_root = File.join(@root, 'mutants', id)
      fail!('auditor mutation path already exists') if File.exist?(mutant_root) || File.symlink?(mutant_root)
      FileUtils.cp_r(original, mutant_root, preserve: true)
      victim = @generated_parts.fetch(id).fetch(:inventory).fetch(:files).find do |entry|
        entry.fetch(:bytes).positive? && entry.fetch(:relative_path) != SIDE_CAR
      end
      fail!('no nonempty generated file is available for the auditor mutation') unless victim
      victim_path = File.join(mutant_root, victim.fetch(:relative_path))
      File.chmod(0o600, victim_path)
      bytes = File.binread(victim_path)
      bytes.setbyte(0, bytes.getbyte(0) ^ 1)
      File.binwrite(victim_path, bytes)
      mutated_inventory = inventory_part(mutant_root)
      sidecar_bytes = File.binread(File.join(mutant_root, SIDE_CAR))
      rejected = false
      begin
        assert_attached_inventory_contract!(@generated_parts.fetch(id).fetch(:inventory), mutated_inventory, sidecar_bytes)
      rescue Error
        rejected = true
      end
      fail!('inventory auditor accepted a byte-mutated attached Compact part') unless rejected
      @auditor_negative = {
        case_id: id,
        mutation: 'flip the first byte of one copied generated part file',
        path: victim.fetch(:relative_path),
        auditor_rejected: true,
        production_artifacts_unchanged: inventory_part(original) == @native_parts.fetch(id).fetch(:attach).fetch(:inventory),
      }
      fail!('auditor negative control changed the actual attached part') unless @auditor_negative.fetch(:production_artifacts_unchanged)
    ensure
      FileUtils.rm_rf(mutant_root) if mutant_root && (File.exist?(mutant_root) || File.symlink?(mutant_root))
    end

    def validate_end_state!
      @runtime_sha_after = sha_file(@binary)
      @helper_sha_after = sha_file(@helper)
      @input_hashes_after = input_hashes
      fail!('pinned ClickHouse runtime changed during witness') unless
        @runtime_sha_after == RUNTIME_PIN.fetch(:sha256) && File.size(@binary) == RUNTIME_PIN.fetch(:bytes)
      fail!('prebuilt Crystal helper changed during witness') unless @helper_sha_after == @helper_sha_before
      fail!('W286 runner and implementation inputs changed during witness') unless @input_hashes_after == @input_hashes_before
      fail!('source part changed during helper/ATTACH/reopen') unless inventory_part(@source_part_path) == @source_inventory
      NATIVE_TARGETS.each do |cell|
        id = cell.fetch(:id)
        generated = @generated_parts.fetch(id)
        fail!("#{id} generated part changed") unless inventory_part(generated.fetch(:path)) == generated.fetch(:inventory)
        attached = @native_parts.fetch(id).fetch(:reopen)
        fail!("#{id} attached part changed after reopen") unless inventory_part(attached.fetch(:path)) == attached.fetch(:inventory)
      end
      true
    end

    def input_manifest
      {
        format: FORMAT,
        status: 'execution_inputs_pinned_before_capture',
        repository: W284::REPO_ROOT,
        repository_revision: git_revision,
        helper_mode: @helper_mode,
        helper_path: @helper,
        helper_sha256: @helper_sha_before,
        clickhouse_path: @binary,
        clickhouse_runtime: RUNTIME_PIN,
        source_part_name: SOURCE_PART,
        native_cases: NATIVE_TARGETS,
        source_literal_sha256: Digest::SHA256.hexdigest(JSON.generate(EXPECTED_SOURCE_ROWS)),
        target_literal_sha256: Digest::SHA256.hexdigest(JSON.generate(EXPECTED_TARGET_ROWS)),
        runner_input_sha256: @input_hashes_before,
        limits: {threads: 1, max_memory_usage_bytes: 536_870_912, timeout_seconds: W284::PROCESS_TIMEOUT_SECONDS,
                 termination_grace_seconds: 5, part_files: W284::MAX_PART_FILES, part_bytes: W284::MAX_PART_BYTES},
      }
    end

    def write_summary(data)
      summary = {
        probe: 'W286 caller-run materialized-view Compact native witness',
        status: data[:status], fatal_error: data[:fatal_error],
        helper_mode: @helper_mode,
        runtime: {path: @binary, expected_sha256: RUNTIME_PIN.fetch(:sha256),
                  sha256_before: @runtime_sha_before, sha256_after: @runtime_sha_after,
                  expected_bytes: RUNTIME_PIN.fetch(:bytes), version: VERSION, build: BUILD},
        helper: {path: @helper, sha256_before: @helper_sha_before, sha256_after: @helper_sha_after},
        input_sha256_before: @input_hashes_before, input_sha256_after: @input_hashes_after,
        source_revision: @source_revision,
        limits: {max_threads: 1, max_memory_usage_bytes: 536_870_912,
                 timeout_seconds: W284::PROCESS_TIMEOUT_SECONDS, termination_grace_seconds: 5,
                 part_files: W284::MAX_PART_FILES, part_bytes: W284::MAX_PART_BYTES},
        evidence_root: @root, process_records: @native_runner&.instance_variable_get(:@processes),
      }.merge(data.reject { |key, _| %i[status fatal_error].include?(key) })
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n") if @root
      if @root
        write_new(File.join(@root, 'summary.md'), [
          '# W286 caller-run materialized-view Compact native witness', '',
          "Status: `#{summary[:status]}`", '',
          'Scope: one stock-created six-row Wide source part, one full callback scan, filtered/rekeyed Compact output with static, Dynamic, JSON, and recursive JSON/Dynamic owners; MRK3/MRK4 × both String profiles; direct byte-preserving copy to empty stock targets, native ATTACH/CHECK/RowBinary read, then a separate-process reopen and repeat read. This does not execute the persisted MATERIALIZED VIEW SELECT or prove callback provenance.', '',
          "Runtime: #{VERSION} / #{BUILD} / SHA256 `#{RUNTIME_PIN.fetch(:sha256)}`", '',
          "Evidence root: `#{@root}`", '',
        ].join("\n"))
      end
      summary
    end

    def run_native(label, sql)
      cell_root = File.join(@root, 'native', label)
      Dir.mkdir(cell_root, 0o700)
      result = @native_runner.send(:run_stage!, label, 'run', @native_store, sql, cell_root)
      record = result.fetch(:record)
      {stdout: result.fetch(:stdout), record: record}
    end

    def validate_store_path!(path)
      root = File.realpath(File.join(@root, 'native'))
      full = File.expand_path(path)
      real = File.realpath(full)
      fail!('native table path escaped the evidence store') unless real.start_with?(root + File::SEPARATOR)
      fail!('native table path is not a plain directory') unless File.directory?(real) && !File.symlink?(full)
      real
    end

    def validate_part_path!(path)
      full = File.expand_path(path)
      real = File.realpath(full)
      store = File.realpath(@native_store)
      fail!('native source part escaped the ClickHouse store') unless real.start_with?(store + File::SEPARATOR)
      fail!('native source part is not a plain part directory') unless File.directory?(real) && !File.symlink?(full)
      real
    end

    def validate_native_part_path!(path, table, part_name)
      full = File.expand_path(path)
      real = File.realpath(full)
      data_path = File.realpath(@native_paths.fetch(table))
      fail!("native part path escaped #{table}") unless real.start_with?(data_path + File::SEPARATOR) && File.basename(real) == part_name
      fail!('native active part path is not a plain directory') unless File.directory?(real) && !File.symlink?(full)
      real
    end

    def inventory_part(path)
      @native_runner.send(:inventory_part, path)
    end

    def inventory_tree(path)
      return {} unless File.directory?(path) && !File.symlink?(path)
      Dir.children(path).sort.to_h do |name|
        item = File.join(path, name)
        if File.directory?(item) && !File.symlink?(item)
          [name, inventory_part(item)]
        elsif File.file?(item) && !File.symlink?(item)
          [name, {bytes: File.size(item), sha256: sha_file(item)}]
        else
          fail!("unsafe entry in detached directory: #{name}")
        end
      end
    end

    def only_part!(native, table)
      rows = native.fetch(:parts).fetch(table, [])
      fail!("#{table} must have exactly one active part") unless rows.size == 1
      rows.fetch(0)
    end

    def native_table_name(cell)
      "native_#{cell.fetch(:id)}"
    end

    def mark_file?(name)
      name.end_with?('.mrk3') || name.end_with?('.mrk4')
    end

    def read_bounded_file(path, limit, label)
      fail!("#{label} is a symlink or absent") unless File.file?(path) && !File.symlink?(path)
      fail!("#{label} exceeds its byte cap") if File.size(path) > limit
      File.binread(path)
    end

    def write_new(path, bytes)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(bytes) }
    end

    def sha_file(path)
      Digest::SHA256.file(path).hexdigest
    end

    def input_hashes
      (SCRIPT_INPUTS + SOURCE_INPUTS).to_h do |relative|
        path = File.join(W284::REPO_ROOT, relative)
        fail!("missing frozen W286 witness input: #{relative}") unless File.file?(path) && !File.symlink?(path)
        [relative, sha_file(path)]
      end
    end

    def git_revision
      output, status = Open3.capture2('git', '-C', W284::REPO_ROOT, 'rev-parse', 'HEAD')
      fail!('cannot capture crystal-click source revision') unless status.success?
      output.strip
    end

    def fail!(message)
      raise Error, "W286 Compact transform witness: #{message}"
    end
  end

  def self.run(argv = ARGV)
    options = {binary: BINARY, helper: nil, evidence_root: nil, helper_mode: nil}
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: ruby scripts/verify_materialized_view_compact_transform_w286.rb --crystal-helper PATH --helper-mode debug|release --evidence-root EMPTY_DIRECT_CHILD [--clickhouse PINNED_PATH]'
      opts.on('--clickhouse PATH') { |value| options[:binary] = value }
      opts.on('--crystal-helper PATH') { |value| options[:helper] = value }
      opts.on('--helper-mode MODE') { |value| options[:helper_mode] = value }
      opts.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
    end
    parser.parse!(argv)
    raise OptionParser::MissingArgument, '--crystal-helper' unless options[:helper]
    raise OptionParser::MissingArgument, '--evidence-root' unless options[:evidence_root]
    raise OptionParser::MissingArgument, '--helper-mode debug|release' unless %w[debug release].include?(options[:helper_mode])
    raise OptionParser::InvalidArgument, 'unexpected positional arguments' unless argv.empty?
    driver = Driver.new(options)
    exit(driver.run ? 0 : 1)
  rescue OptionParser::ParseError, ArgumentError => error
    warn "W286 usage error: #{error.message}"
    warn parser
    exit(2)
  end
end

VerifyMaterializedViewCompactTransformW286.run if $PROGRAM_NAME == __FILE__
