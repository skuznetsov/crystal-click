#!/usr/bin/env ruby
# Bounded W290 source -> caller transform -> mixed projection pair witness.
# It consumes prebuilt executables only; Crystal builds remain caller-owned.

require 'digest'
require 'base64'
require 'fileutils'
require 'find'
require 'json'
require 'open3'
require 'optparse'
require_relative 'verify_compact_recursive_dynamic_w284'

module VerifyMaterializedViewProjectionTransformW290
  W284 = VerifyCompactRecursiveDynamicW284
  REPO_ROOT = File.expand_path('..', __dir__).freeze
  FORMAT = 'materialized_view_projection_transform_w290_native_v1'.freeze
  BINARY = W284::BINARY
  RUNTIME_PIN = W284::RUNTIME_PIN
  VERSION = RUNTIME_PIN.fetch(:version)
  BUILD = RUNTIME_PIN.fetch(:build)
  RUN_SAFE_SHA256 = 'fbfa0fd9d717eb24c1a3f829d464188110e505c7ae311eee2e95cbe7cefab011'.freeze
  DATABASE = 'lab'.freeze
  DATABASE_UUID = 'f2900000-7b7f-4e2f-9e44-dc13a87b8801'.freeze
  SOURCE_UUID = 'f2900000-7b7f-4e2f-9e44-dc13a87b8802'.freeze
  COMPACT_TARGET_UUID = 'f2900000-7b7f-4e2f-9e44-dc13a87b8803'.freeze
  WIDE_TARGET_UUID = 'f2900000-7b7f-4e2f-9e44-dc13a87b8804'.freeze
  COMPACT_VIEW_UUID = 'f2900000-7b7f-4e2f-9e44-dc13a87b8805'.freeze
  WIDE_VIEW_UUID = 'f2900000-7b7f-4e2f-9e44-dc13a87b8806'.freeze
  SOURCE_PART = 'all_1_1_0'.freeze
  COMPACT_PART = 'all_9_9_0'.freeze
  WIDE_PART = 'all_10_10_0'.freeze
  PROJECTION = 'by_score'.freeze
  TABLES = %w[source target_compact target_wide].freeze
  COLUMNS = [['id', 'UInt64'], ['score', 'UInt64'], ['label', 'String']].map(&:freeze).freeze
  TARGET_SETTINGS = 'index_granularity=2, min_rows_for_wide_part=0, min_bytes_for_wide_part=0'.freeze
  PROJECTION_DDL = 'PROJECTION by_score (SELECT score, id, label ORDER BY score) WITH SETTINGS (index_granularity = 3)'.freeze
  MEMORY_BYTES = 536_870_912
  PROCESS_MEMORY_BYTES = 2 * 1024 * 1024 * 1024
  PROCESS_TIMEOUT_SECONDS = 90
  TERMINATION_GRACE_SECONDS = 2
  MAX_CAPTURE_BYTES = 16 * 1024 * 1024
  MAX_PART_FILES = 256
  MAX_PART_BYTES = 16 * 1024 * 1024
  ATTACH_SIDECAR = 'invalidated_system_columns.txt'.freeze
  ATTACH_SIDECAR_BYTES = "_block_offset\n_block_number\n".b.freeze
  ATTACH_SIDECAR_SHA256 = '7409424ab45090c1261e622f7423393905102e7e8cba36a6db88eb513ce1e06c'.freeze
  SOURCE_ROWS = [
    {id: 1, score: 50, label: "a\0b"},
    {id: 2, score: 10, label: ''},
    {id: 3, score: 40, label: 'café'},
    {id: 4, score: 20, label: "z\0"},
    {id: 5, score: 60, label: 'é'},
    {id: 6, score: 30, label: 'hi'},
    {id: 7, score: 70, label: 'drop-seven'},
    {id: 8, score: 80, label: 'drop-eight'},
  ].map(&:freeze).freeze
  # This oracle is literal and does not apply the Crystal callback formula.
  OUTPUT_ROWS = [
    {id: 101, score: 1050, label: "a\0b!"},
    {id: 102, score: 1010, label: '!'},
    {id: 103, score: 1040, label: 'café!'},
    {id: 104, score: 1020, label: "z\0!"},
    {id: 105, score: 1060, label: 'é!'},
    {id: 106, score: 1030, label: 'hi!'},
  ].map(&:freeze).freeze
  PROJECTION_ROWS = OUTPUT_ROWS.sort_by { |row| row.fetch(:score) }.freeze
  SCRIPT_INPUTS = %w[
    scripts/verify_materialized_view_projection_transform_w290.rb
    scripts/check_materialized_view_projection_transform_w290.cr
    scripts/verify_compact_recursive_dynamic_w284.rb
  ].freeze
  class Error < StandardError; end

  class Driver
    def initialize(options)
      @options = options
      @root_argument = options.fetch(:evidence_root)
      @binary_argument = options.fetch(:binary)
      @helper_argument = options.fetch(:helper)
      @run_safe_argument = options.fetch(:run_safe)
      @helper_mode = options.fetch(:helper_mode)
      @root = nil
      @native_store = nil
      @catalog_root = nil
      @binary = nil
      @helper = nil
      @run_safe = nil
      @binary_sha_before = nil
      @helper_sha_before = nil
      @run_safe_sha_before = nil
      @source_revision = nil
      @input_hashes_before = nil
      @processes = []
      @native_paths = {}
      @native_metadata = {}
      @source_part_path = nil
      @source_inventory = nil
      @generated_parts = {}
      @attached_parts = {}
      @helper_reports = {}
      @fatal_error = nil
    end

    def run
      prepare!
      create_native_source!
      insert_source_rows!
      source_state = verify_source_and_capture_path!
      source_rowbinary = run_native('source_rowbinary', "SELECT id, score, label FROM #{DATABASE}.source ORDER BY id FORMAT RowBinary;\n".b)
      assert_bytes!(source_rowbinary.fetch(:stdout), rowbinary_rows(SOURCE_ROWS, %i[id score label]), 'stock source RowBinary')
      @source_rowbinary_sha = Digest::SHA256.hexdigest(source_rowbinary.fetch(:stdout))

      target_state = create_empty_targets_and_views!
      @native_paths.merge!(target_state.fetch(:paths))
      build_offline_catalog!(target_state.fetch(:metadata_paths))
      publish_report = run_helper('publish')
      @helper_reports[:publish] = publish_report
      validate_publish_report!(publish_report)
      snapshot_generated_parts!
      copy_generated_to_native_detached!

      attach_state = attach_check_and_inventory!
      copy_attached_parts_to_catalog!
      verify_native_rowbinary!
      explain = verify_projection_plans!
      attached_names = %w[target_compact target_wide].map { |table| @attached_parts.fetch(table).fetch(:name) }
      reopen_report = run_helper('reopen', attached_names)
      @helper_reports[:reopen] = reopen_report
      validate_reopen_report!(reopen_report)
      validate_end_state!

      write_summary(
        status: 'both_mixed_projection_pairs_attached_checked_and_reopened',
        source: source_state,
        initial_targets: target_state.fetch(:markers),
        attached_native: attach_state,
        source_rowbinary: {
          row_count: SOURCE_ROWS.size,
          oracle_sha256: Digest::SHA256.hexdigest(rowbinary_rows(SOURCE_ROWS, %i[id score label])),
          native_sha256: @source_rowbinary_sha,
          exact: true,
        },
        generated_parts: @generated_parts,
        attached_parts: @attached_parts,
        projection_reads: @projection_reads,
        explains: explain,
        helper_reports: @helper_reports,
        native_data_paths: @native_paths,
        native_metadata: @native_metadata,
      )
      puts "W290 mixed projection transform witness passed; helper_mode=#{@helper_mode}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      @binary_sha_after = sha_file(@binary_argument) rescue nil
      @helper_sha_after = sha_file(@helper_argument) rescue nil
      @run_safe_sha_after = sha_file(@run_safe_argument) rescue nil
      @input_hashes_after = input_hashes rescue nil
      write_summary(status: 'runner_failure_or_observations_differ', fatal_error: @fatal_error) rescue nil
      warn "W290 probe failure (process failure is not native format evidence): #{@fatal_error}"
      false
    end

    private

    def prepare!
      @root = validate_evidence_root(@root_argument)
      @binary = validate_runtime!(@binary_argument)
      @helper = validate_helper!(@helper_argument)
      @run_safe = validate_run_safe!(@run_safe_argument)
      fail!('helper mode must be debug or release') unless %w[debug release].include?(@helper_mode)
      @binary_sha_before = sha_file(@binary)
      @helper_sha_before = sha_file(@helper)
      @run_safe_sha_before = sha_file(@run_safe)
      @input_hashes_before = input_hashes
      @source_revision = git_revision
      %w[native catalog generated helper invocations].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      ENV['TMPDIR'] = File.join(@root, 'tmp')
      ENV['TMP'] = ENV['TMPDIR']
      ENV['TEMP'] = ENV['TMPDIR']
      Dir.mkdir(ENV.fetch('TMPDIR'), 0o700)
      @native_store = File.join(@root, 'native', 'store')
      @catalog_root = File.join(@root, 'catalog', 'offline_catalog')
      write_new(File.join(@root, 'input_manifest.json'), JSON.pretty_generate(input_manifest) + "\n")
    end

    def validate_evidence_root(path)
      fail!('evidence root is required') unless path.is_a?(String) && !path.empty?
      expanded = File.expand_path(path)
      parent = File.dirname(expanded)
      fail!('evidence root parent must be an existing canonical directory') unless
        File.directory?(parent) && !File.symlink?(parent) && File.realpath(parent) == parent
      parent_stat = File.stat(parent)
      fail!('evidence root must be on a non-system volume') if parent_stat.dev == File.stat('/').dev
      fail!('evidence root already exists or is a symlink') if File.exist?(expanded) || File.symlink?(expanded)
      Dir.mkdir(expanded, 0o700)
      real = File.realpath(expanded)
      stat = File.lstat(expanded)
      fail!('evidence root must be a plain owned directory on the selected volume') unless
        real == expanded && stat.directory? && !stat.symlink? && stat.uid == Process.uid && stat.dev == parent_stat.dev
      real
    rescue Errno::ENOENT
      fail!('evidence root parent or path is absent')
    end

    def validate_runtime!(path)
      expanded = File.expand_path(path)
      fail!('ClickHouse runtime is absent or non-executable') unless File.file?(expanded) && File.executable?(expanded)
      full = File.realpath(expanded)
      fail!('ClickHouse runtime byte size differs from the pinned artifact') unless File.size(full) == RUNTIME_PIN.fetch(:bytes)
      fail!('ClickHouse runtime SHA-256 differs from the pinned artifact') unless sha_file(full) == RUNTIME_PIN.fetch(:sha256)
      full
    end

    def validate_helper!(path)
      fail!('prebuilt Crystal helper path is required') unless path.is_a?(String) && !path.empty?
      expanded = File.expand_path(path)
      fail!('prebuilt Crystal helper is absent or non-executable') unless File.file?(expanded) && File.executable?(expanded)
      File.realpath(expanded)
    end

    def validate_run_safe!(path)
      fail!('run_safe path is required') unless path.is_a?(String) && !path.empty?
      expanded = File.expand_path(path)
      fail!('run_safe guard is absent or non-executable') unless File.file?(expanded) && File.executable?(expanded)
      full = File.realpath(expanded)
      fail!('run_safe guard SHA-256 differs from the verified W290 guard') unless sha_file(full) == RUN_SAFE_SHA256
      full
    end

    def create_native_source!
      sql = <<~SQL
        CREATE DATABASE #{DATABASE} ENGINE = Atomic;
        CREATE TABLE #{DATABASE}.source UUID '#{SOURCE_UUID}'
        (
            id UInt64,
            score UInt64,
            label String
        ) ENGINE = MergeTree ORDER BY id SETTINGS #{TARGET_SETTINGS};
        SELECT '__W290_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;
      SQL
      result = run_native('create_source_before_views', sql.b)
      assert_pin!(result.fetch(:stdout))
    end

    def insert_source_rows!
      sql_prefix = "INSERT INTO #{DATABASE}.source FORMAT RowBinary\n".b
      result = run_native('insert_source_rowbinary_before_views', sql_prefix + rowbinary_rows(SOURCE_ROWS, %i[id score label]))
      fail!('ClickHouse RowBinary INSERT emitted unexpected stdout') unless result.fetch(:stdout).empty?
    end

    def verify_source_and_capture_path!
      sql = [
        pin_sql,
        check_sql('source'),
        part_sql(['source']),
        data_path_sql(['source']),
        "SELECT '__W290_ROWCOUNT__', 'source', toString(count()) FROM #{DATABASE}.source FORMAT TSVRaw;",
      ].join("\n") + "\n"
      result = run_native('verify_stock_source_before_views', sql.b)
      native = parse_markers(result.fetch(:stdout))
      assert_pin_marker!(native)
      fail!('stock source CHECK differs') unless native.fetch(:checks) == {'source' => ["#{SOURCE_PART}\t1\t"]}
      fail!('stock source row count differs') unless native.fetch(:row_counts) == {'source' => SOURCE_ROWS.size.to_s}
      source = only_part!(native, 'source')
      fail!('source is not the expected eight-row Wide stock part') unless
        source.fetch(:name) == SOURCE_PART && source.fetch(:part_type) == 'Wide' && source.fetch(:rows) == '8' && source.fetch(:marks) == '5'
      @native_paths['source'] = validate_store_path!(native.fetch(:data_paths).fetch('source'))
      @source_part_path = validate_native_part_path!(source.fetch(:path), 'source', SOURCE_PART)
      @source_inventory = inventory_part(@source_part_path)
      {native: native, source_part_path: @source_part_path, source_inventory: @source_inventory}
    end

    def create_empty_targets_and_views!
      projection_clause = PROJECTION_DDL
      create_target = lambda do |name, uuid|
        "CREATE TABLE #{DATABASE}.#{name} UUID '#{uuid}' (id UInt64, score UInt64, label String, #{projection_clause}) ENGINE = MergeTree ORDER BY id SETTINGS #{TARGET_SETTINGS};"
      end
      sql = [
        pin_sql,
        create_target.call('target_compact', COMPACT_TARGET_UUID),
        create_target.call('target_wide', WIDE_TARGET_UUID),
        "CREATE MATERIALIZED VIEW #{DATABASE}.view_compact UUID '#{COMPACT_VIEW_UUID}' TO #{DATABASE}.target_compact (id UInt64, score UInt64, label String) AS SELECT id, score, label FROM #{DATABASE}.source;",
        "CREATE MATERIALIZED VIEW #{DATABASE}.view_wide UUID '#{WIDE_VIEW_UUID}' TO #{DATABASE}.target_wide (id UInt64, score UInt64, label String) AS SELECT id, score, label FROM #{DATABASE}.source;",
        row_counts_sql(['target_compact', 'target_wide']),
        data_path_sql(['target_compact', 'target_wide']),
        part_sql(['target_compact', 'target_wide']),
        metadata_path_sql(%w[source target_compact target_wide view_compact view_wide]),
      ].join("\n") + "\n"
      result = run_native('create_projection_targets_and_views_after_insert', sql.b)
      native = parse_markers(result.fetch(:stdout))
      assert_pin_marker!(native)
      fail!('native MV targets were not empty after creation') unless
        native.fetch(:row_counts) == {'target_compact' => '0', 'target_wide' => '0'}
      fail!('native MV targets unexpectedly have active parts') unless native.fetch(:parts).empty?
      fail!('native target data-path roster differs') unless native.fetch(:data_paths).keys.sort == %w[target_compact target_wide]
      paths = native.fetch(:data_paths).to_h { |table, path| [table, validate_store_path!(path)] }
      metadata_paths = native.fetch(:metadata_paths)
      fail!('native metadata-path roster differs') unless metadata_paths.keys.sort == %w[source target_compact target_wide view_compact view_wide]
      {markers: native, paths: paths, metadata_paths: metadata_paths}
    end

    def build_offline_catalog!(native_metadata_paths)
      database_path = uuid_path(DATABASE_UUID)
      source_path = uuid_path(SOURCE_UUID)
      compact_path = uuid_path(COMPACT_TARGET_UUID)
      wide_path = uuid_path(WIDE_TARGET_UUID)
      [database_path, source_path, compact_path, wide_path].each { |path| FileUtils.mkdir_p(path, mode: 0o700) }
      FileUtils.mkdir_p(File.join(@catalog_root, 'metadata'), mode: 0o700)
      [source_path, compact_path, wide_path].each { |path| write_new(File.join(path, 'format_version.txt'), "1\n") }
      FileUtils.mkdir_p(File.join(compact_path, 'detached'), mode: 0o700)
      FileUtils.mkdir_p(File.join(wide_path, 'detached'), mode: 0o700)
      write_new(File.join(@catalog_root, 'metadata', 'lab.sql'), "ATTACH DATABASE _ UUID '#{DATABASE_UUID}'\nENGINE = Atomic\n")
      {
        'source' => [SOURCE_UUID, 'TABLE'],
        'target_compact' => [COMPACT_TARGET_UUID, 'TABLE'],
        'target_wide' => [WIDE_TARGET_UUID, 'TABLE'],
        'view_compact' => [COMPACT_VIEW_UUID, 'MATERIALIZED VIEW'],
        'view_wide' => [WIDE_VIEW_UUID, 'MATERIALIZED VIEW'],
      }.each do |name, (uuid, kind)|
        path = validate_metadata_path!(native_metadata_paths.fetch(name), name)
        ddl = File.binread(path)
        fail!("native persisted #{name} metadata exceeds the OfflineCatalog DDL bound") if ddl.bytesize > 1_048_576
        fail!("native persisted #{name} metadata is not UTF-8") unless ddl.dup.force_encoding(Encoding::UTF_8).valid_encoding?
        header = /\A\s*ATTACH\s+#{Regexp.escape(kind)}\s+_\s+UUID\s+'#{Regexp.escape(uuid)}'/im
        fail!("native persisted #{name} metadata identity differs") unless header.match?(ddl)
        write_new(File.join(database_path, "#{name}.sql"), ddl)
        @native_metadata ||= {}
        @native_metadata[name] = {path: path, bytes: ddl.bytesize, sha256: Digest::SHA256.hexdigest(ddl)}
      end
      offline_source = File.join(source_path, SOURCE_PART)
      FileUtils.cp_r(@source_part_path, offline_source, preserve: true)
      fail!('offline source copy differs from original stock part hashes') unless inventory_part(offline_source) == @source_inventory
      @offline_source_path = offline_source
    end

    def validate_metadata_path!(path, name)
      full = File.expand_path(path, @native_store)
      real = File.realpath(full)
      root = File.realpath(@native_store)
      fail!("native #{name} metadata path escaped its isolated ClickHouse store") unless real.start_with?(root + File::SEPARATOR)
      fail!("native #{name} metadata path is not a plain canonical SQL file") unless
        File.file?(real) && !File.symlink?(full) && real == full && full.end_with?('.sql')
      real
    end

    def run_helper(action, arguments = [])
      fail!("W290 helper #{action} invocation root exists") if File.exist?(File.join(@root, 'helper', action))
      cell_root = File.join(@root, 'helper', action)
      Dir.mkdir(cell_root, 0o700)
      argv = guarded_argv(@helper, [@catalog_root, action] + arguments)
      result = run_process("helper_#{action}", argv, ''.b, 'Crystal helper', cell_root)
      stdout = result.fetch(:stdout)
      fail!("Crystal helper #{action} must emit one JSON line") unless stdout.lines.size == 1
      JSON.parse(stdout)
    end

    def validate_publish_report!(report)
      fail!('W290 publish helper report/status differs') unless report.is_a?(Hash) &&
        report['format'] == 'materialized_view_projection_transform_w290_helper_v1' &&
        report['action'] == 'publish' && report['status'] == 'ok'
      fail!('W290 source/output counts differ') unless report['source_row_count'] == SOURCE_ROWS.size && report['output_row_count'] == OUTPUT_ROWS.size
      fail!('W290 transformed output differs from independent literal rows') unless report['output_rows'] == json_rows(OUTPUT_ROWS)
      fail!('W290 helper source filter roster differs') unless report['filtered_source_row_ids'] == [7, 8]
      fail!('W290 parent/child grids differ') unless report['parent_mark_rows'] == [2, 2, 2] && report['child_mark_rows'] == [3, 3]
      fail!('W290 output schemas/projection roster differ') unless
        report['parent_columns'] == %w[id score label] && report['projection_columns'] == %w[score id label] && report['projection_name'] == PROJECTION
      expected_compact = File.join(@catalog_root, 'store', COMPACT_TARGET_UUID[0, 3], COMPACT_TARGET_UUID, 'detached', COMPACT_PART)
      expected_wide = File.join(@catalog_root, 'store', WIDE_TARGET_UUID[0, 3], WIDE_TARGET_UUID, 'detached', WIDE_PART)
      fail!('W290 compact transform destination differs') unless File.expand_path(report['compact_parent_path']) == expected_compact
      fail!('W290 wide transform destination differs') unless File.expand_path(report['wide_parent_path']) == expected_wide
      @generated_parts = {
        'compact_parent_wide_child' => {path: expected_compact},
        'wide_parent_compact_child' => {path: expected_wide},
      }
    end

    def snapshot_generated_parts!
      @generated_parts.each do |id, entry|
        inventory = inventory_part(entry.fetch(:path))
        fail!("#{id} generated part omitted the projection directory") unless inventory.fetch(:files).any? { |file| file.fetch(:relative_path).start_with?("#{PROJECTION}.proj/") }
        entry[:inventory] = inventory
      end
    end

    def copy_generated_to_native_detached!
      [['compact_parent_wide_child', 'target_compact', COMPACT_PART], ['wide_parent_compact_child', 'target_wide', WIDE_PART]].each do |id, table, part_name|
        table_path = @native_paths.fetch(table)
        detached = File.join(table_path, 'detached')
        if File.exist?(detached) || File.symlink?(detached)
          fail!("#{table} detached path is unsafe") unless File.directory?(detached) && !File.symlink?(detached) && Dir.children(detached).empty?
        else
          Dir.mkdir(detached, 0o700)
        end
        destination = File.join(detached, part_name)
        fail!("#{table} detached part path is occupied") if File.exist?(destination) || File.symlink?(destination)
        FileUtils.cp_r(@generated_parts.fetch(id).fetch(:path), destination, preserve: true)
        copied = inventory_part(destination)
        fail!("#{id} detached copy changed original file hashes") unless copied == @generated_parts.fetch(id).fetch(:inventory)
        @generated_parts.fetch(id)[:native_detached_path] = destination
        @generated_parts.fetch(id)[:native_detached_inventory] = copied
      end
    end

    def attach_check_and_inventory!
      sql = [
        pin_sql,
        "ALTER TABLE #{DATABASE}.target_compact ATTACH PART '#{COMPACT_PART}';",
        "ALTER TABLE #{DATABASE}.target_wide ATTACH PART '#{WIDE_PART}';",
        *TABLES.map { |table| check_sql(table) },
        schema_sql(TABLES),
        data_path_sql(TABLES),
        part_sql(TABLES),
        projection_part_sql(%w[target_compact target_wide]),
        row_counts_sql(TABLES),
      ].join("\n") + "\n"
      result = run_native('attach_check_metadata', sql.b)
      native = parse_markers(result.fetch(:stdout))
      assert_pin_marker!(native)
      expected_schemas = TABLES.sort.flat_map { |table| COLUMNS.map { |name, type| [table, name, type] } }
      fail!('native attached schema differs') unless native.fetch(:schemas) == expected_schemas
      fail!('native target/source data path roster differs') unless native.fetch(:data_paths).keys.sort == TABLES.sort
      paths = native.fetch(:data_paths).to_h { |table, path| [table, validate_store_path!(path)] }
      fail!('native source/target data paths changed after creation') unless paths == @native_paths
      fail!('native CHECK results differ after ATTACH') unless native.fetch(:checks) == {
        'source' => ["#{SOURCE_PART}\t1\t"],
        'target_compact' => ["#{only_part!(native, 'target_compact').fetch(:name)}\t1\t"],
        'target_wide' => ["#{only_part!(native, 'target_wide').fetch(:name)}\t1\t"],
      }
      fail!('native row counts after ATTACH differ') unless native.fetch(:row_counts) == {
        'source' => SOURCE_ROWS.size.to_s, 'target_compact' => OUTPUT_ROWS.size.to_s, 'target_wide' => OUTPUT_ROWS.size.to_s,
      }
      fail!('native active-part roster differs after ATTACH') unless native.fetch(:parts).keys.sort == TABLES.sort
      source = only_part!(native, 'source')
      fail!('source part changed after ATTACH') unless source.fetch(:name) == SOURCE_PART && source.fetch(:part_type) == 'Wide' &&
        source.fetch(:rows) == '8' && source.fetch(:marks) == '5' && validate_native_part_path!(source.fetch(:path), 'source', SOURCE_PART) == @source_part_path
      expected_part_types = {'target_compact' => ['Compact', 'Wide'], 'target_wide' => ['Wide', 'Compact']}
      expected_marks = {'target_compact' => ['4', '3'], 'target_wide' => ['4', '3']}
      TABLES.drop(1).each do |table|
        part = only_part!(native, table)
        active_name = part.fetch(:name)
        expected_parent, expected_child = expected_part_types.fetch(table)
        parent_marks, child_marks = expected_marks.fetch(table)
        fail!("#{table} native parent layout differs") unless valid_active_part_name?(active_name) &&
          part.fetch(:part_type) == expected_parent && part.fetch(:rows) == '6' && part.fetch(:marks) == parent_marks
        native_part_path = validate_native_part_path!(part.fetch(:path), table, active_name)
        projection = native.fetch(:projection_parts).fetch(table)
        fail!("#{table} native projection part/grid ownership differs") unless projection.fetch(:name) == PROJECTION &&
          projection.fetch(:parent_name) == active_name && projection.fetch(:part_type) == expected_child &&
          projection.fetch(:parent_part_type) == expected_parent && projection.fetch(:active) == '1' &&
          projection.fetch(:rows) == '6' && projection.fetch(:marks) == child_marks &&
          projection.fetch(:parent_rows) == '6' && projection.fetch(:parent_marks) == parent_marks
        child_path = File.expand_path(projection.fetch(:path))
        fail!("#{table} projection child path escaped its parent") unless child_path == File.join(native_part_path, "#{PROJECTION}.proj")
        generated_id = table == 'target_compact' ? 'compact_parent_wide_child' : 'wide_parent_compact_child'
        generated = @generated_parts.fetch(generated_id)
        attached_inventory = inventory_part(native_part_path)
        compare_attach_inventory!(generated.fetch(:inventory), attached_inventory, native_part_path)
        @attached_parts[table] = {name: active_name, path: native_part_path, inventory: attached_inventory,
                                  projection_path: child_path, projection_metadata: projection}
      end
      fail!('source stock file hashes changed during attach/check') unless inventory_part(@source_part_path) == @source_inventory
      {markers: native, parts: @attached_parts}
    end

    def copy_attached_parts_to_catalog!
      {'target_compact' => COMPACT_TARGET_UUID, 'target_wide' => WIDE_TARGET_UUID}.each do |table, uuid|
        attached = @attached_parts.fetch(table)
        destination = File.join(uuid_path(uuid), attached.fetch(:name))
        fail!("#{table} offline reopen candidate path is occupied") if File.exist?(destination) || File.symlink?(destination)
        FileUtils.cp_r(attached.fetch(:path), destination, preserve: true)
        copy_inventory = inventory_part(destination)
        fail!("#{table} offline reopen copy differs from the checked native attachment") unless copy_inventory == attached.fetch(:inventory)
        attached[:catalog_copy] = {path: destination, inventory: copy_inventory, byte_identical_to_native_attachment: true}
      end
    end

    def verify_native_rowbinary!
      @projection_reads = {}
      TABLES.drop(1).each do |table|
        parent_sql = "SELECT id, score, label FROM #{DATABASE}.#{table} ORDER BY id SETTINGS optimize_use_projections=0 FORMAT RowBinary;\n"
        parent = run_native("parent_read_#{table}", parent_sql.b)
        assert_bytes!(parent.fetch(:stdout), rowbinary_rows(OUTPUT_ROWS, %i[id score label]), "#{table} parent read with projections disabled")

        direct_sql = "SELECT score, id, label FROM mergeTreeProjection('#{DATABASE}', '#{table}', '#{PROJECTION}') ORDER BY score FORMAT RowBinary;\n"
        direct = run_native("direct_projection_read_#{table}", direct_sql.b)
        assert_bytes!(direct.fetch(:stdout), rowbinary_rows(PROJECTION_ROWS, %i[score id label]), "#{table} direct projection read")

        forced_sql = "SELECT id, score, label FROM #{DATABASE}.#{table} ORDER BY score SETTINGS force_optimize_projection=1, force_optimize_projection_name='#{PROJECTION}' FORMAT RowBinary;\n"
        forced = run_native("forced_projection_read_#{table}", forced_sql.b)
        assert_bytes!(forced.fetch(:stdout), rowbinary_rows(PROJECTION_ROWS, %i[id score label]), "#{table} forced projection read")

        @projection_reads[table] = {
          parent: {bytes: parent.fetch(:stdout).bytesize, sha256: Digest::SHA256.hexdigest(parent.fetch(:stdout)), literal_exact: true,
                   projection_use_disabled: true},
          direct_projection: {bytes: direct.fetch(:stdout).bytesize, sha256: Digest::SHA256.hexdigest(direct.fetch(:stdout)), literal_exact: true},
          forced_projection: {bytes: forced.fetch(:stdout).bytesize, sha256: Digest::SHA256.hexdigest(forced.fetch(:stdout)), literal_exact: true},
        }
      end
    end

    def verify_projection_plans!
      TABLES.drop(1).to_h do |table|
        sql = "EXPLAIN json=1, description=1, projections=1 SELECT id, score, label FROM #{DATABASE}.#{table} ORDER BY score SETTINGS force_optimize_projection=1, force_optimize_projection_name='#{PROJECTION}' FORMAT JSONEachRow;\n"
        result = run_native("explain_projection_#{table}", sql.b)
        plan = parse_projection_explain!(result.fetch(:stdout), table)
        [table, plan]
      end
    end

    def validate_reopen_report!(report)
      fail!('W290 reopen helper report/status differs') unless report.is_a?(Hash) &&
        report['format'] == 'materialized_view_projection_transform_w290_helper_v1' &&
        report['action'] == 'reopen' && report['status'] == 'ok' && report['catalog_root'] == @catalog_root
      pairs = report.fetch('pairs')
      fail!('W290 reopen pair roster differs') unless pairs.map { |pair| pair.fetch('table') }.sort == %w[target_compact target_wide]
      expected = {
        'target_compact' => ['Compact', 'Wide', [2, 2, 2], [3, 3]],
        'target_wide' => ['Wide', 'Compact', [2, 2, 2], [3, 3]],
      }
      pairs.each do |pair|
        parent, child, parent_grid, child_grid = expected.fetch(pair.fetch('table'))
        attached = @attached_parts.fetch(pair.fetch('table'))
        fail!("#{pair.fetch('table')} catalog reopen format/grid differs") unless pair['parent_format'] == parent &&
          pair['child_format'] == child && pair['parent_mark_rows'] == parent_grid && pair['child_mark_rows'] == child_grid
        fail!("#{pair.fetch('table')} catalog reopened a different native attachment copy") unless
          pair['part_name'] == attached.fetch(:name) && pair['reopen_source'] == 'byte_identical_copy_of_native_attached_part' &&
          File.expand_path(pair.fetch('parent_path')) == attached.fetch(:catalog_copy).fetch(:path) &&
          File.expand_path(pair.fetch('child_path')) == File.join(attached.fetch(:catalog_copy).fetch(:path), "#{PROJECTION}.proj")
        fail!("#{pair.fetch('table')} catalog full rows differ from the independent literals") unless pair['parent_rows'] == json_rows(OUTPUT_ROWS) &&
          pair['projection_rows'] == json_rows(PROJECTION_ROWS)
        fail!("#{pair.fetch('table')} catalog [2,4) windows differ") unless pair['parent_window_rows_2_4'] == json_rows(OUTPUT_ROWS[2, 2]) &&
          pair['child_window_rows_2_4'] == json_rows(PROJECTION_ROWS[2, 2]) && pair['parent_window_mark_rows'] == [2] &&
          pair['child_window_mark_rows'] == [1, 1]
      end
    end

    def validate_end_state!
      @binary_sha_after = sha_file(@binary)
      @helper_sha_after = sha_file(@helper)
      @run_safe_sha_after = sha_file(@run_safe)
      @input_hashes_after = input_hashes
      fail!('pinned ClickHouse runtime changed during witness') unless @binary_sha_after == RUNTIME_PIN.fetch(:sha256) && File.size(@binary) == RUNTIME_PIN.fetch(:bytes)
      fail!('prebuilt Crystal helper changed during witness') unless @helper_sha_after == @helper_sha_before
      fail!('pinned run_safe guard changed during witness') unless @run_safe_sha_after == @run_safe_sha_before
      fail!('W290 script/source inputs changed during witness') unless @input_hashes_after == @input_hashes_before
      fail!('stock source part hashes changed during witness') unless inventory_part(@source_part_path) == @source_inventory
      @generated_parts.each do |id, entry|
        fail!("#{id} generated output hashes changed during witness") unless inventory_part(entry.fetch(:path)) == entry.fetch(:inventory)
      end
      @attached_parts.each do |table, entry|
        generated_id = table == 'target_compact' ? 'compact_parent_wide_child' : 'wide_parent_compact_child'
        compare_attach_inventory!(@generated_parts.fetch(generated_id).fetch(:inventory), inventory_part(entry.fetch(:path)), entry.fetch(:path))
        fail!("#{table} OfflineCatalog copy no longer matches native attachment") unless
          inventory_part(entry.fetch(:catalog_copy).fetch(:path)) == entry.fetch(:inventory)
      end
      @native_metadata.each do |name, entry|
        fail!("native persisted #{name} metadata changed during witness") unless sha_file(entry.fetch(:path)) == entry.fetch(:sha256)
      end
    end

    def run_native(label, input)
      cell_root = File.join(@root, 'native', label)
      Dir.mkdir(cell_root, 0o700)
      argv = guarded_argv(@binary, ['local', '--path', @native_store, '--session_timezone=UTC', '--max_threads=1',
                                    "--max_memory_usage=#{MEMORY_BYTES}", '--multiquery'])
      run_process(label, argv, input, 'ClickHouse local', cell_root)
    end

    def guarded_argv(binary, arguments)
      [@run_safe, binary, PROCESS_TIMEOUT_SECONDS.to_s, (PROCESS_MEMORY_BYTES / (1024 * 1024)).to_s, *arguments]
    end

    def run_process(label, argv, input, process_kind, cell_root)
      stdin_path = File.join(cell_root, 'stdin.bin')
      stdout_path = File.join(cell_root, 'stdout.bin')
      stderr_path = File.join(cell_root, 'stderr.bin')
      write_new(stdin_path, input)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      pid = nil
      stdout_bytes = ''.b
      stderr_bytes = ''.b
      stdout_truncated = false
      stderr_truncated = false
      stdout_error = nil
      stderr_error = nil
      stdin_error = nil
      timed_out = false
      status = nil

      guard_env = {'RUN_SAFE_PASSTHROUGH_STDIO' => '1', 'COGNI_RUN_SAFE_MIN_FREE_PCT' => '50'}
      Open3.popen3(guard_env, *argv, pgroup: true) do |stdin, stdout, stderr, waiter|
        pid = waiter.pid
        stdin.binmode
        stdout.binmode
        stderr.binmode
        stdout_reader = Thread.new { capture_stream(stdout, MAX_CAPTURE_BYTES) }
        stderr_reader = Thread.new { capture_stream(stderr, MAX_CAPTURE_BYTES) }
        stdin_writer = Thread.new do
          begin
            stdin.write(input)
            nil
          rescue IOError, SystemCallError => error
            "#{error.class}: #{error.message}"
          ensure
            stdin.close unless stdin.closed?
          end
        end
        deadline = started + PROCESS_TIMEOUT_SECONDS + 15
        until waiter.join(0.1)
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
            timed_out = true
            stop_process_group(pid)
            break
          end
        end
        status = waiter.value
        stdin_error = stdin_writer.value
        stdout_result = stdout_reader.value
        stderr_result = stderr_reader.value
        stdout_bytes = stdout_result.fetch(:bytes)
        stderr_bytes = stderr_result.fetch(:bytes)
        stdout_truncated = stdout_result.fetch(:truncated)
        stderr_truncated = stderr_result.fetch(:truncated)
        stdout_error = stdout_result.fetch(:error)
        stderr_error = stderr_result.fetch(:error)
      end

      write_new(stdout_path, stdout_bytes)
      write_new(stderr_path, stderr_bytes)
      workload_stderr = extract_run_safe_stderr(stderr_bytes, label)
      write_new(File.join(cell_root, 'workload_stderr.bin'), workload_stderr)
      record = {
        label: label, process_kind: process_kind, argv: argv,
        argv_sha256: Digest::SHA256.hexdigest(JSON.generate(argv)),
        run_safe: {path: @run_safe, sha256: @run_safe_sha_before, passthrough_stdio: true, min_free_percent: 50},
        input_file: stdin_path, input_bytes: input.bytesize, input_sha256: Digest::SHA256.hexdigest(input),
        timeout_seconds: PROCESS_TIMEOUT_SECONDS, termination_grace_seconds: TERMINATION_GRACE_SECONDS,
        run_safe_process_tree_memory_limit_bytes: PROCESS_MEMORY_BYTES,
        sql_max_threads: process_kind == 'ClickHouse local' ? 1 : nil,
        sql_max_memory_usage_bytes: process_kind == 'ClickHouse local' ? MEMORY_BYTES : nil,
        timed_out: timed_out,
        exitstatus: status&.exitstatus, termsig: status&.termsig, stdin_write_error: stdin_error,
        stdout_file: stdout_path, stdout_bytes: stdout_bytes.bytesize, stdout_truncated: stdout_truncated,
        stdout_read_error: stdout_error, stdout_sha256: Digest::SHA256.hexdigest(stdout_bytes),
        stderr_file: stderr_path, stderr_bytes: stderr_bytes.bytesize, stderr_truncated: stderr_truncated,
        stderr_read_error: stderr_error, stderr_sha256: Digest::SHA256.hexdigest(stderr_bytes),
        workload_stderr_file: File.join(cell_root, 'workload_stderr.bin'),
        workload_stderr_bytes: workload_stderr.bytesize, workload_stderr_sha256: Digest::SHA256.hexdigest(workload_stderr),
        elapsed_seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
      }
      write_new(File.join(cell_root, 'invocation.json'), JSON.pretty_generate(record) + "\n")
      @processes << record
      fail!("#{label} parent watchdog exceeded its fallback time bound") if timed_out
      fail!("#{label} process did not exit cleanly") unless status&.success? && status.termsig.nil?
      fail!("#{label} process output capture failed or truncated") if stdin_error || stdout_truncated || stderr_truncated || stdout_error || stderr_error
      fail!("#{label} workload emitted stderr") unless workload_stderr.empty?
      {stdout: stdout_bytes, stderr: stderr_bytes, record: record}
    end

    def extract_run_safe_stderr(bytes, label)
      text = bytes.dup.force_encoding(Encoding::UTF_8)
      return bytes unless text.valid_encoding?
      lines = text.lines(chomp: true)
      ending = lines.rindex { |line| line.match?(/\A\[EXIT: \d+\] after ~\d+s\z/) }
      return bytes unless ending && ending == lines.size - 1
      stderr_marker = lines.index('=== STDERR ===')
      fail!("#{label} run_safe stderr marker occurs after its exit") if stderr_marker && stderr_marker > ending
      guard_lines = stderr_marker ? lines[0...stderr_marker] + [lines.last] : lines
      unexpected = guard_lines.reject do |line|
        line.match?(/\A\[PREFLIGHT\] System memory free \d+% > 50%\z/) ||
          line.match?(/\A\[WAIT\] Host busy before run_safe launch \(\d+\/\d+s\):\z/) ||
          line.match?(/\A\[WARN\] Host busy before run_safe launch:\z/) ||
          line == '=== STDERR ===' || line.match?(/\A\[EXIT: \d+\] after ~\d+s\z/) ||
          line.match?(/\Abusy total_cpu=/) || line.match?(/\A pid=\d+ cpu=/)
      end
      fail!("#{label} run_safe emitted unexpected guard diagnostics: #{unexpected.inspect}") unless unexpected.empty?
      return ''.b unless stderr_marker
      payload = text.b.split("=== STDERR ===\n", 2).fetch(1)
      suffix = /\[EXIT: \d+\] after ~\d+s\n\z/.match(payload)
      fail!("#{label} run_safe stderr exit suffix is malformed") unless suffix
      payload.byteslice(0, suffix.begin(0))
    end

    def capture_stream(stream, limit)
      bytes = ''.b
      truncated = false
      error = nil
      begin
        loop do
          chunk = stream.readpartial(65_536)
          remaining = limit - bytes.bytesize
          if remaining.positive?
            bytes << chunk.byteslice(0, remaining)
            truncated ||= chunk.bytesize > remaining
          else
            truncated = true
          end
        end
      rescue EOFError
        nil
      rescue IOError, SystemCallError => exception
        error = "#{exception.class}: #{exception.message}"
      ensure
        stream.close rescue nil
      end
      {bytes: bytes, truncated: truncated, error: error}
    end

    def stop_process_group(pid)
      Process.kill('TERM', -pid) rescue nil
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TERMINATION_GRACE_SECONDS
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        break unless process_group_alive?(pid)
        sleep 0.05
      end
      Process.kill('KILL', -pid) rescue nil if process_group_alive?(pid)
    end

    def process_group_alive?(pid)
      Process.kill(0, -pid)
      true
    rescue Errno::ESRCH
      false
    end

    def pin_sql
      "SELECT '__W290_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;"
    end

    def assert_pin!(stdout)
      lines = stdout.dup.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
      expected = "__W290_PIN__\t#{VERSION}\t#{BUILD}"
      fail!("native runtime pin differs: #{lines.inspect}") unless lines == [expected]
    end

    def check_sql(table)
      [
        "SELECT '__W290_CHECK_BEGIN__', '#{table}' FORMAT TSVRaw;",
        "CHECK TABLE #{DATABASE}.#{table} FORMAT TSV;",
        "SELECT '__W290_CHECK_END__', '#{table}' FORMAT TSVRaw;",
      ].join("\n")
    end

    def part_sql(tables)
      list = tables.map { |table| "'#{table}'" }.join(',')
      "SELECT '__W290_PART__', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='#{DATABASE}' AND table IN (#{list}) AND active ORDER BY table,name FORMAT TSVRaw;"
    end

    def projection_part_sql(tables)
      list = tables.map { |table| "'#{table}'" }.join(',')
      "SELECT '__W290_PROJECTION_PART__', table, name, parent_name, part_type, parent_part_type, toString(active), toString(marks), toString(rows), toString(parent_marks), toString(parent_rows), path FROM system.projection_parts WHERE database='#{DATABASE}' AND table IN (#{list}) AND active ORDER BY table,name FORMAT TSVRaw;"
    end

    def schema_sql(tables)
      list = tables.map { |table| "'#{table}'" }.join(',')
      "SELECT '__W290_SCHEMA__', table, name, type FROM system.columns WHERE database='#{DATABASE}' AND table IN (#{list}) ORDER BY table,position FORMAT TSVRaw;"
    end

    def data_path_sql(tables)
      list = tables.map { |table| "'#{table}'" }.join(',')
      "SELECT '__W290_DATA_PATH__', name, arrayElement(data_paths,1) FROM system.tables WHERE database='#{DATABASE}' AND name IN (#{list}) ORDER BY name FORMAT TSVRaw;"
    end

    def metadata_path_sql(tables)
      list = tables.map { |table| "'#{table}'" }.join(',')
      "SELECT '__W290_META_PATH__', name, base64Encode(metadata_path) FROM system.tables WHERE database='#{DATABASE}' AND name IN (#{list}) ORDER BY name FORMAT TSVRaw;"
    end

    def row_counts_sql(tables)
      tables.map { |table| "SELECT '__W290_ROWCOUNT__', '#{table}', toString(count()) FROM #{DATABASE}.#{table} FORMAT TSVRaw;" }.join("\n")
    end

    def parse_markers(stdout)
      lines = stdout.dup.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
      fail!('native marker output is not valid UTF-8') unless lines.all?(&:valid_encoding?)
      known = %w[__W290_PIN__ __W290_SCHEMA__ __W290_DATA_PATH__ __W290_META_PATH__ __W290_PART__ __W290_PROJECTION_PART__ __W290_ROWCOUNT__ __W290_CHECK_BEGIN__ __W290_CHECK_END__]
      unknown = lines.select { |line| line.start_with?('__W290_') }.map { |line| line.split("\t", 2).first }.uniq - known
      fail!("unknown native marker tags: #{unknown.inspect}") unless unknown.empty?
      marker_rows = lambda do |tag, width|
        lines.select { |line| line.start_with?("#{tag}\t") }.map do |line|
          fields = line.split("\t", -1)
          fail!("#{tag} marker width differs") unless fields.size == width
          fields
        end
      end
      pin_rows = marker_rows.call('__W290_PIN__', 3)
      schemas = marker_rows.call('__W290_SCHEMA__', 4).map { |row| row.drop(1) }
      paths = marker_rows.call('__W290_DATA_PATH__', 3).map { |row| [row.fetch(1), row.fetch(2)] }
      fail!('duplicate data path markers') unless paths.map(&:first).uniq.size == paths.size
      metadata_paths = marker_rows.call('__W290_META_PATH__', 3).map do |row|
        [row.fetch(1), Base64.strict_decode64(row.fetch(2))]
      rescue ArgumentError
        fail!('native metadata path marker is invalid Base64')
      end
      fail!('duplicate native metadata path markers') unless metadata_paths.map(&:first).uniq.size == metadata_paths.size
      parts = marker_rows.call('__W290_PART__', 7).group_by { |row| row.fetch(1) }.transform_values do |rows|
        rows.map do |row|
          {name: row.fetch(2), path: row.fetch(3), part_type: row.fetch(4), rows: row.fetch(5), marks: row.fetch(6)}
        end
      end
      projections = marker_rows.call('__W290_PROJECTION_PART__', 12).to_h do |row|
        [row.fetch(1), {name: row.fetch(2), parent_name: row.fetch(3), part_type: row.fetch(4),
                        parent_part_type: row.fetch(5), active: row.fetch(6), marks: row.fetch(7),
                        rows: row.fetch(8), parent_marks: row.fetch(9), parent_rows: row.fetch(10), path: row.fetch(11)}]
      end
      counts = marker_rows.call('__W290_ROWCOUNT__', 3).to_h { |row| [row.fetch(1), row.fetch(2)] }
      fail!('duplicate native row-count markers') unless counts.size == marker_rows.call('__W290_ROWCOUNT__', 3).size
      checks = parse_checks(lines)
      {pin: pin_rows, schemas: schemas, data_paths: paths.to_h, metadata_paths: metadata_paths.to_h, parts: parts,
       projection_parts: projections, row_counts: counts, checks: checks}
    end

    def parse_checks(lines)
      checks = {}
      active = nil
      lines.each do |line|
        if line.start_with?("__W290_CHECK_BEGIN__\t")
          fields = line.split("\t", -1)
          fail!('malformed, nested, or duplicate CHECK start') unless fields.size == 2 && active.nil? && !checks.key?(fields[1])
          active = fields[1]
          checks[active] = []
        elsif line.start_with?("__W290_CHECK_END__\t")
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

    def assert_pin_marker!(native)
      fail!('native runtime pin differs') unless native.fetch(:pin) == [["__W290_PIN__", VERSION, BUILD]]
    end

    def only_part!(native, table)
      parts = native.fetch(:parts).fetch(table, [])
      fail!("#{table} does not have exactly one active part") unless parts.size == 1
      parts.first
    end

    def parse_projection_explain!(stdout, table)
      lines = stdout.dup.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
      fail!("#{table} EXPLAIN output is not valid UTF-8") unless lines.all?(&:valid_encoding?)
      rows = lines.filter_map do |line|
        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end
      fail!("#{table} EXPLAIN output has no JSON rows") if rows.empty?
      objects = []
      walk_json(rows) { |object| objects << object if object.is_a?(Hash) }
      readers = objects.select { |object| object['Node Type'] == 'ReadFromMergeTree' }
      fail!("#{table} EXPLAIN did not expose one MergeTree read step") unless readers.size == 1
      reader = readers.first
      fail!("#{table} EXPLAIN read did not select #{PROJECTION}") unless reader['Description'] == PROJECTION
      node_id = reader['Node Id']
      fail!("#{table} EXPLAIN read node id is absent") unless node_id.is_a?(String) && !node_id.empty?
      {read_step_count: 1, node_type: reader['Node Type'], node_id: node_id, description: reader['Description']}
    end

    def walk_json(value, &block)
      yield value
      case value
      when Hash
        value.each_value { |child| walk_json(child, &block) }
      when Array
        value.each { |child| walk_json(child, &block) }
      when String
        begin
          parsed = JSON.parse(value)
          walk_json(parsed, &block) if parsed.is_a?(Hash) || parsed.is_a?(Array)
        rescue JSON::ParserError
          nil
        end
      end
    end

    def compare_attach_inventory!(generated, attached, attached_root)
      old_files = generated.fetch(:files).to_h { |entry| [entry.fetch(:relative_path), entry] }
      new_files = attached.fetch(:files).to_h { |entry| [entry.fetch(:relative_path), entry] }
      fail!('ATTACH removed or changed an original generated file hash') unless old_files.all? { |path, entry| new_files[path] == entry }
      extras = new_files.keys - old_files.keys
      if extras.any?
        fail!('ATTACH added files other than the exact invalidation sidecar') unless extras == [ATTACH_SIDECAR]
        sidecar = File.join(attached_root, ATTACH_SIDECAR)
        bytes = File.binread(sidecar)
        fail!('ATTACH invalidation sidecar bytes/hash differ') unless bytes == ATTACH_SIDECAR_BYTES && Digest::SHA256.hexdigest(bytes) == ATTACH_SIDECAR_SHA256
      end
      fail!('ATTACH part file count differs') unless new_files.size == old_files.size + extras.size
      {generated_files_preserved: true, added_files: extras}
    end

    def validate_store_path!(path)
      full = File.expand_path(path)
      store = File.realpath(@native_store)
      real = File.realpath(full)
      fail!('native data path escaped the isolated ClickHouse store') unless real.start_with?(store + File::SEPARATOR)
      fail!('native data path is not a plain canonical directory') unless File.directory?(real) && !File.symlink?(full) && real == full
      real
    end

    def validate_native_part_path!(path, table, name)
      full = File.expand_path(path)
      real = File.realpath(full)
      table_path = File.realpath(@native_paths.fetch(table))
      fail!("native #{table} part escaped its data path") unless real == File.join(table_path, name)
      fail!('native part is not a plain canonical directory') unless File.directory?(real) && !File.symlink?(full)
      real
    end

    def valid_active_part_name?(name)
      name.match?(/\Aall_[0-9]+_[0-9]+_[0-9]+\z/)
    end

    def inventory_part(path)
      root = File.realpath(path)
      files = []
      total = 0
      Find.find(root) do |full|
        next if full == root
        stat = File.lstat(full)
        fail!("symlink in part tree: #{full}") if stat.symlink?
        if stat.file?
          relative = full.delete_prefix(root + File::SEPARATOR)
          total += stat.size
          fail!('part tree exceeds file count or byte bound') if files.size >= MAX_PART_FILES || total > MAX_PART_BYTES
          files << {relative_path: relative, bytes: stat.size, sha256: sha_file(full)}
        elsif !stat.directory?
          fail!("unsupported filesystem entry in part tree: #{full}")
        end
      end
      {file_count: files.size, total_bytes: total, files: files.sort_by { |entry| entry.fetch(:relative_path) }}
    end

    def rowbinary_rows(rows, columns)
      rows.map do |row|
        columns.map do |column|
          case column
          when :id, :score
            [row.fetch(column)].pack('Q<')
          when :label
            bytes = row.fetch(:label).b
            encode_varuint(bytes.bytesize) + bytes
          else
            fail!("RowBinary oracle has no encoder for #{column.inspect}")
          end
        end.join.b
      end.join.b
    end

    def encode_varuint(value)
      remaining = Integer(value)
      fail!('negative RowBinary VarUInt') if remaining.negative?
      bytes = ''.b
      loop do
        byte = remaining & 0x7f
        remaining >>= 7
        if remaining.zero?
          bytes << byte
          break
        end
        bytes << (byte | 0x80)
      end
      bytes
    end

    def assert_bytes!(actual, expected, label)
      fail!("#{label} differs from independently constructed literal RowBinary") unless actual == expected
    end

    def json_rows(rows)
      rows.map { |row| [row.fetch(:id), row.fetch(:score), row.fetch(:label)] }
    end

    def uuid_path(uuid)
      File.join(@catalog_root, 'store', uuid[0, 3], uuid)
    end

    def write_summary(data)
      summary = {
        format: FORMAT, status: data[:status], fatal_error: data[:fatal_error], helper_mode: @helper_mode,
        runtime: {path: @binary || @binary_argument, sha256_expected: RUNTIME_PIN.fetch(:sha256),
                  sha256_before: @binary_sha_before, sha256_after: @binary_sha_after,
                  bytes_expected: RUNTIME_PIN.fetch(:bytes), version: VERSION, build: BUILD},
        helper: {path: @helper || @helper_argument, sha256_before: @helper_sha_before, sha256_after: @helper_sha_after},
        run_safe: {path: @run_safe || @run_safe_argument, sha256_expected: RUN_SAFE_SHA256,
                   sha256_before: @run_safe_sha_before, sha256_after: @run_safe_sha_after},
        source_revision: @source_revision, input_sha256_before: @input_hashes_before, input_sha256_after: @input_hashes_after,
        bounds: {run_safe_process_timeout_seconds: PROCESS_TIMEOUT_SECONDS, run_safe_process_tree_memory_bytes: PROCESS_MEMORY_BYTES,
                 run_safe_min_free_percent: 50, fallback_watchdog_seconds: PROCESS_TIMEOUT_SECONDS + 15,
                 sql_max_threads: 1, sql_max_memory_usage_bytes: MEMORY_BYTES, kill_grace_seconds: TERMINATION_GRACE_SECONDS},
        evidence_root: @root, process_records: @processes,
      }.merge(data.reject { |key, _| %i[status fatal_error].include?(key) })
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n") if @root && !File.exist?(File.join(@root, 'summary.json'))
      write_new(File.join(@root, 'summary.md'), [
        '# W290 materialized-view projection transform native witness', '',
        "Status: `#{summary[:status]}`", '',
        'Scope: eight pinned stock source rows inserted before two materialized views were created; caller transforms filter rows 7 and 8, map/rekey the rest, and publish Compact-parent/Wide-child plus Wide-parent/Compact-child parts with independent [2,2,2] and [3,3] grids. Native targets use a simple by_score projection with projection index_granularity=3. The witness checks native ATTACH/CHECK, source and generated file hashes, parent/direct/forced projection RowBinary reads, selected EXPLAIN plans, and fresh OfflineCatalog full/window reads.', '',
        "Runtime: #{VERSION} / #{BUILD} / SHA256 `#{RUNTIME_PIN.fetch(:sha256)}`", '',
        "Evidence root: `#{@root}`", '',
      ].join("\n") + "\n") if @root && !File.exist?(File.join(@root, 'summary.md'))
      summary
    end

    def input_manifest
      {
        format: FORMAT, status: 'execution_inputs_pinned_before_capture',
        repository: REPO_ROOT, repository_revision: git_revision, helper_mode: @helper_mode,
        helper_path: @helper, helper_sha256: @helper_sha_before,
        run_safe_path: @run_safe, run_safe_sha256: @run_safe_sha_before,
        clickhouse_path: @binary, clickhouse_runtime: RUNTIME_PIN,
        source_rows: SOURCE_ROWS, expected_output_rows: OUTPUT_ROWS,
        source_rowbinary_sha256: Digest::SHA256.hexdigest(rowbinary_rows(SOURCE_ROWS, %i[id score label])),
        expected_parent_rowbinary_sha256: Digest::SHA256.hexdigest(rowbinary_rows(OUTPUT_ROWS, %i[id score label])),
        expected_projection_rowbinary_sha256: Digest::SHA256.hexdigest(rowbinary_rows(PROJECTION_ROWS, %i[score id label])),
        runner_inputs_sha256: @input_hashes_before,
        limits: {run_safe_process_timeout_seconds: PROCESS_TIMEOUT_SECONDS, run_safe_process_tree_memory_bytes: PROCESS_MEMORY_BYTES,
                 run_safe_min_free_percent: 50, fallback_watchdog_seconds: PROCESS_TIMEOUT_SECONDS + 15,
                 sql_threads: 1, sql_memory_bytes: MEMORY_BYTES, termination_grace_seconds: TERMINATION_GRACE_SECONDS},
      }
    end

    def input_hashes
      source_root = File.join(REPO_ROOT, 'src', 'crystal_click')
      source_files = Dir.glob(File.join(source_root, '**', '*.cr')).map do |path|
        path.delete_prefix(REPO_ROOT + File::SEPARATOR)
      end
      source_files << 'src/crystal_click.cr'
      (SCRIPT_INPUTS + source_files).uniq.sort.to_h do |relative|
        path = File.join(REPO_ROOT, relative)
        fail!("missing or symlinked W290 input: #{relative}") unless File.file?(path) && !File.symlink?(path)
        [relative, sha_file(path)]
      end
    end

    def git_revision
      stdout, stderr, status = Open3.capture3({'GIT_NO_LAZY_FETCH' => '1'}, 'git', '-C', REPO_ROOT, 'rev-parse', 'HEAD')
      fail!('cannot capture crystal-click source revision') unless status.success? && stderr.empty?
      stdout.strip
    end

    def write_new(path, bytes)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(bytes) }
    end

    def sha_file(path)
      Digest::SHA256.file(path).hexdigest
    end

    def fail!(message)
      raise Error, "W290 projection transform witness: #{message}"
    end
  end

  def self.run(argv = ARGV)
    options = {binary: BINARY, helper: nil, run_safe: nil, evidence_root: nil, helper_mode: nil}
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: ruby scripts/verify_materialized_view_projection_transform_w290.rb --crystal-helper PATH --helper-mode debug|release --evidence-root NEW_PATH --run-safe PINNED_PATH [--clickhouse PINNED_PATH]'
      opts.on('--clickhouse PATH') { |value| options[:binary] = value }
      opts.on('--run-safe PATH') { |value| options[:run_safe] = value }
      opts.on('--crystal-helper PATH') { |value| options[:helper] = value }
      opts.on('--helper-mode MODE') { |value| options[:helper_mode] = value }
      opts.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
    end
    parser.parse!(argv)
    raise OptionParser::MissingArgument, '--crystal-helper' unless options[:helper]
    raise OptionParser::MissingArgument, '--run-safe' unless options[:run_safe]
    raise OptionParser::MissingArgument, '--evidence-root' unless options[:evidence_root]
    raise OptionParser::MissingArgument, '--helper-mode debug|release' unless %w[debug release].include?(options[:helper_mode])
    raise OptionParser::InvalidArgument, 'unexpected positional arguments' unless argv.empty?
    exit(Driver.new(options).run ? 0 : 1)
  rescue OptionParser::ParseError, ArgumentError => error
    warn "W290 usage error: #{error.message}"
    warn parser
    exit(2)
  end
end

VerifyMaterializedViewProjectionTransformW290.run if $PROGRAM_NAME == __FILE__
