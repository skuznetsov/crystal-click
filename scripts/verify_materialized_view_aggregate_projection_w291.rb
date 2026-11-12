#!/usr/bin/env ruby
# Bounded W291 stock-native -> caller transform -> aggregate projection witness.
# It consumes a prebuilt helper only; Crystal builds remain caller-owned.

require 'base64'
require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'open3'
require 'optparse'

module VerifyMaterializedViewAggregateProjectionW291
  extend self

  REPO_ROOT = File.expand_path('..', __dir__).freeze
  FORMAT = 'materialized_view_aggregate_projection_w291_native_v1'.freeze
  BINARY = '/opt/mldata_ssd/cache/crystal-click-w283.PDWAiK/recovery/runtime/clickhouse'.freeze
  RUNTIME_PIN = {
    sha256: '5bb43958f4c0806cc363b84b9858e7206e56ac80263a24acc704271322e531ae'.freeze,
    bytes: 919_123_095,
    version: '26.10.1.1201'.freeze,
    build: 'd9bcb5ab007f0f6299f7f973f2642245bab3d028'.freeze,
  }.freeze
  RUN_SAFE_SHA256 = 'fbfa0fd9d717eb24c1a3f829d464188110e505c7ae311eee2e95cbe7cefab011'.freeze
  DATABASE = 'lab'.freeze
  DATABASE_UUID = 'f2910000-7b7f-4e2f-9e44-dc13a87b8801'.freeze
  SOURCE_UUID = 'f2910000-7b7f-4e2f-9e44-dc13a87b8802'.freeze
  COMPACT_TARGET_UUID = 'f2910000-7b7f-4e2f-9e44-dc13a87b8805'.freeze
  WIDE_TARGET_UUID = 'f2910000-7b7f-4e2f-9e44-dc13a87b8806'.freeze
  COMPACT_VIEW_UUID = 'f2910000-7b7f-4e2f-9e44-dc13a87b8807'.freeze
  WIDE_VIEW_UUID = 'f2910000-7b7f-4e2f-9e44-dc13a87b8808'.freeze
  SOURCE_PART = 'all_1_1_0'.freeze
  COMPACT_PART = 'all_9_9_0'.freeze
  WIDE_PART = 'all_10_10_0'.freeze
  PROJECTION = 'by_group'.freeze
  SOURCE_ROWS = 133
  COMPACT_ROWS = 6
  WIDE_ROWS = 131
  PROJECTION_COLUMNS = [['group_key', 'UInt64'], ['count()', 'AggregateFunction(count)']].freeze
  COMPACT_EXPECTED_CHILD_ROW_BINARY_HEX = '4d0000000000000003750000000000000002290100000000000001'.freeze
  WIDE_EXPECTED_CHILD_ROW_BINARY_HEX = '4d000000000000008001750000000000000002290100000000000001'.freeze
  COMPACT_TARGET_SETTINGS = 'index_granularity=3, min_rows_for_wide_part=0, min_bytes_for_wide_part=0'.freeze
  WIDE_TARGET_SETTINGS = 'index_granularity=4, min_rows_for_wide_part=0, min_bytes_for_wide_part=0'.freeze
  MEMORY_BYTES = 536_870_912
  PROCESS_MEMORY_BYTES = 2 * 1024 * 1024 * 1024
  PROCESS_TIMEOUT_SECONDS = 90
  MAX_CAPTURE_BYTES = 16 * 1024 * 1024
  MAX_PART_FILES = 256
  MAX_PART_BYTES = 16 * 1024 * 1024
  ATTACH_SIDECAR = 'invalidated_system_columns.txt'.freeze
  ATTACH_SIDECAR_BYTES = "_block_offset\n_block_number\n".b.freeze
  ATTACH_SIDECAR_SHA256 = '7409424ab45090c1261e622f7423393905102e7e8cba36a6db88eb513ce1e06c'.freeze
  INPUT_FILES = %w[
    scripts/verify_materialized_view_aggregate_projection_w291.rb
    scripts/check_materialized_view_aggregate_projection_w291.cr
  ].freeze

  class Error < StandardError; end

  class Driver
    def initialize(options)
      @root_argument = options.fetch(:evidence_root)
      @binary_argument = options.fetch(:binary)
      @helper_argument = options.fetch(:helper)
      @run_safe_argument = options.fetch(:run_safe)
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
      @process_records = []
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
      source_state = verify_source!
      create_targets_and_views!
      catalog_state = build_offline_catalog!
      publish_report = run_helper('publish')
      @helper_reports['publish'] = publish_report
      validate_publish_report!(publish_report)
      snapshot_generated_parts!
      copy_generated_to_native_detached!
      attach_state = attach_check_and_inventory!
      verify_native_grouped_reads!
      verify_native_direct_projection_states!
      verify_native_forced_explains!
      copy_attached_parts_to_catalog!
      part_names = %w[target_compact target_wide].map { |table| @attached_parts.fetch(table).fetch(:parent_name) }
      reopen_report = run_helper('reopen', part_names)
      @helper_reports['reopen'] = reopen_report
      validate_reopen_report!(reopen_report)
      validate_end_state!

      write_summary(
        status: 'aggregate_count_projection_parts_attached_checked_and_reopened',
        source: source_state,
        catalog: catalog_state,
        attached_native: attach_state,
        generated_parts: @generated_parts,
        attached_parts: @attached_parts,
        helper_reports: @helper_reports,
        native_paths: @native_paths,
        native_metadata: @native_metadata,
        grouped_reads: @grouped_reads,
        direct_projection_states: @direct_projection_states,
        forced_explains: @forced_explains,
        process_records: @process_records,
      )
      puts "W291 aggregate projection witness passed; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      @binary_sha_after = sha_file(@binary_argument) rescue nil
      @helper_sha_after = sha_file(@helper_argument) rescue nil
      @run_safe_sha_after = sha_file(@run_safe_argument) rescue nil
      @input_hashes_after = input_hashes rescue nil
      write_summary(status: 'runner_failure_or_observations_differ', fatal_error: @fatal_error) rescue nil
      warn "W291 probe failure (process failure is not native format evidence): #{@fatal_error}"
      false
    end

    private

    def prepare!
      @root = validate_evidence_root(@root_argument)
      @binary = validate_runtime!(@binary_argument)
      @helper = validate_helper!(@helper_argument)
      @run_safe = validate_run_safe!(@run_safe_argument)
      @binary_sha_before = sha_file(@binary)
      @helper_sha_before = sha_file(@helper)
      @run_safe_sha_before = sha_file(@run_safe)
      @input_hashes_before = input_hashes
      @source_revision = git_revision
      %w[native catalog helper tmp].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      @native_store = File.join(@root, 'native', 'store')
      @catalog_root = File.join(@root, 'catalog', 'offline_catalog')
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
            source_id UInt64,
            source_group UInt64,
            payload String
        ) ENGINE = MergeTree ORDER BY source_id SETTINGS index_granularity=2, min_rows_for_wide_part=0, min_bytes_for_wide_part=0;
        SELECT version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;
      SQL
      result = run_native('create_source', sql.b)
      expected_pin = "#{RUNTIME_PIN.fetch(:version)}\t#{RUNTIME_PIN.fetch(:build)}\n".b
      assert_bytes!(result.fetch(:stdout), expected_pin, 'pinned native version/build')
    end

    def insert_source_rows!
      input = "INSERT INTO #{DATABASE}.source FORMAT RowBinary\n".b + source_rowbinary
      result = run_native('insert_source', input)
      fail!('ClickHouse RowBinary INSERT emitted unexpected stdout') unless result.fetch(:stdout).empty?
    end

    def verify_source!
      check = native_query('source_check', "CHECK TABLE #{DATABASE}.source FORMAT TSV;")
      assert_bytes!(check, "#{SOURCE_PART}\t1\t\n".b, 'stock source CHECK TABLE')
      part = native_query('source_part', "SELECT name, part_type, toString(rows), toString(marks), path FROM system.parts WHERE database='#{DATABASE}' AND table='source' AND active FORMAT TSVRaw;")
      fields = one_tsv_row(part, 5, 'source active part')
      fail!('stock source part identity/type/row count differs') unless fields[0] == SOURCE_PART && fields[1] == 'Wide' && fields[2] == SOURCE_ROWS.to_s
      data_path = native_query('source_data_path', "SELECT data_paths[1] FROM system.tables WHERE database='#{DATABASE}' AND name='source' FORMAT TSVRaw;").strip
      @native_paths['source'] = validate_store_path!(data_path)
      @source_part_path = validate_native_part_path!(fields[4], 'source', SOURCE_PART)
      @source_inventory = inventory_part(@source_part_path)
      fail!('source part path is outside its recorded data path') unless @source_part_path == File.join(@native_paths.fetch('source'), SOURCE_PART)
      {part_name: SOURCE_PART, part_type: fields[1], row_count: fields[2].to_i, marks: fields[3].to_i,
       check: check, path: @source_part_path, inventory: @source_inventory}
    end

    def create_targets_and_views!
      compact_projection = 'PROJECTION by_group (SELECT group_key, count() GROUP BY group_key)'
      wide_projection = 'PROJECTION by_group (SELECT count() AS n GROUP BY group_key)'
      sql = <<~SQL
        CREATE TABLE #{DATABASE}.target_compact UUID '#{COMPACT_TARGET_UUID}'
        (
            parent_id UInt64,
            group_key UInt64,
            payload String,
            #{compact_projection}
        ) ENGINE = MergeTree ORDER BY parent_id SETTINGS #{COMPACT_TARGET_SETTINGS};
        CREATE TABLE #{DATABASE}.target_wide UUID '#{WIDE_TARGET_UUID}'
        (
            parent_id UInt64,
            group_key UInt64,
            payload String,
            #{wide_projection}
        ) ENGINE = MergeTree ORDER BY parent_id SETTINGS #{WIDE_TARGET_SETTINGS};
        CREATE MATERIALIZED VIEW #{DATABASE}.view_compact UUID '#{COMPACT_VIEW_UUID}' TO #{DATABASE}.target_compact
        (parent_id UInt64, group_key UInt64, payload String)
        AS SELECT source_id + 1000 AS parent_id, source_group * 10 + 7 AS group_key, concat(payload, '!') AS payload
        FROM #{DATABASE}.source WHERE source_id <= 6;
        CREATE MATERIALIZED VIEW #{DATABASE}.view_wide UUID '#{WIDE_VIEW_UUID}' TO #{DATABASE}.target_wide
        (parent_id UInt64, group_key UInt64, payload String)
        AS SELECT source_id + 1000 AS parent_id, source_group * 10 + 7 AS group_key, concat(payload, '!') AS payload
        FROM #{DATABASE}.source WHERE source_id <= 131;
      SQL
      run_native('create_targets_and_views', sql.b)
      %w[target_compact target_wide].each do |table|
        count = native_query("empty_#{table}", "SELECT toString(count()) FROM #{DATABASE}.#{table} FORMAT TSVRaw;").strip
        fail!("native MV target #{table} is not empty") unless count == '0'
        active = native_query("empty_parts_#{table}", "SELECT toString(count()) FROM system.parts WHERE database='#{DATABASE}' AND table='#{table}' AND active FORMAT TSVRaw;").strip
        fail!("native MV target #{table} unexpectedly has active parts") unless active == '0'
      end

      path_rows = native_query('target_data_paths', "SELECT name, arrayElement(data_paths,1) FROM system.tables WHERE database='#{DATABASE}' AND name IN ('target_compact','target_wide') ORDER BY name FORMAT TSVRaw;").lines(chomp: true)
      fail!('native target data path roster differs') unless path_rows.size == 2
      path_rows.each do |line|
        name, path = line.split("\t", -1)
        fail!('native target data path row is malformed') unless path
        @native_paths[name] = validate_store_path!(path)
      end
      fail!('native target data path names differ') unless @native_paths.keys.sort == %w[source target_compact target_wide]

      metadata_rows = native_query('native_metadata_paths', "SELECT name, base64Encode(metadata_path) FROM system.tables WHERE database='#{DATABASE}' AND name IN ('source','target_compact','target_wide','view_compact','view_wide') ORDER BY name FORMAT TSVRaw;").lines(chomp: true)
      fail!('native metadata path roster differs') unless metadata_rows.size == 5
      @native_metadata_paths = metadata_rows.to_h do |line|
        name, encoded = line.split("\t", -1)
        fail!('native metadata path row is malformed') unless encoded
        [name, Base64.strict_decode64(encoded)]
      rescue ArgumentError
        fail!('native metadata path marker is invalid Base64')
      end
    end

    def build_offline_catalog!
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
        path = validate_metadata_path!(@native_metadata_paths.fetch(name), name)
        ddl = File.binread(path)
        fail!("native persisted #{name} metadata exceeds the OfflineCatalog DDL bound") if ddl.bytesize > 1_048_576
        fail!("native persisted #{name} metadata is not UTF-8") unless ddl.dup.force_encoding(Encoding::UTF_8).valid_encoding?
        header = /\A\s*ATTACH\s+#{Regexp.escape(kind)}\s+_\s+UUID\s+'#{Regexp.escape(uuid)}'/im
        fail!("native persisted #{name} metadata identity differs") unless header.match?(ddl)
        write_new(File.join(database_path, "#{name}.sql"), ddl)
        @native_metadata[name] = {path: path, bytes: ddl.bytesize, sha256: Digest::SHA256.hexdigest(ddl)}
      end
      offline_source = File.join(source_path, SOURCE_PART)
      copy_tree(@source_part_path, offline_source)
      copy_inventory = inventory_part(offline_source)
      fail!('offline source copy differs from original stock part hashes') unless copy_inventory == @source_inventory
      {root: @catalog_root, source_copy: offline_source, source_inventory: copy_inventory}
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
      cell_root = File.join(@root, 'helper', action)
      Dir.mkdir(cell_root, 0o700)
      result = run_process("helper_#{action}", @helper, [@catalog_root, action, *arguments], ''.b, 'Crystal helper', cell_root)
      stdout = result.fetch(:stdout)
      fail!("Crystal helper #{action} must emit one JSON line") unless stdout.lines.size == 1
      JSON.parse(stdout)
    rescue JSON::ParserError => error
      fail!("Crystal helper #{action} emitted malformed JSON: #{error.message}")
    end

    def validate_publish_report!(report)
      fail!('W291 publish helper report/status differs') unless report.is_a?(Hash) &&
        report['format'] == 'materialized_view_aggregate_projection_w291_helper_v1' &&
        report['action'] == 'publish' && report['status'] == 'ok'
      fail!('W291 source/parent row counts differ') unless report['source_row_count'] == SOURCE_ROWS &&
        report['compact_parent_row_count'] == COMPACT_ROWS && report['wide_parent_row_count'] == WIDE_ROWS
      fail!('W291 compact transformed parent rows differ') unless report['compact_parent_rows'] == expected_parent_rows(COMPACT_ROWS)
      fail!('W291 wide transformed parent rows differ') unless report['wide_parent_rows'] == expected_parent_rows(WIDE_ROWS)
      fail!('W291 compact grouped counts differ') unless report['compact_child_rows'] == expected_count_rows(COMPACT_ROWS)
      fail!('W291 wide grouped counts differ') unless report['wide_child_rows'] == expected_count_rows(WIDE_ROWS)
      fail!('W291 parent/child mark schedules differ') unless report['compact_parent_mark_rows'] == [3, 3] &&
        report['wide_parent_mark_rows'] == mark_rows(WIDE_ROWS, 4) && report['child_mark_rows'] == [2, 1]
      fail!('W291 transformed column/projection identities differ') unless report['parent_columns'] == %w[parent_id group_key payload] &&
        report['projection_name'] == PROJECTION && report['projection_columns'] == %w[group_key count()]
      fail!('W291 physical AggregateFunction state name/type differs') unless
        report['projection_physical_state'] == 'count() AggregateFunction(count)' && report['alias_target_state_name'] == 'count()'
      expected_compact = File.join(@catalog_root, 'store', COMPACT_TARGET_UUID[0, 3], COMPACT_TARGET_UUID, 'detached', COMPACT_PART)
      expected_wide = File.join(@catalog_root, 'store', WIDE_TARGET_UUID[0, 3], WIDE_TARGET_UUID, 'detached', WIDE_PART)
      fail!('W291 Compact transform destination differs') unless File.expand_path(report['compact_parent_path']) == expected_compact
      fail!('W291 Wide transform destination differs') unless File.expand_path(report['wide_parent_path']) == expected_wide
      @generated_parts = {
        'compact_parent_wide_count_child' => {path: expected_compact, target: 'target_compact', part: COMPACT_PART},
        'wide_parent_wide_count_child' => {path: expected_wide, target: 'target_wide', part: WIDE_PART},
      }
    end

    def snapshot_generated_parts!
      @generated_parts.each do |id, entry|
        inventory = inventory_part(entry.fetch(:path))
        fail!("#{id} generated part omitted the aggregate projection directory") unless
          inventory.fetch(:files).any? { |file| file.fetch(:relative_path).start_with?("#{PROJECTION}.proj/") }
        entry[:inventory] = inventory
      end
    end

    def copy_generated_to_native_detached!
      @generated_parts.each do |id, entry|
        table = entry.fetch(:target)
        part_name = entry.fetch(:part)
        table_path = @native_paths.fetch(table)
        detached = File.join(table_path, 'detached')
        if File.exist?(detached) || File.symlink?(detached)
          fail!("#{table} detached path is unsafe") unless File.directory?(detached) && !File.symlink?(detached) && Dir.children(detached).empty?
        else
          Dir.mkdir(detached, 0o700)
        end
        destination = File.join(detached, part_name)
        fail!("#{table} detached part path is occupied") if File.exist?(destination) || File.symlink?(destination)
        copy_tree(entry.fetch(:path), destination)
        copied = inventory_part(destination)
        fail!("#{id} detached copy changed original file hashes") unless copied == entry.fetch(:inventory)
        entry[:native_detached_path] = destination
        entry[:native_detached_inventory] = copied
      end
    end

    def attach_check_and_inventory!
      @generated_parts.each do |id, entry|
        run_native("attach_#{id}", "ALTER TABLE #{DATABASE}.#{entry.fetch(:target)} ATTACH PART '#{entry.fetch(:part)}';\n".b)
        active_name_output = native_query("part_after_attach_#{id}", "SELECT name FROM system.parts WHERE database='#{DATABASE}' AND table='#{entry.fetch(:target)}' AND active FORMAT TSVRaw;")
        active_name = one_tsv_row(active_name_output, 1, "#{entry.fetch(:target)} active part after ATTACH").first
        fail!("#{entry.fetch(:target)} active part name after ATTACH is malformed") unless valid_active_part_name?(active_name)
        check = native_query("check_#{entry.fetch(:target)}", "CHECK TABLE #{DATABASE}.#{entry.fetch(:target)} FORMAT TSV;")
        assert_bytes!(check, "#{active_name}\t1\t\n".b, "#{entry.fetch(:target)} CHECK TABLE after ATTACH")
      end

      parent_rows = native_query('attached_parent_parts', <<~SQL)
        SELECT table, name, part_type, toString(rows), toString(marks), path
        FROM system.parts WHERE database='#{DATABASE}' AND table IN ('target_compact','target_wide') AND active
        ORDER BY table FORMAT TSVRaw;
      SQL
      parent_records = parent_rows.lines(chomp: true).map do |line|
        table, name, format, rows, marks, path = split_tsv(line, 6, 'attached parent part')
        {table: table, name: name, format: format, rows: rows.to_i, marks: marks.to_i, path: path}
      end
      fail!('attached parent part roster differs') unless parent_records.map { |row| row.fetch(:table) } == %w[target_compact target_wide]
      expected_parent = {
        'target_compact' => ['Compact', COMPACT_ROWS, mark_rows(COMPACT_ROWS, 3).size + 1],
        'target_wide' => ['Wide', WIDE_ROWS, mark_rows(WIDE_ROWS, 4).size + 1],
      }
      parent_records.each do |record|
        format, rows, marks = expected_parent.fetch(record.fetch(:table))
        fail!("#{record.fetch(:table)} attached parent axes differ") unless valid_active_part_name?(record.fetch(:name)) &&
          record.fetch(:format) == format && record.fetch(:rows) == rows && record.fetch(:marks) == marks
        record[:path] = validate_native_part_path!(record.fetch(:path), record.fetch(:table), record.fetch(:name))
      end

      projection_rows = native_query('attached_projection_parts', <<~SQL)
        SELECT table, name, parent_name, part_type, parent_part_type, toString(active),
               toString(rows), toString(marks), toString(parent_rows), toString(parent_marks), path
        FROM system.projection_parts WHERE database='#{DATABASE}' AND table IN ('target_compact','target_wide') AND active
        ORDER BY table FORMAT TSVRaw;
      SQL
      projection_records = projection_rows.lines(chomp: true).map do |line|
        table, name, parent_name, child_type, parent_type, active, rows, marks, parent_rows, parent_marks, path = split_tsv(line, 11, 'attached projection part')
        {table: table, name: name, parent_name: parent_name, child_type: child_type, parent_type: parent_type,
         active: active, rows: rows.to_i, marks: marks.to_i, parent_rows: parent_rows.to_i,
         parent_marks: parent_marks.to_i, path: path}
      end
      fail!('attached aggregate projection child roster differs') unless projection_records.map { |row| row.fetch(:table) } == %w[target_compact target_wide]
      projection_records.each do |record|
        parent = parent_records.find { |row| row.fetch(:table) == record.fetch(:table) }
        fail!("#{record.fetch(:table)} aggregate child axes differ") unless record.fetch(:name) == PROJECTION &&
          record.fetch(:parent_name) == parent.fetch(:name) && record.fetch(:child_type) == 'Wide' &&
          record.fetch(:parent_type) == parent.fetch(:format) && record.fetch(:active) == '1' &&
          record.fetch(:rows) == 3 && record.fetch(:marks) == 3 &&
          record.fetch(:parent_rows) == parent.fetch(:rows) && record.fetch(:parent_marks) == parent.fetch(:marks)
        expected_child_path = File.join(parent.fetch(:path), "#{PROJECTION}.proj")
        fail!("#{record.fetch(:table)} aggregate child path differs") unless File.expand_path(record.fetch(:path)) == expected_child_path
        record[:inventory] = inventory_part(parent.fetch(:path))
        generated = @generated_parts.values.find { |entry| entry.fetch(:target) == record.fetch(:table) }
        attach_inventory_comparison = compare_attach_inventory!(generated.fetch(:inventory), record.fetch(:inventory), parent.fetch(:path))
        @attached_parts[record.fetch(:table)] = record.merge(
          parent_path: parent.fetch(:path),
          attach_inventory_comparison: attach_inventory_comparison,
        )
      end

      ["target_compact", "target_wide"].each do |table|
        check = native_query("check_#{table}_final", "CHECK TABLE #{DATABASE}.#{table} FORMAT TSV;")
        part_name = parent_records.find { |row| row.fetch(:table) == table }.fetch(:name)
        assert_bytes!(check, "#{part_name}\t1\t\n".b, "#{table} final CHECK TABLE")
      end
      {parents: parent_records, projections: projection_records}
    end

    def verify_native_grouped_reads!
      @grouped_reads = {}
      {'target_compact' => COMPACT_ROWS, 'target_wide' => WIDE_ROWS}.each do |table, row_count|
        parent_sql = "SELECT parent_id, group_key, payload FROM #{DATABASE}.#{table} ORDER BY parent_id SETTINGS optimize_use_projections=0 FORMAT RowBinary;"
        parent_rows = native_query("parent_rows_#{table}", parent_sql)
        assert_bytes!(parent_rows, parent_rowbinary(expected_parent_rows(row_count)), "#{table} exact parent rows with projections disabled")

        expected = grouped_tsv(expected_count_rows(row_count))
        grouped_parent_sql = "SELECT group_key, count() FROM #{DATABASE}.#{table} GROUP BY group_key ORDER BY group_key SETTINGS optimize_use_projections=0 FORMAT TSVRaw;"
        grouped_parent = native_query("grouped_parent_#{table}", grouped_parent_sql)
        assert_bytes!(grouped_parent, expected, "#{table} grouped query with projections disabled")
        alias_expr = table == 'target_wide' ? ' AS n' : ''
        forced_sql = "SELECT group_key, count()#{alias_expr} FROM #{DATABASE}.#{table} GROUP BY group_key ORDER BY group_key SETTINGS force_optimize_projection=1, force_optimize_projection_name='#{PROJECTION}' FORMAT TSVRaw;"
        forced = native_query("forced_grouped_#{table}", forced_sql)
        assert_bytes!(forced, expected, "#{table} forced grouped projection query")
        @grouped_reads[table] = {
          parent_rowbinary_sha256: Digest::SHA256.hexdigest(parent_rows),
          grouped_parent_sha256: Digest::SHA256.hexdigest(grouped_parent),
          forced_sha256: Digest::SHA256.hexdigest(forced), exact: true,
        }
      end
    end

    def verify_native_direct_projection_states!
      @direct_projection_states = {}
      {
        'target_compact' => COMPACT_EXPECTED_CHILD_ROW_BINARY_HEX,
        'target_wide' => WIDE_EXPECTED_CHILD_ROW_BINARY_HEX,
      }.each do |table, expected_hex|
        schema = native_query("direct_schema_#{table}", "DESCRIBE TABLE mergeTreeProjection('#{DATABASE}','#{table}','#{PROJECTION}') FORMAT TSVRaw;")
        schema_rows = schema.lines(chomp: true).map { |line| line.split("\t", -1).take(2) }
        fail!("#{table} direct projection child state schema/order differs") unless schema_rows == PROJECTION_COLUMNS
        direct_sql = "SELECT * FROM mergeTreeProjection('#{DATABASE}','#{table}','#{PROJECTION}') ORDER BY group_key FORMAT RowBinary;"
        direct = native_query("direct_projection_states_#{table}", direct_sql)
        expected = [expected_hex].pack('H*')
        assert_bytes!(direct, expected, "#{table} direct aggregate projection RowBinary")
        @direct_projection_states[table] = {
          column_order_and_types: PROJECTION_COLUMNS,
          rowbinary_bytes: direct.bytesize,
          rowbinary_hex: direct.unpack1('H*'),
          sha256: Digest::SHA256.hexdigest(direct),
          count_128_state_varuint: table == 'target_wide' ? '8001' : nil,
          literal_exact: true,
        }
      end
    end

    def verify_native_forced_explains!
      @forced_explains = {}
      {'target_compact' => '', 'target_wide' => ' AS n'}.each do |table, alias_expr|
        sql = "EXPLAIN json=1, description=1, projections=1 SELECT group_key, count()#{alias_expr} FROM #{DATABASE}.#{table} GROUP BY group_key ORDER BY group_key SETTINGS force_optimize_projection=1, force_optimize_projection_name='#{PROJECTION}' FORMAT JSONEachRow;"
        stdout = native_query("forced_explain_#{table}", sql)
        @forced_explains[table] = parse_forced_explain!(stdout, table)
      end
    end

    def parse_forced_explain!(stdout, table)
      rows = stdout.lines(chomp: true).filter_map do |line|
        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end
      fail!("#{table} EXPLAIN output has no JSON rows") if rows.empty?
      objects = []
      walk_json(rows) { |object| objects << object if object.is_a?(Hash) }
      readers = objects.select { |object| object['Node Type'] == 'ReadFromMergeTree' }
      fail!("#{table} EXPLAIN did not expose exactly one MergeTree read") unless readers.size == 1
      reader = readers.first
      fail!("#{table} EXPLAIN did not select #{PROJECTION}") unless reader['Description'] == PROJECTION
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

    def copy_attached_parts_to_catalog!
      {'target_compact' => COMPACT_TARGET_UUID, 'target_wide' => WIDE_TARGET_UUID}.each do |table, uuid|
        attached = @attached_parts.fetch(table)
        destination = File.join(uuid_path(uuid), attached.fetch(:parent_name))
        fail!("#{table} offline reopen candidate path is occupied") if File.exist?(destination) || File.symlink?(destination)
        copy_tree(attached.fetch(:parent_path), destination)
        copied = inventory_part(destination)
        fail!("#{table} offline copy differs from checked native attachment") unless copied == attached.fetch(:inventory)
        attached[:catalog_copy] = {path: destination, inventory: copied, byte_identical_to_native_attachment: true}
      end
    end

    def validate_reopen_report!(report)
      fail!('W291 reopen helper report/status differs') unless report.is_a?(Hash) &&
        report['format'] == 'materialized_view_aggregate_projection_w291_helper_v1' &&
        report['action'] == 'reopen' && report['status'] == 'ok' && report['catalog_root'] == @catalog_root
      pairs = report.fetch('pairs')
      fail!('W291 reopen pair roster differs') unless pairs.map { |pair| pair.fetch('table') }.sort == %w[target_compact target_wide]
      expected = {
        'target_compact' => ['Compact', COMPACT_ROWS, expected_parent_rows(COMPACT_ROWS), expected_count_rows(COMPACT_ROWS), [3, 3]],
        'target_wide' => ['Wide', WIDE_ROWS, expected_parent_rows(WIDE_ROWS), expected_count_rows(WIDE_ROWS), mark_rows(WIDE_ROWS, 4)],
      }
      pairs.each do |pair|
        format, parent_count, parents, counts, parent_grid = expected.fetch(pair.fetch('table'))
        fail!("#{pair.fetch('table')} OfflineCatalog formats or row count differ") unless pair['parent_format'] == format &&
          pair['child_format'] == 'Wide' && pair['parent_row_count'] == parent_count
        fail!("#{pair.fetch('table')} OfflineCatalog full rows differ") unless pair['parent_rows'] == parents &&
          pair['child_rows'] == counts && pair['parent_mark_rows'] == parent_grid && pair['child_mark_rows'] == [2, 1]
        fail!("#{pair.fetch('table')} OfflineCatalog crossing-window rows differ") unless
          pair['parent_window_rows_1_3'] == parents[1, 2] &&
          pair['child_window_rows_1_3'] == counts[1, 2] &&
          pair['parent_window_mark_rows'] == [2] && pair['child_window_mark_rows'] == [1, 1]
        attached = @attached_parts.fetch(pair.fetch('table'))
        fail!("#{pair.fetch('table')} OfflineCatalog part identity/path differs") unless pair['part_name'] == attached.fetch(:parent_name) &&
          pair['parent_path'] == attached.fetch(:catalog_copy).fetch(:path) &&
          pair['child_path'] == File.join(attached.fetch(:catalog_copy).fetch(:path), "#{PROJECTION}.proj") &&
          pair['reopen_source'] == 'byte_identical_copy_of_native_attached_part'
      end
    end

    def validate_end_state!
      fail!('native binary changed during witness') unless sha_file(@binary) == @binary_sha_before
      fail!('helper changed during witness') unless sha_file(@helper) == @helper_sha_before
      fail!('pinned run_safe guard changed during witness') unless sha_file(@run_safe) == @run_safe_sha_before
      fail!('input sources changed during witness') unless input_hashes == @input_hashes_before
      fail!('stock source part changed during witness') unless inventory_part(@source_part_path) == @source_inventory
      @generated_parts.each do |id, entry|
        fail!("#{id} generated files changed during native attach/reopen") unless inventory_part(entry.fetch(:path)) == entry.fetch(:inventory)
      end
      @attached_parts.each do |table, entry|
        generated = @generated_parts.values.find { |part| part.fetch(:target) == table }
        observed = compare_attach_inventory!(generated.fetch(:inventory), inventory_part(entry.fetch(:parent_path)), entry.fetch(:parent_path))
        fail!("#{table} attached inventory changed after its checked snapshot") unless observed == entry.fetch(:attach_inventory_comparison)
        fail!("#{table} OfflineCatalog copy changed after reopen") unless inventory_part(entry.fetch(:catalog_copy).fetch(:path)) == entry.fetch(:inventory)
      end
    end

    def native_query(label, sql)
      run_native(label, (sql.end_with?("\n") ? sql : sql + "\n").b).fetch(:stdout)
    end

    def run_native(label, input)
      cell_root = File.join(@root, 'native', label)
      Dir.mkdir(cell_root, 0o700)
      arguments = ['local', '--path', @native_store, '--session_timezone=UTC', '--max_threads=1',
                   "--max_memory_usage=#{MEMORY_BYTES}", '--multiquery']
      run_process(label, @binary, arguments, input, 'ClickHouse local', cell_root)
    end

    def run_process(label, executable, arguments, input, process_kind, cell_root)
      argv = [@run_safe, executable, PROCESS_TIMEOUT_SECONDS.to_s,
              (PROCESS_MEMORY_BYTES / (1024 * 1024)).to_s, *arguments]
      env = {
        'RUN_SAFE_PASSTHROUGH_STDIO' => '1',
        'COGNI_RUN_SAFE_MIN_FREE_PCT' => '50',
        'TMPDIR' => File.join(@root, 'tmp'),
        'TMP' => File.join(@root, 'tmp'),
        'TEMP' => File.join(@root, 'tmp'),
      }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      stdout, stderr, status = Open3.capture3(env, *argv, stdin_data: input)
      duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      stdout = stdout.b
      stderr = stderr.b
      fail!("#{label} stdout exceeded capture bound") if stdout.bytesize > MAX_CAPTURE_BYTES
      fail!("#{label} stderr exceeded capture bound") if stderr.bytesize > MAX_CAPTURE_BYTES
      write_new(File.join(cell_root, 'stdin.bin'), input)
      write_new(File.join(cell_root, 'stdout.bin'), stdout)
      write_new(File.join(cell_root, 'stderr.bin'), stderr)
      record = {
        label: label, process_kind: process_kind, argv: argv, argv_sha256: Digest::SHA256.hexdigest(JSON.generate(argv)),
        run_safe_sha256: @run_safe_sha_before, min_free_percent: 50, process_tree_memory_limit_bytes: PROCESS_MEMORY_BYTES,
        sql_max_threads: process_kind == 'ClickHouse local' ? 1 : nil,
        sql_max_memory_usage_bytes: process_kind == 'ClickHouse local' ? MEMORY_BYTES : nil,
        input_bytes: input.bytesize, input_sha256: Digest::SHA256.hexdigest(input), duration_seconds: duration.round(3),
        exitstatus: status.exitstatus, termsig: status.termsig,
        stdout_file: File.join(cell_root, 'stdout.bin'), stdout_bytes: stdout.bytesize, stdout_sha256: Digest::SHA256.hexdigest(stdout),
        stderr_file: File.join(cell_root, 'stderr.bin'), stderr_bytes: stderr.bytesize, stderr_sha256: Digest::SHA256.hexdigest(stderr),
      }
      write_new(File.join(cell_root, 'process.json'), JSON.pretty_generate(record) + "\n")
      @process_records << record
      fail!("#{label}: exit=#{status.exitstatus} signal=#{status.termsig}: #{stderr}") unless status.success? && status.termsig.nil?
      {stdout: stdout, stderr: stderr, status: status}
    rescue Errno::ENOENT => error
      fail!("#{label}: spawn failed: #{error.class}: #{error.message}")
    end

    def validate_store_path!(path)
      full = File.expand_path(path)
      root = File.realpath(@native_store)
      real = File.realpath(full)
      fail!('native data path escaped the isolated store') unless real.start_with?(root + File::SEPARATOR)
      fail!('native data path is not canonical or is a symlink') unless full == real && !File.symlink?(full)
      real
    end

    def validate_native_part_path!(path, table, part_name)
      data_path = @native_paths[table]
      full = File.expand_path(path)
      expected = File.join(data_path, part_name)
      fail!("#{table} native part path differs from its system.data_paths parent") unless full == expected
      fail!("#{table} native part path escaped the isolated store") unless File.realpath(full).start_with?(File.realpath(@native_store) + File::SEPARATOR)
      fail!("#{table} native part path is symlinked") if File.symlink?(full)
      File.realpath(full)
    end

    def inventory_part(root)
      real = File.realpath(root)
      files = []
      total = 0
      Find.find(real) do |path|
        stat = File.lstat(path)
        fail!("symlink or special entry in part: #{path}") if stat.symlink? || !(stat.directory? || stat.file?)
        next if stat.directory?
        total += stat.size
        files << {relative_path: path.delete_prefix(real + File::SEPARATOR), bytes: stat.size, sha256: sha_file(path)}
        fail!('part file count exceeds bound') if files.size > MAX_PART_FILES
        fail!('part bytes exceed bound') if total > MAX_PART_BYTES
      end
      {files: files.sort_by { |entry| entry.fetch(:relative_path) }, total_bytes: total}
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

    def copy_tree(source, destination)
      fail!('part copy destination already exists') if File.exist?(destination) || File.symlink?(destination)
      Find.find(source) do |path|
        stat = File.lstat(path)
        fail!("symlink or special part entry: #{path}") if stat.symlink? || !(stat.directory? || stat.file?)
      end
      FileUtils.cp_r(source, destination, preserve: true)
    end

    def one_tsv_row(bytes, width, label)
      lines = bytes.dup.force_encoding(Encoding::UTF_8).lines(chomp: true)
      fail!("#{label} output is not one valid UTF-8 row") unless lines.size == 1 && lines.first.valid_encoding?
      split_tsv(lines.first, width, label)
    end

    def split_tsv(line, width, label)
      fields = line.split("\t", -1)
      fail!("#{label} output width differs") unless fields.size == width
      fields
    end

    def source_group(id)
      return 7 if (1..3).cover?(id) || (7..131).cover?(id)
      return 11 if (4..5).cover?(id)
      return 29 if id == 6
      return 41 if id == 132
      43
    end

    def source_rows
      (1..SOURCE_ROWS).map { |id| [id, source_group(id), "r#{id}"] }
    end

    def expected_parent_rows(limit)
      source_rows.take(limit).map do |id, group, payload|
        [id + 1000, group * 10 + 7, "#{payload}!"]
      end
    end

    def expected_count_rows(limit)
      expected_parent_rows(limit).each_with_object(Hash.new(0)) { |(_id, key, _payload), counts| counts[key] += 1 }
        .sort_by { |key, _count| key }
    end

    def grouped_tsv(rows)
      rows.map { |key, count| "#{key}\t#{count}\n" }.join.b
    end

    def mark_rows(row_count, rows_per_mark)
      count = (row_count + rows_per_mark - 1) / rows_per_mark
      Array.new(count) { |index| [row_count - index * rows_per_mark, rows_per_mark].min }
    end

    def valid_active_part_name?(name)
      name.match?(/\Aall_[0-9]+_[0-9]+_[0-9]+\z/)
    end

    def source_rowbinary
      source_rows.map do |id, group, payload|
        [id].pack('Q<') + [group].pack('Q<') + rowbinary_string(payload)
      end.join.b
    end

    def parent_rowbinary(rows)
      rows.map do |parent_id, group_key, payload|
        [parent_id].pack('Q<') + [group_key].pack('Q<') + rowbinary_string(payload)
      end.join.b
    end

    def rowbinary_string(value)
      bytes = value.b
      rowbinary_varuint(bytes.bytesize) + bytes
    end

    def rowbinary_varuint(value)
      remaining = value
      output = ''.b
      while remaining >= 0x80
        output << ((remaining & 0x7f) | 0x80)
        remaining >>= 7
      end
      output << remaining
      output
    end

    def assert_bytes!(actual, expected, label)
      fail!("#{label} differs: bytes=#{actual.bytesize} sha256=#{Digest::SHA256.hexdigest(actual)} expected_bytes=#{expected.bytesize} expected_sha256=#{Digest::SHA256.hexdigest(expected)}") unless actual == expected
    end

    def uuid_path(uuid)
      File.join(@catalog_root, 'store', uuid[0, 3], uuid)
    end

    def write_summary(values)
      record = {
        format: FORMAT, source_revision: @source_revision,
        runtime: {path: @binary || @binary_argument, sha256_expected: RUNTIME_PIN.fetch(:sha256),
                  sha256_before: @binary_sha_before, sha256_after: @binary_sha_after || (@binary && sha_file(@binary))},
        helper: {path: @helper || @helper_argument, sha256_before: @helper_sha_before,
                 sha256_after: @helper_sha_after || (@helper && sha_file(@helper))},
        run_safe: {path: @run_safe || @run_safe_argument, sha256_expected: RUN_SAFE_SHA256,
                   sha256_before: @run_safe_sha_before, sha256_after: @run_safe_sha_after || (@run_safe && sha_file(@run_safe))},
        evidence_root: @root || @root_argument, input_hashes_before: @input_hashes_before,
        input_hashes_after: @input_hashes_after || (input_hashes rescue nil),
        limits: {timeout_seconds: PROCESS_TIMEOUT_SECONDS, process_tree_memory_bytes: PROCESS_MEMORY_BYTES,
                 sql_memory_bytes: MEMORY_BYTES, run_safe_min_free_percent: 50},
        fatal_error: @fatal_error,
      }.merge(values)
      return unless @root && File.directory?(@root)
      path = File.join(@root, 'summary.json')
      File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(JSON.pretty_generate(record) + "\n") }
    end

    def input_hashes
      INPUT_FILES.to_h do |relative|
        path = File.join(REPO_ROOT, relative)
        fail!("missing or symlinked W291 input: #{relative}") unless File.file?(path) && !File.symlink?(path)
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
      raise Error, "W291 aggregate projection witness: #{message}"
    end
  end

  def self.run(argv = ARGV)
    options = {binary: BINARY, helper: nil, run_safe: nil, evidence_root: nil}
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: ruby scripts/verify_materialized_view_aggregate_projection_w291.rb --crystal-helper PATH --evidence-root NEW_PATH --run-safe PINNED_PATH [--clickhouse PINNED_PATH]'
      opts.on('--clickhouse PATH') { |value| options[:binary] = value }
      opts.on('--run-safe PATH') { |value| options[:run_safe] = value }
      opts.on('--crystal-helper PATH') { |value| options[:helper] = value }
      opts.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
    end
    parser.parse!(argv)
    raise OptionParser::MissingArgument, '--crystal-helper' unless options[:helper]
    raise OptionParser::MissingArgument, '--run-safe' unless options[:run_safe]
    raise OptionParser::MissingArgument, '--evidence-root' unless options[:evidence_root]
    raise OptionParser::InvalidArgument, 'unexpected positional arguments' unless argv.empty?
    exit(Driver.new(options).run ? 0 : 1)
  rescue OptionParser::ParseError, ArgumentError => error
    warn "W291 usage error: #{error.message}"
    warn parser
    exit(2)
  end
end

VerifyMaterializedViewAggregateProjectionW291.run if $PROGRAM_NAME == __FILE__
