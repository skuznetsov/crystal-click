#!/usr/bin/env ruby
# Bounded W296 stock-native -> caller transform -> Compact aggregate projection witness.
# The Crystal helper must already be built; this runner never invokes a build.

require 'base64'
require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'open3'
require 'optparse'

module VerifyMaterializedViewAggregateProjectionW296
  extend self

  REPO_ROOT = File.expand_path('..', __dir__).freeze
  FORMAT = 'materialized_view_aggregate_projection_w296_native_v1'.freeze
  HELPER_FORMAT = 'materialized_view_aggregate_projection_w296_helper_v1'.freeze
  BINARY = '/opt/mldata_ssd/cache/crystal-click-w283.PDWAiK/recovery/runtime/clickhouse'.freeze
  BINARY_SHA256 = '5bb43958f4c0806cc363b84b9858e7206e56ac80263a24acc704271322e531ae'.freeze
  VERSION = '26.10.1.1201'.freeze
  REVISION = '54515'.freeze
  RUN_SAFE_SHA256 = 'fbfa0fd9d717eb24c1a3f829d464188110e505c7ae311eee2e95cbe7cefab011'.freeze

  DATABASE = 'lab'.freeze
  DATABASE_UUID = 'f2960000-7b7f-4e2f-9e44-dc13a87b8801'.freeze
  SOURCE_UUID = 'f2960000-7b7f-4e2f-9e44-dc13a87b8802'.freeze
  COMPACT_TARGET_UUID = 'f2960000-7b7f-4e2f-9e44-dc13a87b8803'.freeze
  WIDE_TARGET_UUID = 'f2960000-7b7f-4e2f-9e44-dc13a87b8804'.freeze
  COMPACT_VIEW_UUID = 'f2960000-7b7f-4e2f-9e44-dc13a87b8805'.freeze
  WIDE_VIEW_UUID = 'f2960000-7b7f-4e2f-9e44-dc13a87b8806'.freeze
  COMPACT_CONTROL_UUID = 'f2960000-7b7f-4e2f-9e44-dc13a87b8807'.freeze
  WIDE_CONTROL_UUID = 'f2960000-7b7f-4e2f-9e44-dc13a87b8808'.freeze

  SOURCE_PART = 'all_1_1_0'.freeze
  WIDE_PART = 'all_9_9_0'.freeze
  COMPACT_PART = 'all_10_10_0'.freeze
  PROJECTION = 'by_group'.freeze
  ATTACH_SIDECAR = 'invalidated_system_columns.txt'.freeze
  ATTACH_SIDECAR_BYTES = "_block_offset\n_block_number\n".b.freeze
  ATTACH_SIDECAR_SHA256 = '7409424ab45090c1261e622f7423393905102e7e8cba36a6db88eb513ce1e06c'.freeze

  ASYMMETRIC = 0x0102030405060708
  UINT64_MAX = (1 << 64) - 1
  GROUP_KEYS = [7, 42, ASYMMETRIC, 0x8000000000000001, UINT64_MAX].freeze
  GROUP_COUNTS = [1, 130, 2, 7, 3].freeze
  SOURCE_ROWS = begin
    rows = []
    id = 1
    GROUP_KEYS.each_with_index do |group, index|
      GROUP_COUNTS.fetch(index).times do
        value = ((id * 37) ^ ASYMMETRIC) & UINT64_MAX
        value = {1 => 0, 2 => 1, 3 => UINT64_MAX, 132 => ASYMMETRIC,
                 133 => 42, 141 => ASYMMETRIC, 142 => UINT64_MAX, 143 => 17}.fetch(id, value)
        rows << [id, group, value].freeze
        id += 1
      end
    end
    rows.freeze
  end
  PARENT_ROWS = SOURCE_ROWS.map { |id, group, value| [id + 100, group, value].freeze }.freeze
  SOURCE_ROW_COUNT = SOURCE_ROWS.size
  PARENT_DATA_MARKS = (SOURCE_ROW_COUNT + 1) / 2
  PARENT_SYSTEM_MARKS = PARENT_DATA_MARKS + 1
  PARENT_MARK_ROWS = (Array.new(PARENT_DATA_MARKS - 1, 2) + [1]).freeze
  CHILD_DATA_MARK_ROWS = [2, 2, 1].freeze
  CHILD_SYSTEM_MARKS = CHILD_DATA_MARK_ROWS.size + 1
  FILTER_KEY = 42

  AGGREGATES = begin
    grouped = SOURCE_ROWS.group_by { |_id, group, _value| group }
    GROUP_KEYS.to_h do |key|
      values = grouped.fetch(key).map(&:last)
      sum = values.sum & UINT64_MAX
      [key, {count: values.size, sum: sum, min: values.min, max: values.max}.freeze]
    end.freeze
  end
  COMPACT_AGGREGATES = %w[max(value) sum(value) min(value)].freeze
  WIDE_AGGREGATES = %w[min(value) count() sum(value) max(value)].freeze
  COMPACT_COLUMNS = [
    ['group_key', 'UInt64'],
    ['max(value)', 'AggregateFunction(max, UInt64)'],
    ['sum(value)', 'AggregateFunction(sum, UInt64)'],
    ['min(value)', 'AggregateFunction(min, UInt64)'],
  ].freeze
  WIDE_COLUMNS = [
    ['group_key', 'UInt64'],
    ['min(value)', 'AggregateFunction(min, UInt64)'],
    ['count()', 'AggregateFunction(count)'],
    ['sum(value)', 'AggregateFunction(sum, UInt64)'],
    ['max(value)', 'AggregateFunction(max, UInt64)'],
  ].freeze
  TARGETS = {
    'target_compact' => {
      uuid: COMPACT_TARGET_UUID, part: COMPACT_PART, format: 'Compact', compressed: true,
      control: 'control_compact', control_uuid: COMPACT_CONTROL_UUID,
      min_rows: 1000, compress_marks: 1, aggregates: COMPACT_AGGREGATES,
      columns: COMPACT_COLUMNS,
      select: 'group_key, max(value), sum(value), min(value)',
      ddl: 'SELECT max(value) AS maximum, sum(value) AS total, min(value) AS minimum GROUP BY group_key',
    }.freeze,
    'target_wide' => {
      uuid: WIDE_TARGET_UUID, part: WIDE_PART, format: 'Wide', compressed: false,
      control: 'control_wide', control_uuid: WIDE_CONTROL_UUID,
      min_rows: 0, compress_marks: 0, aggregates: WIDE_AGGREGATES,
      columns: WIDE_COLUMNS,
      select: 'group_key, min(value), count(), sum(value), max(value)',
      ddl: 'SELECT group_key, min(value) AS minimum, count() AS n, sum(value) AS total, max(value) AS maximum GROUP BY group_key',
    }.freeze,
  }.freeze

  MEMORY_BYTES = 536_870_912
  PROCESS_MEMORY_MIB = 2048
  PROCESS_TIMEOUT_SECONDS = 90
  MAX_CAPTURE_BYTES = 16 * 1024 * 1024
  MAX_PART_FILES = 256
  MAX_PART_BYTES = 16 * 1024 * 1024
  INPUT_FILES = %w[
    scripts/verify_materialized_view_aggregate_projection_w296.rb
    scripts/check_materialized_view_aggregate_projection_w296.cr
  ].freeze

  class Error < StandardError; end

  class Driver
    def initialize(options)
      @root_arg = options.fetch(:evidence_root)
      @binary_arg = options.fetch(:binary)
      @helper_arg = options.fetch(:helper)
      @run_safe_arg = options.fetch(:run_safe)
      @processes = []
      @metadata = {}
      @native_paths = {}
      @controls = {}
      @generated = {}
      @attached = {}
    end

    def run
      prepare!
      create_source!
      insert_source!
      source = verify_source!
      create_targets!
      create_controls!
      controls = verify_controls!
      catalog = build_catalog!
      stock_reopen = reopen_stock_controls!
      publish = run_helper('publish')
      validate_publish!(publish)
      verify_generated_parts!
      copy_to_detached!
      attach_and_check!
      native_checks = verify_native_reads!
      copy_attached_to_catalog!
      reopen = run_helper('reopen', [@attached.fetch('target_wide').fetch(:part), @attached.fetch('target_compact').fetch(:part)])
      validate_reopen!(reopen, expected_part: SOURCE_PART,
                        expected_paths: @attached.to_h { |table, entry| [table, entry.fetch(:catalog_copy)] })
      validate_inputs_unchanged!
      write_summary(
        status: 'wide_and_compact_parents_with_compact_aggregate_children_attached_checked_and_offline_reopened',
        binary: {path: @binary, sha256: @binary_sha_before, version: VERSION, revision: REVISION},
        helper: {path: @helper, sha256: @helper_sha_before},
        run_safe: {path: @run_safe, sha256: @run_safe_sha_before},
        source: source, stock_controls: controls, offline_catalog: catalog,
        stock_offline_reopen: stock_reopen,
        published_projection: publish, generated_parts: @generated,
        attached_parts: @attached, native_checks: native_checks,
        offline_reopen: reopen, invocations: @processes,
        cleanup_owner: 'orchestrator', retained_evidence_root: @root,
      )
      puts "W296 Compact AggregateFunction projection witness passed; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error = "#{error.class}: #{error.message}"
      write_summary(status: 'witness_failure_or_observations_differ', fatal_error: @fatal_error,
                    cleanup_owner: 'orchestrator', retained_evidence_root: @root) rescue nil
      warn "W296 probe failure (process failure is not native format evidence): #{@fatal_error}"
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
      %w[native catalog helper tmp cache].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      @native_store = File.join(@root, 'native', 'store')
      @catalog_root = File.join(@root, 'catalog', 'offline_catalog')
    end

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
      stat = File.lstat(full)
      fail!('evidence root must be a plain owned directory on the selected volume') unless
        File.realpath(full) == full && stat.directory? && !stat.symlink? && stat.uid == Process.uid && stat.dev == parent_stat.dev
      full
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
        ) ENGINE = MergeTree ORDER BY source_id
        SETTINGS index_granularity=2, min_rows_for_wide_part=0, min_bytes_for_wide_part=0,
                 compress_marks=0, compress_primary_key=0, replace_long_file_name_to_hash=0;
        SELECT version(), revision() FORMAT TSVRaw;
      SQL
      assert_bytes!(native('create_source', sql.b), "#{VERSION}\t#{REVISION}\n".b, 'pinned native version/revision')
    end

    def insert_source!
      values = SOURCE_ROWS.map { |row| "(#{row.join(',')})" }.join(",\n")
      output = native('insert_source', "INSERT INTO #{DATABASE}.source VALUES\n#{values};\n".b)
      fail!('source VALUES insert emitted unexpected stdout') unless output.empty?
    end

    def verify_source!
      check = query('source_check', "CHECK TABLE #{DATABASE}.source FORMAT TSV;")
      assert_bytes!(check, "#{SOURCE_PART}\t1\t\n".b, 'stock source CHECK TABLE')
      raw = query('source_rows', "SELECT source_id, source_group, value FROM #{DATABASE}.source ORDER BY source_id FORMAT RowBinary;")
      assert_bytes!(raw, SOURCE_ROWS.map { |row| row.pack('Q<Q<Q<') }.join.b, 'stock source fixture RowBinary')
      fields = one_row(query('source_part', <<~SQL), 5, 'source part')
        SELECT name, part_type, toString(rows), toString(marks), path
        FROM system.parts WHERE database='#{DATABASE}' AND table='source' AND active FORMAT TSVRaw;
      SQL
      fail!('source part identity, type, rows, or marks differ') unless
        fields[0] == SOURCE_PART && fields[1] == 'Wide' && fields[2].to_i == SOURCE_ROW_COUNT && fields[3].to_i == PARENT_SYSTEM_MARKS
      data_path = query('source_data_path', "SELECT data_paths[1] FROM system.tables WHERE database='#{DATABASE}' AND name='source' FORMAT TSVRaw;").strip
      @native_paths['source'] = store_path!(data_path)
      @source_path = part_path!(fields[4], 'source', SOURCE_PART)
      @source_inventory = inventory(@source_path)
      {part: SOURCE_PART, format: fields[1], rows: fields[2].to_i, marks: fields[3].to_i,
       path: @source_path, rowbinary_sha256: Digest::SHA256.hexdigest(raw), inventory: @source_inventory}
    end

    def create_targets!
      sql = TARGETS.map do |table, target|
        <<~SQL
          CREATE TABLE #{DATABASE}.#{table} UUID '#{target.fetch(:uuid)}'
          (
              parent_id UInt64, group_key UInt64, value UInt64,
              PROJECTION #{PROJECTION} (#{target.fetch(:ddl)}) WITH SETTINGS (min_rows_for_wide_part = 1000, index_granularity = 2)
          ) ENGINE = MergeTree ORDER BY parent_id
          SETTINGS index_granularity=2, min_rows_for_wide_part=#{target.fetch(:min_rows)}, min_bytes_for_wide_part=0;
        SQL
      end.join("\n")
      sql << <<~SQL
        CREATE MATERIALIZED VIEW #{DATABASE}.view_wide UUID '#{WIDE_VIEW_UUID}' TO #{DATABASE}.target_wide
        (parent_id UInt64, group_key UInt64, value UInt64)
        AS SELECT source_id + 100 AS parent_id, source_group AS group_key, value FROM #{DATABASE}.source;
        CREATE MATERIALIZED VIEW #{DATABASE}.view_compact UUID '#{COMPACT_VIEW_UUID}' TO #{DATABASE}.target_compact
        (parent_id UInt64, group_key UInt64, value UInt64)
        AS SELECT source_id + 100 AS parent_id, source_group AS group_key, value FROM #{DATABASE}.source;
      SQL
      native('create_targets', sql.b)
      TARGETS.each_key do |table|
        fail!("#{table} target was not empty") unless query("target_count_#{table}", "SELECT toString(count()) FROM #{DATABASE}.#{table} FORMAT TSVRaw;").strip == '0'
        fail!("#{table} unexpectedly has active parts") unless
          query("target_parts_#{table}", "SELECT toString(count()) FROM system.parts WHERE database='#{DATABASE}' AND table='#{table}' AND active FORMAT TSVRaw;").strip == '0'
      end
      @native_paths.merge!(query_target_paths(%w[target_compact target_wide]))
      metadata_lines = query('metadata_paths', <<~SQL).lines(chomp: true)
        SELECT name, base64Encode(metadata_path) FROM system.tables
        WHERE database='#{DATABASE}' AND name IN ('source','target_compact','target_wide','view_compact','view_wide')
        ORDER BY name FORMAT TSVRaw;
      SQL
      fail!('native source/target/MV metadata roster differs') unless metadata_lines.size == 5
      metadata_lines.each do |line|
        name, encoded = line.split("\t", -1)
        fail!('native metadata row is malformed') unless encoded
        @metadata[name] = Base64.strict_decode64(encoded)
      rescue ArgumentError
        fail!('native metadata path is malformed base64')
      end
    end

    def create_controls!
      sql = TARGETS.map do |_table, target|
        <<~SQL
          CREATE TABLE #{DATABASE}.#{target.fetch(:control)} UUID '#{target.fetch(:control_uuid)}'
          (
              parent_id UInt64, group_key UInt64, value UInt64,
              PROJECTION #{PROJECTION} (#{target.fetch(:ddl)}) WITH SETTINGS (min_rows_for_wide_part = 1000, index_granularity = 2)
          ) ENGINE = MergeTree ORDER BY parent_id
          SETTINGS index_granularity=2, min_rows_for_wide_part=#{target.fetch(:min_rows)}, min_bytes_for_wide_part=0,
                   compress_marks=#{target.fetch(:compress_marks)}, compress_primary_key=0, replace_long_file_name_to_hash=0;
        SQL
      end.join("\n")
      native('create_controls', sql.b)
      values = PARENT_ROWS.map { |row| "(#{row.join(',')})" }.join(",\n")
      TARGETS.each_value do |target|
        out = native("insert_#{target.fetch(:control)}", "INSERT INTO #{DATABASE}.#{target.fetch(:control)} VALUES\n#{values};\n".b)
        fail!("#{target.fetch(:control)} VALUES insert emitted unexpected stdout") unless out.empty?
      end
      @native_paths.merge!(query_target_paths(TARGETS.values.map { |target| target.fetch(:control) }))
    end

    def query_target_paths(names)
      sql_names = names.map { |name| "'#{name}'" }.join(',')
      lines = query('target_paths_' + names.join('_'), <<~SQL).lines(chomp: true)
        SELECT name, arrayElement(data_paths,1) FROM system.tables
        WHERE database='#{DATABASE}' AND name IN (#{sql_names}) ORDER BY name FORMAT TSVRaw;
      SQL
      fail!('native target data path roster differs') unless lines.size == names.size
      lines.to_h do |line|
        name, path = line.split("\t", -1)
        fail!('native target data path row is malformed') unless names.include?(name) && path
        [name, store_path!(path)]
      end
    end

    def verify_controls!
      TARGETS.to_h do |table, target|
        name = target.fetch(:control)
        check = query("check_#{name}", "CHECK TABLE #{DATABASE}.#{name} FORMAT TSV;")
        fields = one_row(query("control_parent_#{name}", <<~SQL), 5, "#{name} active parent")
          SELECT name, part_type, toString(rows), toString(marks), path FROM system.parts
          WHERE database='#{DATABASE}' AND table='#{name}' AND active FORMAT TSVRaw;
        SQL
        assert_bytes!(check, "#{fields[0]}\t1\t\n".b, "#{name} CHECK TABLE")
        fail!("#{name} parent identity/type/rows/marks differ") unless
          fields[0] == SOURCE_PART && fields[1] == target.fetch(:format) && fields[2].to_i == SOURCE_ROW_COUNT && fields[3].to_i == PARENT_SYSTEM_MARKS
        parent_path = part_path!(fields[4], name, SOURCE_PART)
        child = one_row(query("control_projection_#{name}", <<~SQL), 7, "#{name} stock projection")
          SELECT name, parent_name, part_type, parent_part_type, toString(rows), toString(marks), path
          FROM system.projection_parts WHERE database='#{DATABASE}' AND table='#{name}' AND active FORMAT TSVRaw;
        SQL
        child_path = File.expand_path(child[6])
        fail!("#{name} stock Compact child identity/type/axes differ") unless
          child[0] == PROJECTION && child[1] == fields[0] && child[2] == 'Compact' && child[3] == target.fetch(:format) &&
          child[4].to_i == GROUP_KEYS.size && child[5].to_i == CHILD_SYSTEM_MARKS && child_path == File.join(parent_path, "#{PROJECTION}.proj")
        assert_format!(parent_path, target.fetch(:format), "#{name} stock parent", compressed: target.fetch(:compressed))
        assert_format!(child_path, 'Compact', "#{name} stock projection", compressed: target.fetch(:compressed))
        schema = child_schema(name)
        fail!("#{name} stock projection schema differs") unless schema == target.fetch(:columns)
        index_bytes = File.binread(File.join(child_path, 'primary.idx'))
        assert_bytes!(index_bytes, expected_primary_index, "#{name} stock child primary.idx")
        raw = query("control_raw_#{name}", <<~SQL)
          SELECT * FROM mergeTreeProjection('#{DATABASE}','#{name}','#{PROJECTION}') ORDER BY group_key FORMAT RowBinary;
        SQL
        assert_bytes!(raw, expected_child_rowbinary(target), "#{name} stock child RowBinary states")
        parent_inventory = inventory(parent_path)
        @controls[name] = {part: fields[0], parent_path: parent_path, child_path: child_path,
                           primary_index: index_bytes, child_rowbinary: raw, inventory: parent_inventory}
        [table, {control_table: name, part: fields[0], parent_format: fields[1], parent_rows: fields[2].to_i,
                 parent_system_marks_including_terminal_index_entry: fields[3].to_i,
                 child_format: child[2], child_parent_format: child[3], child_rows: child[4].to_i,
                 child_system_marks_including_terminal_index_entry: child[5].to_i,
                 child_data_mark_rows: CHILD_DATA_MARK_ROWS, compressed_marks: target.fetch(:compressed),
                 primary_index_hex: index_bytes.unpack1('H*'), schema: schema,
                 child_rowbinary_hex: raw.unpack1('H*'), path: child_path}]
      end
    end

    def build_catalog!
      database_path = uuid_path(DATABASE_UUID)
      source_path = uuid_path(SOURCE_UUID)
      target_paths = TARGETS.to_h { |name, target| [name, uuid_path(target.fetch(:uuid))] }
      [database_path, source_path, *target_paths.values].each { |path| FileUtils.mkdir_p(path, mode: 0o700) }
      FileUtils.mkdir_p(File.join(@catalog_root, 'metadata'), mode: 0o700)
      [source_path, *target_paths.values].each { |path| write_new(File.join(path, 'format_version.txt'), "1\n") }
      target_paths.each_value { |path| FileUtils.mkdir_p(File.join(path, 'detached'), mode: 0o700) }
      write_new(File.join(@catalog_root, 'metadata', 'lab.sql'), "ATTACH DATABASE _ UUID '#{DATABASE_UUID}'\nENGINE = Atomic\n")
      identities = {
        'source' => [SOURCE_UUID, 'TABLE'],
        'target_compact' => [COMPACT_TARGET_UUID, 'TABLE'],
        'target_wide' => [WIDE_TARGET_UUID, 'TABLE'],
        'view_compact' => [COMPACT_VIEW_UUID, 'MATERIALIZED VIEW'],
        'view_wide' => [WIDE_VIEW_UUID, 'MATERIALIZED VIEW'],
      }
      identities.each do |name, (uuid, kind)|
        metadata_path = File.expand_path(@metadata.fetch(name), @native_store)
        real = File.realpath(metadata_path)
        fail!("#{name} metadata path escaped the isolated ClickHouse store") unless real.start_with?(File.realpath(@native_store) + File::SEPARATOR)
        ddl = File.binread(real)
        fail!("persisted #{name} metadata is oversized or invalid UTF-8") if ddl.bytesize > 1_048_576 || !ddl.dup.force_encoding(Encoding::UTF_8).valid_encoding?
        fail!("persisted #{name} metadata identity differs") unless /\A\s*ATTACH\s+#{Regexp.escape(kind)}\s+_\s+UUID\s+'#{Regexp.escape(uuid)}'/im.match?(ddl)
        write_new(File.join(database_path, "#{name}.sql"), ddl)
      end
      source_copy = File.join(source_path, SOURCE_PART)
      copy_tree(@source_path, source_copy)
      copied = inventory(source_copy)
      fail!('OfflineCatalog source part copy differs') unless copied == @source_inventory
      {root: @catalog_root, source_copy: source_copy, source_inventory: copied}
    end

    def reopen_stock_controls!
      @stock_catalog_root = File.join(@root, 'catalog', 'stock_native_copy')
      copy_tree(@catalog_root, @stock_catalog_root)
      copied_parts = TARGETS.to_h do |table, target|
        source = @controls.fetch(target.fetch(:control)).fetch(:parent_path)
        destination = File.join(uuid_path(target.fetch(:uuid), @stock_catalog_root), SOURCE_PART)
        copy_tree(source, destination)
        copied = inventory(destination)
        expected = @controls.fetch(target.fetch(:control)).fetch(:inventory)
        fail!("#{table} stock projection part copy differs") unless copied == expected
        [table, {path: destination, inventory: copied}]
      end
      report = run_helper('reopen', [SOURCE_PART, SOURCE_PART],
                          catalog_root: @stock_catalog_root, run_name: 'reopen_stock')
      validate_reopen!(report, expected_part: SOURCE_PART,
                        expected_paths: copied_parts.to_h { |table, entry| [table, entry.fetch(:path)] })
      {root: @stock_catalog_root, parts: copied_parts, reopen: report}
    end

    def validate_publish!(report)
      fail!('publish helper format/status differs') unless report.is_a?(Hash) &&
        report['format'] == HELPER_FORMAT && report['action'] == 'publish' && report['status'] == 'ok'
      fail!('publish source or transformed parent rows differ') unless report['source_row_count'] == SOURCE_ROW_COUNT &&
        report['parent_rows'] == PARENT_ROWS.map { |row| row.map(&:to_s) }
      expected_groups = GROUP_KEYS.map { |key| AGGREGATES.fetch(key) }
      fail!('publish group keys or UInt64 aggregate values differ') unless
        report['group_keys'] == GROUP_KEYS.map(&:to_s) &&
        report['group_counts'] == expected_groups.map { |item| item.fetch(:count).to_s } &&
        report['group_sums'] == expected_groups.map { |item| item.fetch(:sum).to_s } &&
        report['group_mins'] == expected_groups.map { |item| item.fetch(:min).to_s } &&
        report['group_maxs'] == expected_groups.map { |item| item.fetch(:max).to_s }
      fail!('publish aggregate declaration order, bytes, or mark schedule differs') unless
        report['compact_projection_columns'] == %w[group_key max(value) sum(value) min(value)] &&
        report['wide_projection_columns'] == %w[group_key min(value) count() sum(value) max(value)] &&
        report['compact_aggregate_order'] == COMPACT_AGGREGATES && report['wide_aggregate_order'] == WIDE_AGGREGATES &&
        report['min_state_hex'] == expected_groups.map { |item| minmax_state(item.fetch(:min)).unpack1('H*') } &&
        report['max_state_hex'] == expected_groups.map { |item| minmax_state(item.fetch(:max)).unpack1('H*') } &&
        report['sum_state_hex'] == expected_groups.map { |item| [item.fetch(:sum)].pack('Q<').unpack1('H*') } &&
        report['count_state_varuint_hex'] == expected_groups.map { |item| varuint(item.fetch(:count)).unpack1('H*') } &&
        report['child_mark_rows'] == CHILD_DATA_MARK_ROWS && report['parent_mark_count'] == PARENT_DATA_MARKS && report['parent_tail_rows'] == 1
      @generated = TARGETS.to_h do |table, target|
        field = table == 'target_wide' ? 'wide_parent_path' : 'compact_parent_path'
        expected = File.join(uuid_path(target.fetch(:uuid)), 'detached', target.fetch(:part))
        fail!("#{table} transform destination differs") unless File.expand_path(report.fetch(field)) == expected
        [table, {path: expected, table: table, part: target.fetch(:part), format: target.fetch(:format), compressed: target.fetch(:compressed)}]
      end
    end

    def verify_generated_parts!
      TARGETS.each do |table, target|
        entry = @generated.fetch(table)
        child_path = File.join(entry.fetch(:path), "#{PROJECTION}.proj")
        assert_format!(entry.fetch(:path), target.fetch(:format), "#{table} generated parent", compressed: target.fetch(:compressed))
        assert_format!(child_path, 'Compact', "#{table} generated child", compressed: target.fetch(:compressed))
        index = File.binread(File.join(child_path, 'primary.idx'))
        assert_bytes!(index, expected_primary_index, "#{table} generated primary.idx vs literal")
        control = @controls.fetch(target.fetch(:control))
        assert_bytes!(index, control.fetch(:primary_index), "#{table} generated primary.idx vs stock control")
        entry[:child_primary_index_hex] = index.unpack1('H*')
        entry[:inventory] = inventory(entry.fetch(:path))
        entry[:child_inventory] = inventory(child_path)
      end
    end

    def copy_to_detached!
      @generated.each do |table, entry|
        detached = File.join(@native_paths.fetch(table), 'detached')
        if File.exist?(detached) || File.symlink?(detached)
          fail!("#{table} detached destination is unsafe or occupied") unless File.directory?(detached) && !File.symlink?(detached) && Dir.children(detached).empty?
        else
          Dir.mkdir(detached, 0o700)
        end
        destination = File.join(detached, entry.fetch(:part))
        copy_tree(entry.fetch(:path), destination)
        entry[:native_detached_path] = destination
        entry[:native_detached_inventory] = inventory(destination)
        fail!("#{table} detached copy changed bytes") unless entry.fetch(:native_detached_inventory) == entry.fetch(:inventory)
      end
    end

    def attach_and_check!
      TARGETS.each do |table, target|
        native("attach_#{table}", "ALTER TABLE #{DATABASE}.#{table} ATTACH PART '#{target.fetch(:part)}';\n".b)
        check = query("check_#{table}", "CHECK TABLE #{DATABASE}.#{table} FORMAT TSV;")
        fields = one_row(query("attached_parent_#{table}", <<~SQL), 5, "#{table} active parent")
          SELECT name, part_type, toString(rows), toString(marks), path FROM system.parts
          WHERE database='#{DATABASE}' AND table='#{table}' AND active FORMAT TSVRaw;
        SQL
        assert_bytes!(check, "#{fields[0]}\t1\t\n".b, "#{table} CHECK TABLE")
        fail!("#{table} ATTACH-renamed parent identity/type/rows/marks differ") unless
          fields[0] == SOURCE_PART && fields[1] == target.fetch(:format) &&
          fields[2].to_i == SOURCE_ROW_COUNT && fields[3].to_i == PARENT_SYSTEM_MARKS
        parent_path = part_path!(fields[4], table, fields[0])
        child = one_row(query("attached_projection_#{table}", <<~SQL), 7, "#{table} active projection child")
          SELECT name, parent_name, part_type, parent_part_type, toString(rows), toString(marks), path
          FROM system.projection_parts WHERE database='#{DATABASE}' AND table='#{table}' AND active FORMAT TSVRaw;
        SQL
        child_path = File.expand_path(child[6])
        fail!("#{table} attached child identity/type/rows/marks/path differ") unless
          child[0] == PROJECTION && child[1] == fields[0] && child[2] == 'Compact' && child[3] == target.fetch(:format) &&
          child[4].to_i == GROUP_KEYS.size && child[5].to_i == CHILD_SYSTEM_MARKS && child_path == File.join(parent_path, "#{PROJECTION}.proj")
        generated = @generated.fetch(table)
        attached_inventory = inventory(parent_path)
        assert_attached_files_preserved!(generated.fetch(:inventory), attached_inventory, table, parent_path)
        @attached[table] = {part: fields[0], format: fields[1], rows: fields[2].to_i, marks: fields[3].to_i,
                            path: parent_path, child_path: child_path, inventory: attached_inventory,
                            generated_inventory: generated.fetch(:inventory)}
      end
    end

    def verify_native_reads!
      results = {}
      TARGETS.each do |table, target|
        parent = query("parent_read_#{table}", <<~SQL)
          SELECT parent_id, group_key, value FROM #{DATABASE}.#{table}
          ORDER BY parent_id SETTINGS optimize_use_projections=0 FORMAT RowBinary;
        SQL
        expected_parent = PARENT_ROWS.map { |row| row.pack('Q<Q<Q<') }.join.b
        assert_bytes!(parent, expected_parent, "#{table} parent rows with projections disabled")
        full_disabled = query("grouped_disabled_#{table}", grouped_sql(table, forced: false, filtered: false))
        full_forced = query("grouped_forced_#{table}", grouped_sql(table, forced: true, filtered: false))
        filter_disabled = query("filter_disabled_#{table}", grouped_sql(table, forced: false, filtered: true))
        filter_forced = query("filter_forced_#{table}", grouped_sql(table, forced: true, filtered: true))
        assert_bytes!(full_disabled, expected_grouped(target), "#{table} full parent grouping")
        assert_bytes!(full_forced, expected_grouped(target), "#{table} full forced projection grouping")
        assert_bytes!(filter_disabled, expected_filtered(target), "#{table} filtered parent grouping")
        assert_bytes!(filter_forced, expected_filtered(target), "#{table} filtered forced projection grouping")

        schema = child_schema(table)
        fail!("#{table} canonical Compact child names/order/types differ") unless schema == target.fetch(:columns)
        raw = query("child_raw_#{table}", <<~SQL)
          SELECT * FROM mergeTreeProjection('#{DATABASE}','#{table}','#{PROJECTION}') ORDER BY group_key FORMAT RowBinary;
        SQL
        assert_bytes!(raw, expected_child_rowbinary(target), "#{table} exact aggregate child RowBinary state order")
        control = @controls.fetch(target.fetch(:control))
        assert_bytes!(raw, control.fetch(:child_rowbinary), "#{table} generated child RowBinary vs stock")
        attached_index = File.binread(File.join(@attached.fetch(table).fetch(:child_path), 'primary.idx'))
        assert_bytes!(attached_index, expected_primary_index, "#{table} attached primary.idx vs literal")
        assert_bytes!(attached_index, control.fetch(:primary_index), "#{table} attached primary.idx vs stock")
        full_plan = forced_projection!(query("explain_full_#{table}", explain_sql(table, filtered: false)), table, filtered: false)
        filter_plan = forced_projection!(query("explain_filter_#{table}", explain_sql(table, filtered: true)), table,
                                         filtered: true, expected_keys: ['group_key'])
        results[table] = {
          parent_rowbinary_sha256: Digest::SHA256.hexdigest(parent),
          full_parent_sha256: Digest::SHA256.hexdigest(full_disabled),
          full_forced_sha256: Digest::SHA256.hexdigest(full_forced),
          filtered_parent_sha256: Digest::SHA256.hexdigest(filter_disabled),
          filtered_forced_sha256: Digest::SHA256.hexdigest(filter_forced),
          projection_schema: schema, child_rowbinary_hex: raw.unpack1('H*'),
          attached_primary_index_hex: attached_index.unpack1('H*'),
          stock_primary_index_hex: control.fetch(:primary_index).unpack1('H*'),
          full_forced_plan: full_plan, filtered_forced_plan: filter_plan,
        }
      end
      results
    end

    def grouped_sql(table, forced:, filtered:)
      target = TARGETS.fetch(table)
      settings = forced ? "force_optimize_projection=1, force_optimize_projection_name='#{PROJECTION}'" : 'optimize_use_projections=0'
      where = filtered ? " WHERE group_key=#{FILTER_KEY}" : ''
      "SELECT #{target.fetch(:select)} FROM #{DATABASE}.#{table}#{where} GROUP BY group_key ORDER BY group_key SETTINGS #{settings} FORMAT TSVRaw;"
    end

    def explain_sql(table, filtered:)
      target = TARGETS.fetch(table)
      where = filtered ? " WHERE group_key=#{FILTER_KEY}" : ''
      <<~SQL
        EXPLAIN json=1, description=1, projections=1, indexes=1
        SELECT #{target.fetch(:select)} FROM #{DATABASE}.#{table}#{where} GROUP BY group_key ORDER BY group_key
        SETTINGS force_optimize_projection=1, force_optimize_projection_name='#{PROJECTION}' FORMAT JSONEachRow;
      SQL
    end

    def expected_grouped(target, only_key = nil)
      keys = only_key ? [only_key] : GROUP_KEYS
      rows = keys.map { |key| [key] + target.fetch(:aggregates).map { |name| aggregate_value(key, name) } }
      rows.map { |row| row.join("\t") + "\n" }.join.b
    end

    def expected_filtered(target)
      expected_grouped(target, FILTER_KEY)
    end

    def forced_projection!(stdout, table, filtered:, expected_keys: nil)
      rows = stdout.lines(chomp: true).filter_map { |line| JSON.parse(line) rescue nil }
      fail!("#{table} EXPLAIN output has no JSON rows") if rows.empty?
      objects = []
      walk_json(rows) { |object| objects << object if object.is_a?(Hash) }
      readers = objects.select { |object| object['Node Type'] == 'ReadFromMergeTree' }
      fail!("#{table} EXPLAIN did not expose exactly one MergeTree read") unless readers.size == 1
      reader = readers.first
      fail!("#{table} EXPLAIN did not name #{PROJECTION}") unless reader['Description'] == PROJECTION
      result = {node_type: reader['Node Type'], node_id: reader['Node Id'], description: reader['Description'], filtered: filtered}
      if filtered
        indexes = reader['Indexes']
        indexes = JSON.parse(indexes) if indexes.is_a?(String)
        primary = Array(indexes).find { |entry| entry.is_a?(Hash) && entry['Type'] == 'PrimaryKey' }
        fail!("#{table} filtered EXPLAIN omitted the projection primary key") unless primary
        fail!("#{table} filtered EXPLAIN key order differs") unless primary['Keys'] == expected_keys
        initial = Integer(primary.fetch('Initial Granules'))
        selected = Integer(primary.fetch('Selected Granules'))
        fail!("#{table} filtered EXPLAIN granules differ from the 1/3 witness") unless initial == 3 && selected == 1
        result[:primary_key] = primary
      end
      result
    rescue JSON::ParserError, KeyError, ArgumentError => error
      fail!("#{table} forced EXPLAIN could not be validated: #{error.message}")
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
        entry[:catalog_inventory] = copied
      end
    end

    def validate_reopen!(report, expected_part:, expected_paths:)
      fail!('reopen helper format/status differs') unless report.is_a?(Hash) && report['format'] == HELPER_FORMAT && report['action'] == 'reopen' && report['status'] == 'ok'
      pairs = report.fetch('pairs')
      fail!('reopen helper must report both Compact and Wide parents') unless pairs.map { |pair| pair.fetch('table') }.sort == %w[target_compact target_wide]
      pairs.each do |pair|
        table = pair.fetch('table')
        target = TARGETS.fetch(table)
        fail!("#{table} offline part identity differs") unless pair.fetch('part_name') == expected_part
        fail!("#{table} offline parent rows/window differ") unless
          pair.fetch('parent_rows') == PARENT_ROWS.map { |row| row.map(&:to_s) } &&
          pair.fetch('parent_mark_rows') == PARENT_MARK_ROWS &&
          pair.fetch('parent_window_start_1_count_5') == PARENT_ROWS[1, 5].map { |row| row.map(&:to_s) } &&
          pair.fetch('parent_window_mark_rows') == [1, 2, 2]
        expected_children = GROUP_KEYS.map { |key| [key] + target.fetch(:aggregates).map { |name| aggregate_value(key, name) } }
        fail!("#{table} offline aggregate rows/window differ") unless
          pair.fetch('child_rows') == expected_children.map { |row| row.map(&:to_s) } &&
          pair.fetch('child_mark_rows') == CHILD_DATA_MARK_ROWS &&
          pair.fetch('child_window_start_1_count_4') == expected_children[1, 4].map { |row| row.map(&:to_s) } &&
          pair.fetch('child_window_mark_rows') == [1, 2, 1] &&
          pair.fetch('child_keys_only') == GROUP_KEYS.map(&:to_s) &&
          pair.fetch('child_keys_window_start_1_count_4') == GROUP_KEYS[1, 4].map(&:to_s)
        expected_values = target.fetch(:aggregates).to_h do |name|
          [name, GROUP_KEYS.map { |key| aggregate_value(key, name).to_s }]
        end
        expected_state_hex = target.fetch(:aggregates).to_h do |name|
          [name, GROUP_KEYS.map { |key| aggregate_state(name, key).unpack1('H*') }]
        end
        expected_window_values = expected_values.transform_values { |values| values[1, 4] }
        expected_window_hex = expected_state_hex.transform_values { |values| values[1, 4] }
        fail!("#{table} state-only reader/full-window bytes differ") unless
          pair.fetch('aggregate_columns_only') == target.fetch(:aggregates) &&
          pair.fetch('state_only_rows') == expected_values && pair.fetch('state_only_window_rows') == expected_window_values &&
          pair.fetch('state_only_mark_rows') == CHILD_DATA_MARK_ROWS && pair.fetch('state_only_window_mark_rows') == [1, 2, 1] &&
          pair.fetch('state_hex') == expected_state_hex && pair.fetch('state_window_hex') == expected_window_hex &&
          pair.fetch('state_only_hex') == expected_state_hex && pair.fetch('state_only_window_hex') == expected_window_hex
        fail!("#{table} offline callback parent identity differs") unless
          pair.fetch('callback_parent_identity') == {"part_name" => pair.fetch('part_name'), "part_path" => pair.fetch('parent_path')}
        fail!("#{table} reopen did not consume the byte-identical native part copy") unless
          pair.fetch('parent_path') == expected_paths.fetch(table) &&
          pair.fetch('reopen_source') == 'byte_identical_native_part_copy'
      end
    end

    def validate_inputs_unchanged!
      fail!('pinned binary changed while the witness ran') unless sha_file(@binary) == @binary_sha_before
      fail!('prebuilt helper changed while the witness ran') unless sha_file(@helper) == @helper_sha_before
      fail!('run_safe guard changed while the witness ran') unless sha_file(@run_safe) == @run_safe_sha_before
      fail!('W296 source files changed while the witness ran') unless input_hashes == @input_hashes
    end

    def assert_attached_files_preserved!(expected_inventory, actual_inventory, table, attached_path)
      expected = expected_inventory.fetch(:files).to_h { |entry| [entry.fetch(:relative_path), entry] }
      actual = actual_inventory.fetch(:files).to_h { |entry| [entry.fetch(:relative_path), entry] }
      fail!("#{table} ATTACH changed or removed generated part files") unless expected.all? { |name, entry| actual[name] == entry }
      extras = actual.keys - expected.keys
      fail!("#{table} ATTACH added unexpected sidecars") unless extras == [ATTACH_SIDECAR]
      bytes = File.binread(File.join(attached_path, ATTACH_SIDECAR))
      fail!("#{table} ATTACH sidecar bytes/hash differ") unless bytes == ATTACH_SIDECAR_BYTES && actual.fetch(ATTACH_SIDECAR).fetch(:sha256) == ATTACH_SIDECAR_SHA256
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

    def run_helper(action, args = [], catalog_root: @catalog_root, run_name: action)
      cell = File.join(@root, 'helper', run_name)
      Dir.mkdir(cell, 0o700)
      stdout = run_process("helper_#{run_name}", @helper, [catalog_root, action, *args], ''.b,
                           'prebuilt Crystal helper', cell)
      fail!("helper #{action} must emit one JSON line") unless stdout.lines.size == 1
      JSON.parse(stdout)
    rescue JSON::ParserError => error
      fail!("helper #{action} emitted invalid JSON: #{error.message}")
    end

    def run_process(label, executable, args, input, kind, cell)
      argv = [@run_safe, executable, PROCESS_TIMEOUT_SECONDS.to_s, PROCESS_MEMORY_MIB.to_s, *args]
      env = {'RUN_SAFE_PASSTHROUGH_STDIO' => '1', 'COGNI_RUN_SAFE_MIN_FREE_PCT' => '50',
             'TMPDIR' => File.join(@root, 'tmp'), 'TMP' => File.join(@root, 'tmp'), 'TEMP' => File.join(@root, 'tmp'),
             'CRYSTAL_CACHE_DIR' => File.join(@root, 'cache')}
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      stdout, stderr, status = Open3.capture3(env, *argv, stdin_data: input)
      stdout = stdout.b
      stderr = stderr.b
      fail!("#{label} stdout exceeds capture bound") if stdout.bytesize > MAX_CAPTURE_BYTES
      fail!("#{label} stderr exceeds capture bound") if stderr.bytesize > MAX_CAPTURE_BYTES
      write_new(File.join(cell, 'stdin.bin'), input)
      write_new(File.join(cell, 'stdout.bin'), stdout)
      write_new(File.join(cell, 'stderr.bin'), stderr)
      record = {label: label, executable: executable, argv: argv,
                argv_sha256: Digest::SHA256.hexdigest(JSON.generate(argv)), kind: kind,
                run_safe_sha256: @run_safe_sha_before, timeout_seconds: PROCESS_TIMEOUT_SECONDS,
                process_tree_memory_limit_bytes: PROCESS_MEMORY_MIB * 1024 * 1024,
                input_bytes: input.bytesize, input_sha256: Digest::SHA256.hexdigest(input),
                duration_seconds: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3),
                exitstatus: status.exitstatus, termsig: status.termsig,
                stdout_file: File.join(cell, 'stdout.bin'), stdout_bytes: stdout.bytesize,
                stdout_sha256: Digest::SHA256.hexdigest(stdout), stderr_file: File.join(cell, 'stderr.bin'),
                stderr_bytes: stderr.bytesize, stderr_sha256: Digest::SHA256.hexdigest(stderr)}
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

    def assert_format!(path, format, label, compressed:)
      names = Dir.children(path)
      compact_marks = names.select { |name| name.end_with?('.mrk4') || name.end_with?('.cmrk4') }
      wide_marks = names.select { |name| name.end_with?('.mrk2') || name.end_with?('.cmrk2') }
      actual = if !compact_marks.empty? && wide_marks.empty? then 'Compact' elsif !wide_marks.empty? && compact_marks.empty? then 'Wide' else 'ambiguous' end
      fail!("#{label} marker family was #{actual}, expected #{format}") unless actual == format
      marks = format == 'Compact' ? compact_marks : wide_marks
      actual_compressed = !marks.empty? && marks.all? { |name| name.include?('.cmrk') }
      fail!("#{label} mark compression differs from table setting") unless actual_compressed == compressed
      index = File.join(path, 'primary.idx')
      fail!("#{label} primary.idx is missing") unless File.file?(index)
      # All W296 parents and projection children request uncompressed primary indexes.
      fail!("#{label} has a compressed primary index") if names.any? { |name| name == 'primary.idx.gz' }
    end

    def child_schema(table)
      query("child_schema_#{table}", "DESCRIBE TABLE mergeTreeProjection('#{DATABASE}','#{table}','#{PROJECTION}') FORMAT TSVRaw;")
        .lines(chomp: true).map { |line| line.split("\t", -1).take(2) }
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

    def aggregate_value(key, name)
      aggregate = AGGREGATES.fetch(key)
      case name
      when 'count()' then aggregate.fetch(:count)
      when 'min(value)' then aggregate.fetch(:min)
      when 'max(value)' then aggregate.fetch(:max)
      when 'sum(value)' then aggregate.fetch(:sum)
      else fail!("unknown aggregate name #{name}")
      end
    end

    def aggregate_state(name, key)
      aggregate = AGGREGATES.fetch(key)
      case name
      when 'count()' then varuint(aggregate.fetch(:count))
      when 'min(value)' then minmax_state(aggregate.fetch(:min))
      when 'max(value)' then minmax_state(aggregate.fetch(:max))
      when 'sum(value)' then [aggregate.fetch(:sum)].pack('Q<').b
      else fail!("unknown aggregate name #{name}")
      end
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

    def expected_primary_index
      (GROUP_KEYS.each_slice(2).map(&:first) + [GROUP_KEYS.last]).map { |key| [key].pack('Q<').b }.join.b
    end

    def expected_child_rowbinary(target)
      GROUP_KEYS.map do |key|
        [key].pack('Q<').b + target.fetch(:aggregates).map { |name| aggregate_state(name, key) }.join.b
      end.join.b
    end

    def assert_bytes!(actual, expected, label)
      fail!("#{label}: byte mismatch; expected #{expected.unpack1('H*')}, observed #{actual.unpack1('H*')}") unless actual == expected
    end

    def uuid_path(uuid, root = @catalog_root)
      File.join(root, 'store', uuid[0, 3], uuid)
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
      payload = {format: FORMAT, repository_head: @revision_before, fatal_error: @fatal_error}.merge(values)
      File.write(File.join(@root, 'summary.json'), JSON.pretty_generate(payload) + "\n", mode: 'w', perm: 0o600)
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
      args.banner = 'Usage: ruby scripts/verify_materialized_view_aggregate_projection_w296.rb --evidence-root PATH --helper PREBUILT --run-safe PATH [--binary PATH]'
      args.on('--evidence-root PATH', 'Fresh evidence directory on /opt/mldata_ssd') { |value| options[:evidence_root] = value }
      args.on('--helper PATH', 'Prebuilt executable W296 Crystal helper') { |value| options[:helper] = value }
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

exit VerifyMaterializedViewAggregateProjectionW296.run
