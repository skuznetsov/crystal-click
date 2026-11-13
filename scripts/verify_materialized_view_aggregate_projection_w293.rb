#!/usr/bin/env ruby
# Bounded W293 stock-native -> caller transform -> min/max projection witness.
# The Crystal helper must already be built; this runner never invokes a build.

require 'base64'
require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'open3'
require 'optparse'

module VerifyMaterializedViewAggregateProjectionW293
  extend self

  REPO_ROOT = File.expand_path('..', __dir__).freeze
  FORMAT = 'materialized_view_aggregate_projection_w293_native_v1'.freeze
  BINARY = '/opt/mldata_ssd/cache/crystal-click-w283.PDWAiK/recovery/runtime/clickhouse'.freeze
  BINARY_SHA256 = '5bb43958f4c0806cc363b84b9858e7206e56ac80263a24acc704271322e531ae'.freeze
  VERSION = '26.10.1.1201'.freeze
  REVISION = '54515'.freeze
  RUN_SAFE_SHA256 = 'fbfa0fd9d717eb24c1a3f829d464188110e505c7ae311eee2e95cbe7cefab011'.freeze
  DATABASE = 'lab'.freeze
  DATABASE_UUID = 'f2930000-7b7f-4e2f-9e44-dc13a87b8801'.freeze
  SOURCE_UUID = 'f2930000-7b7f-4e2f-9e44-dc13a87b8802'.freeze
  COMPACT_TARGET_UUID = 'f2930000-7b7f-4e2f-9e44-dc13a87b8805'.freeze
  WIDE_TARGET_UUID = 'f2930000-7b7f-4e2f-9e44-dc13a87b8806'.freeze
  COMPACT_VIEW_UUID = 'f2930000-7b7f-4e2f-9e44-dc13a87b8807'.freeze
  WIDE_VIEW_UUID = 'f2930000-7b7f-4e2f-9e44-dc13a87b8808'.freeze
  SOURCE_PART = 'all_1_1_0'.freeze
  COMPACT_PART = 'all_9_9_0'.freeze
  WIDE_PART = 'all_10_10_0'.freeze
  PROJECTION = 'by_group'.freeze
  UINT64_MAX = (1 << 64) - 1
  ASYMMETRIC = 0x0102030405060708
  SOURCE_ROWS = [
    [1, 10, 0],
    [2, 10, 1],
    [3, 10, UINT64_MAX],
    [4, 20, ASYMMETRIC],
    [5, 20, 17],
    [6, 20, 23],
    [7, 30, 42],
    [8, 20, 99],
    [9, 30, ASYMMETRIC],
  ].freeze
  PARENT_ROWS = SOURCE_ROWS.map { |id, group, value| [id + 100, group, value.to_s] }.freeze
  KEYS = [10, 20, 30].freeze
  MINS = [0, 17, 42].freeze
  MAXS = [UINT64_MAX, ASYMMETRIC, ASYMMETRIC].freeze
  COUNTS = [3, 4, 2].freeze
  SUMS = [0, ASYMMETRIC + 139, ASYMMETRIC + 42].freeze
  COMPACT_CHILD_ROWS = KEYS.each_index.map { |index| [KEYS[index], MINS[index].to_s, MAXS[index].to_s] }.freeze
  WIDE_CHILD_ROWS = KEYS.each_index.map do |index|
    [KEYS[index], MAXS[index].to_s, COUNTS[index], MINS[index].to_s, SUMS[index].to_s]
  end.freeze
  COMPACT_COLUMNS = [
    ['group_key', 'UInt64'],
    ['min(value)', 'AggregateFunction(min, UInt64)'],
    ['max(value)', 'AggregateFunction(max, UInt64)'],
  ].freeze
  WIDE_COLUMNS = [
    ['group_key', 'UInt64'],
    ['max(value)', 'AggregateFunction(max, UInt64)'],
    ['count()', 'AggregateFunction(count)'],
    ['min(value)', 'AggregateFunction(min, UInt64)'],
    ['sum(value)', 'AggregateFunction(sum, UInt64)'],
  ].freeze
  TARGETS = {
    'target_compact' => {
      uuid: COMPACT_TARGET_UUID, part: COMPACT_PART, format: 'Compact',
      columns: COMPACT_COLUMNS, order: %w[min(value) max(value)], variant: :compact,
      select: 'group_key, min(value), max(value)',
      ddl: 'SELECT min(value) AS minimum, max(value) AS maximum GROUP BY group_key',
    },
    'target_wide' => {
      uuid: WIDE_TARGET_UUID, part: WIDE_PART, format: 'Wide',
      columns: WIDE_COLUMNS, order: %w[max(value) count() min(value) sum(value)], variant: :wide,
      select: 'group_key, max(value), count(), min(value), sum(value)',
      ddl: 'SELECT group_key, max(value) AS maximum, count() AS n, min(value) AS minimum, sum(value) AS total GROUP BY group_key',
    },
  }.freeze
  MEMORY_BYTES = 536_870_912
  PROCESS_MEMORY_MIB = 2048
  PROCESS_TIMEOUT_SECONDS = 90
  MAX_CAPTURE_BYTES = 16 * 1024 * 1024
  MAX_PART_FILES = 256
  MAX_PART_BYTES = 16 * 1024 * 1024
  INPUT_FILES = %w[
    scripts/verify_materialized_view_aggregate_projection_w293.rb
    scripts/check_materialized_view_aggregate_projection_w293.cr
  ].freeze

  class Error < StandardError; end

  class Driver
    def initialize(options)
      @root_arg = options.fetch(:evidence_root)
      @binary_arg = options.fetch(:binary)
      @helper_arg = options.fetch(:helper)
      @run_safe_arg = options.fetch(:run_safe)
      @processes = []
      @generated = {}
      @attached = {}
      @metadata = {}
      @native_paths = {}
    end

    def run
      prepare!
      create_source!
      insert_source!
      source = verify_source!
      create_targets!
      catalog = build_catalog!
      publish = run_helper('publish')
      validate_publish!(publish)
      copy_to_detached!
      attach_and_check!
      native_state = verify_native_reads!
      copy_attached_to_catalog!
      names = %w[target_compact target_wide].map { |name| @attached.fetch(name).fetch(:part) }
      reopen = run_helper('reopen', names)
      validate_reopen!(reopen)
      validate_inputs_unchanged!
      write_summary(
        status: 'native_minmax_aggregate_children_attached_checked_and_offline_reopened',
        binary: {path: @binary, sha256: @binary_sha_before, version: VERSION, revision: REVISION},
        helper: {path: @helper, sha256: @helper_sha_before},
        run_safe: {path: @run_safe, sha256: @run_safe_sha_before},
        source: source, offline_catalog: catalog, generated_parts: @generated,
        attached_parts: @attached, native_checks: native_state, reopen: reopen,
        invocations: @processes,
        cleanup_owner: 'orchestrator', retained_evidence_root: @root,
        generated_native_part_paths: @attached.values.map { |entry| entry.fetch(:path) },
      )
      puts "W293 min/max aggregate projection witness passed; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error = "#{error.class}: #{error.message}"
      write_summary(status: 'witness_failure_or_observations_differ', fatal_error: @fatal_error,
                    cleanup_owner: 'orchestrator', retained_evidence_root: @root) rescue nil
      warn "W293 probe failure (process failure is not native format evidence): #{@fatal_error}"
      false
    end

    private

    def prepare!
      @root = validate_evidence_root(@root_arg)
      @binary = validate_pinned_file!(@binary_arg, BINARY_SHA256, 'ClickHouse runtime')
      @helper = validate_executable!(@helper_arg, 'prebuilt Crystal helper')
      @run_safe = validate_pinned_file!(@run_safe_arg, RUN_SAFE_SHA256, 'run_safe guard')
      @binary_sha_before = sha_file(@binary)
      @helper_sha_before = sha_file(@helper)
      @run_safe_sha_before = sha_file(@run_safe)
      @input_hashes = input_hashes
      @revision_before = git_revision
      %w[native catalog helper tmp].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      @native_store = File.join(@root, 'native', 'store')
      @catalog_root = File.join(@root, 'catalog', 'offline_catalog')
    end

    # Resolve the /opt/mldata_ssd volume alias before creating the evidence
    # root. This still rejects system-volume targets, pre-existing roots, and
    # symlinked roots while allowing the pinned /opt path used by the runner.
    def validate_evidence_root(path)
      fail!('fresh --evidence-root is required') unless path.is_a?(String) && !path.empty?
      expanded = File.expand_path(path)
      parent = File.dirname(expanded)
      fail!('evidence root parent must be an existing directory') unless File.directory?(parent)
      real_parent = File.realpath(parent)
      parent_stat = File.stat(real_parent)
      fail!('evidence root must be on a non-system volume') if parent_stat.dev == File.stat('/').dev
      full = File.join(real_parent, File.basename(expanded))
      fail!('evidence root already exists or is a symlink') if File.exist?(full) || File.symlink?(full)
      Dir.mkdir(full, 0o700)
      real = File.realpath(full)
      stat = File.lstat(full)
      fail!('evidence root must be a plain owned directory on the selected volume') unless
        real == full && stat.directory? && !stat.symlink? && stat.uid == Process.uid && stat.dev == parent_stat.dev
      real
    rescue Errno::ENOENT
      fail!('evidence root parent or path is absent')
    end

    def validate_pinned_file!(path, sha, label)
      full = File.realpath(File.expand_path(path))
      fail!("#{label} is absent or not executable") unless File.file?(full) && File.executable?(full)
      fail!("#{label} SHA-256 differs from the pinned artifact") unless sha_file(full) == sha
      full
    rescue Errno::ENOENT
      fail!("#{label} path is absent")
    end

    def validate_executable!(path, label)
      fail!("#{label} path is required") unless path.is_a?(String) && !path.empty?
      full = File.realpath(File.expand_path(path))
      fail!("#{label} is absent or not executable") unless File.file?(full) && File.executable?(full)
      full
    rescue Errno::ENOENT
      fail!("#{label} path is absent")
    end

    def create_source!
      sql = <<~SQL
        CREATE DATABASE #{DATABASE} ENGINE = Atomic;
        CREATE TABLE #{DATABASE}.source UUID '#{SOURCE_UUID}'
        (
            source_id UInt64,
            source_group UInt64,
            value UInt64
        ) ENGINE = MergeTree ORDER BY source_id SETTINGS index_granularity=2, min_rows_for_wide_part=0, min_bytes_for_wide_part=0;
        SELECT version(), revision() FORMAT TSVRaw;
      SQL
      output = native('create_source', sql.b)
      assert_bytes!(output, "#{VERSION}\t#{REVISION}\n".b, 'pinned native version/revision')
    end

    def insert_source!
      bytes = SOURCE_ROWS.map { |row| row.pack('Q<Q<Q<') }.join.b
      output = native('insert_source', "INSERT INTO #{DATABASE}.source FORMAT RowBinary\n".b + bytes)
      fail!('RowBinary source insert emitted unexpected stdout') unless output.empty?
    end

    def verify_source!
      check = query('source_check', "CHECK TABLE #{DATABASE}.source FORMAT TSV;")
      assert_bytes!(check, "#{SOURCE_PART}\t1\t\n".b, 'stock source CHECK TABLE')
      source_rows = query('source_rows', <<~SQL)
        SELECT source_id, source_group, value FROM #{DATABASE}.source ORDER BY source_id FORMAT RowBinary;
      SQL
      expected_source = SOURCE_ROWS.map { |row| row.pack('Q<Q<Q<') }.join.b
      assert_bytes!(source_rows, expected_source, 'stock source fixture RowBinary')
      row = query('source_part', <<~SQL)
        SELECT name, part_type, toString(rows), toString(marks), path
        FROM system.parts WHERE database='#{DATABASE}' AND table='source' AND active FORMAT TSVRaw;
      SQL
      fields = one_row(row, 5, 'source part')
      fail!('source part identity, type, or count differs') unless
        fields[0] == SOURCE_PART && fields[1] == 'Wide' && fields[2] == SOURCE_ROWS.size.to_s && fields[3].to_i == 6
      data_path = query('source_data_path', "SELECT data_paths[1] FROM system.tables WHERE database='#{DATABASE}' AND name='source' FORMAT TSVRaw;").strip
      @native_paths['source'] = store_path!(data_path)
      @source_path = part_path!(fields[4], 'source', SOURCE_PART)
      @source_inventory = inventory(@source_path)
      {part: SOURCE_PART, format: fields[1], rows: fields[2].to_i, marks: fields[3].to_i,
       path: @source_path, rowbinary_sha256: Digest::SHA256.hexdigest(source_rows), inventory: @source_inventory}
    end

    def create_targets!
      compact_projection = TARGETS.fetch('target_compact').fetch(:ddl)
      wide_projection = TARGETS.fetch('target_wide').fetch(:ddl)
      sql = <<~SQL
        CREATE TABLE #{DATABASE}.target_compact UUID '#{COMPACT_TARGET_UUID}'
        (
            parent_id UInt64,
            group_key UInt64,
            value UInt64,
            PROJECTION #{PROJECTION} (#{compact_projection})
        ) ENGINE = MergeTree ORDER BY parent_id SETTINGS index_granularity=2, min_rows_for_wide_part=0, min_bytes_for_wide_part=0;
        CREATE TABLE #{DATABASE}.target_wide UUID '#{WIDE_TARGET_UUID}'
        (
            parent_id UInt64,
            group_key UInt64,
            value UInt64,
            PROJECTION #{PROJECTION} (#{wide_projection})
        ) ENGINE = MergeTree ORDER BY parent_id SETTINGS index_granularity=2, min_rows_for_wide_part=0, min_bytes_for_wide_part=0;
        CREATE MATERIALIZED VIEW #{DATABASE}.view_compact UUID '#{COMPACT_VIEW_UUID}' TO #{DATABASE}.target_compact
        (parent_id UInt64, group_key UInt64, value UInt64)
        AS SELECT source_id + 100 AS parent_id, source_group AS group_key, value FROM #{DATABASE}.source;
        CREATE MATERIALIZED VIEW #{DATABASE}.view_wide UUID '#{WIDE_VIEW_UUID}' TO #{DATABASE}.target_wide
        (parent_id UInt64, group_key UInt64, value UInt64)
        AS SELECT source_id + 100 AS parent_id, source_group AS group_key, value FROM #{DATABASE}.source;
      SQL
      native('create_targets', sql.b)
      %w[target_compact target_wide].each do |name|
        fail!("materialized-view target #{name} was not empty") unless
          query("target_count_#{name}", "SELECT toString(count()) FROM #{DATABASE}.#{name} FORMAT TSVRaw;").strip == '0'
        fail!("materialized-view target #{name} unexpectedly has active parts") unless
          query("target_parts_#{name}", "SELECT toString(count()) FROM system.parts WHERE database='#{DATABASE}' AND table='#{name}' AND active FORMAT TSVRaw;").strip == '0'
      end

      paths = query('target_paths', <<~SQL).lines(chomp: true)
        SELECT name, arrayElement(data_paths,1) FROM system.tables
        WHERE database='#{DATABASE}' AND name IN ('target_compact','target_wide') ORDER BY name FORMAT TSVRaw;
      SQL
      fail!('native target data path roster differs') unless paths.size == 2
      paths.each do |line|
        name, path = line.split("\t", -1)
        @native_paths[name] = store_path!(path)
      end
      metadata_lines = query('metadata_paths', <<~SQL).lines(chomp: true)
        SELECT name, base64Encode(metadata_path) FROM system.tables
        WHERE database='#{DATABASE}' AND name IN ('source','target_compact','target_wide','view_compact','view_wide')
        ORDER BY name FORMAT TSVRaw;
      SQL
      fail!('native metadata roster differs') unless metadata_lines.size == 5
      metadata_lines.each do |line|
        name, encoded = line.split("\t", -1)
        fail!('native metadata row is malformed') unless encoded
        @metadata[name] = Base64.strict_decode64(encoded)
      rescue ArgumentError
        fail!('native metadata path is malformed base64')
      end
    end

    def build_catalog!
      database_path = uuid_path(DATABASE_UUID)
      source_path = uuid_path(SOURCE_UUID)
      compact_path = uuid_path(COMPACT_TARGET_UUID)
      wide_path = uuid_path(WIDE_TARGET_UUID)
      [database_path, source_path, compact_path, wide_path].each { |path| FileUtils.mkdir_p(path, mode: 0o700) }
      FileUtils.mkdir_p(File.join(@catalog_root, 'metadata'), mode: 0o700)
      [source_path, compact_path, wide_path].each { |path| write_new(File.join(path, 'format_version.txt'), "1\n") }
      [compact_path, wide_path].each { |path| FileUtils.mkdir_p(File.join(path, 'detached'), mode: 0o700) }
      write_new(File.join(@catalog_root, 'metadata', 'lab.sql'), "ATTACH DATABASE _ UUID '#{DATABASE_UUID}'\nENGINE = Atomic\n")
      {
        'source' => [SOURCE_UUID, 'TABLE'],
        'target_compact' => [COMPACT_TARGET_UUID, 'TABLE'],
        'target_wide' => [WIDE_TARGET_UUID, 'TABLE'],
        'view_compact' => [COMPACT_VIEW_UUID, 'MATERIALIZED VIEW'],
        'view_wide' => [WIDE_VIEW_UUID, 'MATERIALIZED VIEW'],
      }.each do |name, (uuid, kind)|
        path = File.expand_path(@metadata.fetch(name), @native_store)
        real = File.realpath(path)
        fail!("#{name} metadata path escaped the isolated ClickHouse store") unless real.start_with?(File.realpath(@native_store) + File::SEPARATOR)
        ddl = File.binread(real)
        fail!("persisted #{name} metadata is oversized or invalid UTF-8") if ddl.bytesize > 1_048_576 || !ddl.dup.force_encoding(Encoding::UTF_8).valid_encoding?
        fail!("persisted #{name} metadata identity differs") unless /\A\s*ATTACH\s+#{Regexp.escape(kind)}\s+_\s+UUID\s+'#{Regexp.escape(uuid)}'/im.match?(ddl)
        write_new(File.join(database_path, "#{name}.sql"), ddl)
      end
      source_copy = File.join(source_path, SOURCE_PART)
      copy_tree(@source_path, source_copy)
      copy_inventory = inventory(source_copy)
      fail!('OfflineCatalog source part copy differs') unless copy_inventory == @source_inventory
      {root: @catalog_root, source_copy: source_copy, source_inventory: copy_inventory}
    end

    def validate_publish!(report)
      fail!('publish helper format/status differs') unless report.is_a?(Hash) &&
        report['format'] == 'materialized_view_aggregate_projection_w293_helper_v1' &&
        report['action'] == 'publish' && report['status'] == 'ok'
      fail!('publish source rows differ') unless report['source_row_count'] == SOURCE_ROWS.size && report['parent_rows'] == PARENT_ROWS
      fail!('publish child rows differ') unless report['compact_child_rows'] == COMPACT_CHILD_ROWS && report['wide_child_rows'] == WIDE_CHILD_ROWS
      fail!('publish aggregate columns/order/state bytes differ') unless
        report['compact_projection_columns'] == %w[group_key min(value) max(value)] &&
        report['wide_projection_columns'] == %w[group_key max(value) count() min(value) sum(value)] &&
        report['compact_aggregate_order'] == %w[min(value) max(value)] &&
        report['wide_aggregate_order'] == %w[max(value) count() min(value) sum(value)] &&
        report['min_state_hex'] == MINS.map { |value| minmax_state(value).unpack1('H*') } &&
        report['max_state_hex'] == MAXS.map { |value| minmax_state(value).unpack1('H*') } &&
        report['sum_state_hex'] == SUMS.map { |value| [value].pack('Q<').unpack1('H*') } &&
        report['count_state_varuint_hex'] == COUNTS.map { |value| varuint(value).unpack1('H*') }
      fail!('publish mark schedule differs') unless report['parent_mark_rows'] == [2, 2, 2, 2, 1] && report['child_mark_rows'] == [2, 1]
      @generated = {}
      {
        'target_compact' => [:compact_parent_wide_minmax_child, report.fetch('compact_parent_path')],
        'target_wide' => [:wide_parent_wide_mixed_child, report.fetch('wide_parent_path')],
      }.each do |table, (id, path)|
        expected = File.join(@catalog_root, 'store', TARGETS.fetch(table).fetch(:uuid)[0, 3], TARGETS.fetch(table).fetch(:uuid), 'detached', TARGETS.fetch(table).fetch(:part))
        fail!("#{table} transform destination differs") unless File.expand_path(path) == expected
        @generated[id] = {path: expected, table: table, part: TARGETS.fetch(table).fetch(:part)}
      end
    end

    def copy_to_detached!
      @generated.each do |id, entry|
        entry[:inventory] = inventory(entry.fetch(:path))
        child_prefix = "#{PROJECTION}.proj/"
        fail!("#{id} omitted its Wide aggregate child") unless entry.fetch(:inventory).fetch(:files).any? { |file| file.fetch(:relative_path).start_with?(child_prefix) }
        table_path = @native_paths.fetch(entry.fetch(:table))
        detached = File.join(table_path, 'detached')
        if File.exist?(detached) || File.symlink?(detached)
          fail!("#{entry.fetch(:table)} detached target is unsafe or occupied") unless File.directory?(detached) && !File.symlink?(detached) && Dir.children(detached).empty?
        else
          Dir.mkdir(detached, 0o700)
        end
        destination = File.join(detached, entry.fetch(:part))
        copy_tree(entry.fetch(:path), destination)
        entry[:native_detached_path] = destination
        entry[:native_detached_inventory] = inventory(destination)
        fail!("#{id} detached copy changed file hashes") unless entry.fetch(:native_detached_inventory) == entry.fetch(:inventory)
      end
    end

    def attach_and_check!
      TARGETS.each do |table, target|
        native("attach_#{table}", "ALTER TABLE #{DATABASE}.#{table} ATTACH PART '#{target.fetch(:part)}';\n".b)
        check = query("check_#{table}", "CHECK TABLE #{DATABASE}.#{table} FORMAT TSV;")
        active = query("attached_#{table}", <<~SQL)
          SELECT name, part_type, toString(rows), toString(marks), path FROM system.parts
          WHERE database='#{DATABASE}' AND table='#{table}' AND active FORMAT TSVRaw;
        SQL
        fields = one_row(active, 5, "#{table} active part")
        assert_bytes!(check, "#{fields[0]}\t1\t\n".b, "#{table} CHECK TABLE")
        fail!("#{table} parent format, rows, or marks differ") unless
          fields[1] == target.fetch(:format) && fields[2].to_i == PARENT_ROWS.size && fields[3].to_i == 6
        parent_path = part_path!(fields[4], table, fields[0])
        projection = query("projection_#{table}", <<~SQL)
          SELECT name, parent_name, part_type, parent_part_type, toString(rows), toString(marks), path
          FROM system.projection_parts WHERE database='#{DATABASE}' AND table='#{table}' AND active FORMAT TSVRaw;
        SQL
        child = one_row(projection, 7, "#{table} active projection child")
        fail!("#{table} projection identity, format, or axes differ") unless
          child[0] == PROJECTION && child[1] == fields[0] && child[2] == 'Wide' && child[3] == target.fetch(:format) &&
          child[4].to_i == KEYS.size && child[5].to_i == 3 && File.expand_path(child[6]) == File.join(parent_path, "#{PROJECTION}.proj")
        attached_inventory = inventory(parent_path)
        generated = @generated.values.find { |entry| entry.fetch(:table) == table }
        fail!("#{table} ATTACH changed generated part file bytes") unless same_original_files?(generated.fetch(:inventory), attached_inventory)
        @attached[table] = {
          part: fields[0], format: fields[1], rows: fields[2].to_i, marks: fields[3].to_i,
          path: parent_path, child_path: File.join(parent_path, "#{PROJECTION}.proj"),
          inventory: attached_inventory, generated_inventory: generated.fetch(:inventory),
        }
      end
    end

    def verify_native_reads!
      result = {}
      TARGETS.each do |table, target|
        parent = query("parent_read_#{table}", <<~SQL)
          SELECT parent_id, group_key, value FROM #{DATABASE}.#{table}
          ORDER BY parent_id SETTINGS optimize_use_projections=0 FORMAT RowBinary;
        SQL
        expected_parent = SOURCE_ROWS.map { |id, group, value| [id + 100, group, value].pack('Q<Q<Q<') }.join.b
        assert_bytes!(parent, expected_parent, "#{table} parent rows with projections disabled")
        disabled = query("grouped_disabled_#{table}", grouped_sql(table, forced: false))
        forced = query("grouped_forced_#{table}", grouped_sql(table, forced: true))
        assert_bytes!(disabled, expected_grouped(target), "#{table} grouped result with projections disabled")
        assert_bytes!(forced, expected_grouped(target), "#{table} forced grouped result")

        schema = query('child_schema_' + table, "DESCRIBE TABLE mergeTreeProjection('#{DATABASE}','#{table}','#{PROJECTION}') FORMAT TSVRaw;")
        columns = schema.lines(chomp: true).map { |line| line.split("\t", -1).take(2) }
        fail!("#{table} canonical child names/order/types differ") unless columns == target.fetch(:columns)
        raw = query("child_raw_#{table}", <<~SQL)
          SELECT * FROM mergeTreeProjection('#{DATABASE}','#{table}','#{PROJECTION}') ORDER BY group_key FORMAT RowBinary;
        SQL
        assert_bytes!(raw, expected_child_rowbinary(target), "#{table} exact aggregate child RowBinary state order")

        explain = query("forced_explain_#{table}", <<~SQL)
          EXPLAIN json=1, description=1, projections=1
          SELECT #{target.fetch(:select)} FROM #{DATABASE}.#{table} GROUP BY group_key ORDER BY group_key
          SETTINGS force_optimize_projection=1, force_optimize_projection_name='#{PROJECTION}' FORMAT JSONEachRow;
        SQL
        plan = forced_projection!(explain, table)
        result[table] = {
          grouped_disabled_sha256: Digest::SHA256.hexdigest(disabled),
          grouped_forced_sha256: Digest::SHA256.hexdigest(forced),
          projection_schema: columns, child_rowbinary_hex: raw.unpack1('H*'), forced_plan: plan,
        }
      end
      result
    end

    def grouped_sql(table, forced:)
      target = TARGETS.fetch(table)
      settings = forced ? "force_optimize_projection=1, force_optimize_projection_name='#{PROJECTION}'" : 'optimize_use_projections=0'
      "SELECT #{target.fetch(:select)} FROM #{DATABASE}.#{table} GROUP BY group_key ORDER BY group_key SETTINGS #{settings} FORMAT TSVRaw;"
    end

    def expected_grouped(target)
      rows = if target.fetch(:variant) == :compact
               KEYS.each_index.map { |index| [KEYS[index], MINS[index], MAXS[index]] }
             else
               WIDE_CHILD_ROWS
             end
      rows.map { |row| row.join("\t") + "\n" }.join.b
    end

    def expected_child_rowbinary(target)
      KEYS.each_index.map do |index|
        fields = {
          'min(value)' => minmax_state(MINS[index]),
          'max(value)' => minmax_state(MAXS[index]),
          'count()' => varuint(COUNTS[index]),
          'sum(value)' => [SUMS[index]].pack('Q<').b,
        }
        [KEYS[index]].pack('Q<').b + target.fetch(:order).map { |name| fields.fetch(name) }.join.b
      end.join.b
    end

    def forced_projection!(stdout, table)
      rows = stdout.lines(chomp: true).filter_map { |line| JSON.parse(line) rescue nil }
      fail!("#{table} EXPLAIN output has no JSON rows") if rows.empty?
      objects = []
      walk_json(rows) { |object| objects << object if object.is_a?(Hash) }
      readers = objects.select { |object| object['Node Type'] == 'ReadFromMergeTree' }
      fail!("#{table} EXPLAIN did not expose exactly one MergeTree read") unless readers.size == 1
      reader = readers.first
      fail!("#{table} EXPLAIN did not name #{PROJECTION}") unless reader['Description'] == PROJECTION
      {node_type: reader['Node Type'], node_id: reader['Node Id'], description: reader['Description']}
    end

    def walk_json(value, &block)
      yield value
      case value
      when Hash then value.each_value { |child| walk_json(child, &block) }
      when Array then value.each { |child| walk_json(child, &block) }
      when String
        parsed = JSON.parse(value) rescue nil
        walk_json(parsed, &block) if parsed.is_a?(Hash) || parsed.is_a?(Array)
      end
    end

    def copy_attached_to_catalog!
      TARGETS.each do |table, target|
        entry = @attached.fetch(table)
        destination = File.join(uuid_path(target.fetch(:uuid)), entry.fetch(:part))
        copy_tree(entry.fetch(:path), destination)
        copied = inventory(destination)
        fail!("#{table} OfflineCatalog copy differs from attached native part") unless copied == entry.fetch(:inventory)
        entry[:catalog_copy] = destination
      end
    end

    def validate_reopen!(report)
      fail!('reopen helper format/status/root differs') unless report.is_a?(Hash) &&
        report['format'] == 'materialized_view_aggregate_projection_w293_helper_v1' && report['action'] == 'reopen' &&
        report['status'] == 'ok' && File.expand_path(report['catalog_root']) == @catalog_root
      pairs = report.fetch('pairs')
      fail!('reopen helper table roster differs') unless pairs.map { |pair| pair.fetch('table') }.sort == TARGETS.keys.sort
      pairs.each do |pair|
        table = pair.fetch('table')
        target = TARGETS.fetch(table)
        attached = @attached.fetch(table)
        expected_children = target.fetch(:variant) == :compact ? COMPACT_CHILD_ROWS : WIDE_CHILD_ROWS
        expected_window = expected_children[1, 2]
        fail!("#{table} offline identity or format differs") unless pair['part_name'] == attached.fetch(:part) &&
          pair['parent_format'] == target.fetch(:format) && pair['child_format'] == 'Wide'
        fail!("#{table} offline full/window values or mark grids differ") unless
          pair['parent_rows'] == PARENT_ROWS && pair['child_rows'] == expected_children &&
          pair['parent_mark_rows'] == [2, 2, 2, 2, 1] && pair['child_mark_rows'] == [2, 1] &&
          pair['parent_window_start_1_count_5'] == PARENT_ROWS[1, 5] &&
          pair['child_window_start_1_count_2'] == expected_window &&
          pair['parent_window_mark_rows'] == [1, 2, 2] && pair['child_window_mark_rows'] == [1, 1]
        fail!("#{table} offline candidate path or lineage differs") unless
          pair['parent_path'] == attached.fetch(:catalog_copy) &&
          pair['child_path'] == File.join(attached.fetch(:catalog_copy), "#{PROJECTION}.proj") &&
          pair['reopen_source'] == 'byte_identical_copy_of_native_attached_part'
      end
    end

    def validate_inputs_unchanged!
      fail!('pinned ClickHouse runtime changed during witness') unless sha_file(@binary) == @binary_sha_before
      fail!('prebuilt Crystal helper changed during witness') unless sha_file(@helper) == @helper_sha_before
      fail!('run_safe guard changed during witness') unless sha_file(@run_safe) == @run_safe_sha_before
      fail!('W293 witness sources changed during witness') unless input_hashes == @input_hashes
      fail!('repository HEAD changed during witness') unless git_revision == @revision_before
      fail!('stock source part changed during witness') unless inventory(@source_path) == @source_inventory
      true
    end

    def native(label, input)
      cell = File.join(@root, 'native', label)
      Dir.mkdir(cell, 0o700)
      args = ['local', '--path', @native_store, '--session_timezone=UTC', '--max_threads=1',
              "--max_memory_usage=#{MEMORY_BYTES}", '--multiquery']
      run_process(label, @binary, args, input, 'ClickHouse local', cell)
    end

    def query(label, sql)
      native(label, (sql.end_with?("\n") ? sql : sql + "\n").b)
    end

    def run_helper(action, args = [])
      cell = File.join(@root, 'helper', action)
      Dir.mkdir(cell, 0o700)
      stdout = run_process("helper_#{action}", @helper, [@catalog_root, action, *args], ''.b, 'prebuilt Crystal helper', cell)
      fail!("helper #{action} must emit one JSON line") unless stdout.lines.size == 1
      JSON.parse(stdout)
    rescue JSON::ParserError => error
      fail!("helper #{action} emitted invalid JSON: #{error.message}")
    end

    def run_process(label, executable, args, input, kind, cell)
      argv = [@run_safe, executable, PROCESS_TIMEOUT_SECONDS.to_s, PROCESS_MEMORY_MIB.to_s, *args]
      env = {
        'RUN_SAFE_PASSTHROUGH_STDIO' => '1',
        'COGNI_RUN_SAFE_MIN_FREE_PCT' => '50',
        'TMPDIR' => File.join(@root, 'tmp'),
        'TMP' => File.join(@root, 'tmp'),
        'TEMP' => File.join(@root, 'tmp'),
      }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      stdout, stderr, status = Open3.capture3(env, *argv, stdin_data: input)
      stdout = stdout.b
      stderr = stderr.b
      fail!("#{label} stdout exceeds capture bound") if stdout.bytesize > MAX_CAPTURE_BYTES
      fail!("#{label} stderr exceeds capture bound") if stderr.bytesize > MAX_CAPTURE_BYTES
      write_new(File.join(cell, 'stdin.bin'), input)
      write_new(File.join(cell, 'stdout.bin'), stdout)
      write_new(File.join(cell, 'stderr.bin'), stderr)
      record = {
        label: label, executable: executable, argv: argv,
        argv_sha256: Digest::SHA256.hexdigest(JSON.generate(argv)), kind: kind,
        run_safe_sha256: @run_safe_sha_before, timeout_seconds: PROCESS_TIMEOUT_SECONDS,
        process_tree_memory_limit_bytes: PROCESS_MEMORY_MIB * 1024 * 1024,
        input_bytes: input.bytesize, input_sha256: Digest::SHA256.hexdigest(input),
        duration_seconds: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3),
        exitstatus: status.exitstatus, termsig: status.termsig,
        stdout_file: File.join(cell, 'stdout.bin'), stdout_bytes: stdout.bytesize,
        stdout_sha256: Digest::SHA256.hexdigest(stdout), stderr_file: File.join(cell, 'stderr.bin'),
        stderr_bytes: stderr.bytesize, stderr_sha256: Digest::SHA256.hexdigest(stderr),
      }
      write_new(File.join(cell, 'process.json'), JSON.pretty_generate(record) + "\n")
      @processes << record
      fail!("#{label}: exit=#{status.exitstatus} signal=#{status.termsig}: #{stderr}") unless status.success? && status.termsig.nil?
      stdout
    rescue Errno::ENOENT => error
      fail!("#{label}: spawn failed: #{error.class}: #{error.message}")
    end

    def store_path!(path)
      full = File.expand_path(path)
      real = File.realpath(full)
      fail!('native data path escaped the isolated ClickHouse store') unless real.start_with?(File.realpath(@native_store) + File::SEPARATOR)
      fail!('native data path is not canonical or is a symlink') unless full == real && !File.symlink?(full)
      real
    end

    def part_path!(path, table, part)
      full = File.expand_path(path)
      expected = File.join(@native_paths.fetch(table), part)
      fail!("#{table} part path differs from system.data_paths") unless full == expected
      fail!("#{table} part path is symlinked or escaped") unless File.realpath(full) == full && !File.symlink?(full)
      full
    end

    def inventory(path)
      real = File.realpath(path)
      files = []
      total = 0
      Find.find(real) do |entry|
        stat = File.lstat(entry)
        fail!("symlink or special entry in part: #{entry}") if stat.symlink? || !(stat.directory? || stat.file?)
        next if stat.directory?
        total += stat.size
        files << {relative_path: entry.delete_prefix(real + File::SEPARATOR), bytes: stat.size, sha256: sha_file(entry)}
        fail!('part file count exceeds bound') if files.size > MAX_PART_FILES
        fail!('part total bytes exceed bound') if total > MAX_PART_BYTES
      end
      {files: files.sort_by { |entry| entry.fetch(:relative_path) }, total_bytes: total}
    end

    def same_original_files?(expected, actual)
      old = expected.fetch(:files).to_h { |entry| [entry.fetch(:relative_path), entry] }
      new = actual.fetch(:files).to_h { |entry| [entry.fetch(:relative_path), entry] }
      old.all? { |path, entry| new[path] == entry }
    end

    def copy_tree(source, destination)
      fail!("copy destination already exists: #{destination}") if File.exist?(destination) || File.symlink?(destination)
      Find.find(source) do |entry|
        stat = File.lstat(entry)
        fail!("symlink or special part entry: #{entry}") if stat.symlink? || !(stat.directory? || stat.file?)
      end
      FileUtils.cp_r(source, destination, preserve: true)
    end

    def one_row(bytes, width, label)
      rows = bytes.lines(chomp: true)
      fail!("#{label} expected one TSV row") unless rows.size == 1
      fields = rows.first.split("\t", -1)
      fail!("#{label} expected #{width} fields") unless fields.size == width
      fields
    end

    def varuint(value)
      bytes = +''.b
      loop do
        byte = value & 0x7f
        value >>= 7
        bytes << (value.zero? ? byte : byte | 0x80)
        break if value.zero?
      end
      bytes.b
    end

    def minmax_state(value)
      "\x01".b + [value].pack('Q<').b
    end

    def assert_bytes!(actual, expected, label)
      fail!("#{label}: byte mismatch; expected #{expected.unpack1('H*')}, observed #{actual.unpack1('H*')}") unless actual == expected
    end

    def uuid_path(uuid)
      File.join(@catalog_root, 'store', uuid[0, 3], uuid)
    end

    def write_new(path, bytes)
      fail!("evidence path already exists: #{path}") if File.exist?(path) || File.symlink?(path)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.binmode; file.write(bytes) }
    end

    def input_hashes
      INPUT_FILES.to_h { |relative| [relative, sha_file(File.join(REPO_ROOT, relative))] }
    end

    def git_revision
      stdout, _stderr, status = Open3.capture3('git', '-C', REPO_ROOT, 'rev-parse', 'HEAD')
      fail!('cannot read repository HEAD') unless status.success?
      stdout.strip
    end

    def write_summary(values)
      return unless @root && File.directory?(@root)
      path = File.join(@root, 'summary.json')
      payload = {format: FORMAT, repository_head: @revision_before, fatal_error: @fatal_error}.merge(values)
      File.write(path, JSON.pretty_generate(payload) + "\n", mode: 'w', perm: 0o600)
    end

    def sha_file(path)
      Digest::SHA256.file(path).hexdigest
    end

    def fail!(message)
      raise Error, message
    end
  end

  def self.run(argv = ARGV)
    options = {binary: BINARY}
    parser = OptionParser.new do |args|
      args.banner = 'Usage: ruby scripts/verify_materialized_view_aggregate_projection_w293.rb --evidence-root PATH --helper PREBUILT --run-safe PATH [--binary PATH]'
      args.on('--evidence-root PATH', 'Fresh evidence directory on /opt/mldata_ssd') { |value| options[:evidence_root] = value }
      args.on('--helper PATH', 'Prebuilt executable W293 Crystal helper') { |value| options[:helper] = value }
      args.on('--run-safe PATH', 'Pinned resource-guard script') { |value| options[:run_safe] = value }
      args.on('--binary PATH', 'Pinned stock ClickHouse executable') { |value| options[:binary] = value }
    end
    parser.parse!(argv)
    Driver.new(options).run ? 0 : 1
  rescue OptionParser::ParseError => error
    warn error.message
    2
  end
end

exit VerifyMaterializedViewAggregateProjectionW293.run
