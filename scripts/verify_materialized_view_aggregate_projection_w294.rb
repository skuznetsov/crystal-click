#!/usr/bin/env ruby
# Bounded W294 stock-native -> caller transform -> two-key aggregate projection witness.
# The Crystal helper must already be built; this runner never invokes a build.

require 'base64'
require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'open3'
require 'optparse'

module VerifyMaterializedViewAggregateProjectionW294
  extend self

  REPO_ROOT = File.expand_path('..', __dir__).freeze
  FORMAT = 'materialized_view_aggregate_projection_w294_native_v1'.freeze
  BINARY = '/opt/mldata_ssd/cache/crystal-click-w283.PDWAiK/recovery/runtime/clickhouse'.freeze
  BINARY_SHA256 = '5bb43958f4c0806cc363b84b9858e7206e56ac80263a24acc704271322e531ae'.freeze
  VERSION = '26.10.1.1201'.freeze
  REVISION = '54515'.freeze
  RUN_SAFE_SHA256 = 'fbfa0fd9d717eb24c1a3f829d464188110e505c7ae311eee2e95cbe7cefab011'.freeze
  DATABASE = 'lab'.freeze
  DATABASE_UUID = 'f2940000-7b7f-4e2f-9e44-dc13a87b8801'.freeze
  SOURCE_UUID = 'f2940000-7b7f-4e2f-9e44-dc13a87b8802'.freeze
  COMPACT_TARGET_UUID = 'f2940000-7b7f-4e2f-9e44-dc13a87b8805'.freeze
  WIDE_TARGET_UUID = 'f2940000-7b7f-4e2f-9e44-dc13a87b8806'.freeze
  COMPACT_VIEW_UUID = 'f2940000-7b7f-4e2f-9e44-dc13a87b8807'.freeze
  WIDE_VIEW_UUID = 'f2940000-7b7f-4e2f-9e44-dc13a87b8808'.freeze
  SOURCE_PART = 'all_1_1_0'.freeze
  COMPACT_PART = 'all_9_9_0'.freeze
  WIDE_PART = 'all_10_10_0'.freeze
  PROJECTION = 'by_group'.freeze
  ATTACH_SIDECAR = 'invalidated_system_columns.txt'.freeze
  ATTACH_SIDECAR_BYTES = "_block_offset\n_block_number\n".b.freeze
  ATTACH_SIDECAR_SHA256 = '7409424ab45090c1261e622f7423393905102e7e8cba36a6db88eb513ce1e06c'.freeze
  UINT64_MAX = (1 << 64) - 1
  ASYMMETRIC = 0x0102030405060708

  SOURCE_ROWS = [
    [1, 6, 10, 0],
    [2, 6, 10, ASYMMETRIC],
    [3, 6, 10, UINT64_MAX],
    [4, 6, 12, 17],
    [5, 6, 15, 42],
    [6, 6, 15, 23],
    [7, 7, 1, 99],
    [8, 7, 1, 1],
    [9, 7, 1, 2],
    [10, 7, 1, 3],
    [11, 7, 4, ASYMMETRIC],
    [12, 7, 4, 7],
    [13, 8, 1, 0],
    [14, 8, 1, UINT64_MAX],
    [15, 8, 1, 8],
    [16, UINT64_MAX, 0, ASYMMETRIC],
    [17, UINT64_MAX, 0, UINT64_MAX],
    [18, UINT64_MAX, ASYMMETRIC, ASYMMETRIC],
  ].freeze
  PARENT_ROWS = SOURCE_ROWS.map { |id, key_a, key_b, value| [id + 100, key_a, key_b, value.to_s] }.freeze
  GROUPS = [
    [6, 10, 3, ASYMMETRIC - 1, 0, UINT64_MAX],
    [6, 12, 1, 17, 17, 17],
    [6, 15, 2, 65, 23, 42],
    [7, 1, 4, 105, 1, 99],
    [7, 4, 2, ASYMMETRIC + 7, 7, ASYMMETRIC],
    [8, 1, 3, 7, 0, UINT64_MAX],
    [UINT64_MAX, 0, 2, ASYMMETRIC - 1, ASYMMETRIC, UINT64_MAX],
    [UINT64_MAX, ASYMMETRIC, 1, ASYMMETRIC, ASYMMETRIC, ASYMMETRIC],
  ].freeze
  GROUPS_REVERSED = GROUPS.sort_by { |key_a, key_b, *_state| [key_b, key_a] }.freeze
  COMPACT_CHILD_ROWS = GROUPS.map { |key_a, key_b, count, sum, min, max| [key_a, key_b, count, sum, min, max].map(&:to_s) }.freeze
  WIDE_CHILD_ROWS = GROUPS_REVERSED.map { |key_a, key_b, count, _sum, _min, _max| [key_b, key_a, count].map(&:to_s) }.freeze

  TARGETS = {
    'target_compact' => {
      uuid: COMPACT_TARGET_UUID, part: COMPACT_PART, format: 'Compact', control: 'control_compact',
      control_uuid: 'f2940000-7b7f-4e2f-9e44-dc13a87b8809', variant: :all,
      columns: [
        ['key_a', 'UInt64'], ['key_b', 'UInt64'],
        ['count()', 'AggregateFunction(count)'], ['sum(value)', 'AggregateFunction(sum, UInt64)'],
        ['min(value)', 'AggregateFunction(min, UInt64)'], ['max(value)', 'AggregateFunction(max, UInt64)'],
      ].freeze,
      key_order: %w[key_a key_b],
      select: 'key_b, count() AS n, sum(value) AS total, min(value) AS minimum, key_a, max(value) AS maximum',
      ddl: 'SELECT key_b, count() AS n, sum(value) AS total, min(value) AS minimum, key_a, max(value) AS maximum GROUP BY key_a, key_b',
      leading_filter: 'key_a = 6',
      filter: 'key_a = 6 AND key_b <= 12',
      filter_rows: [[12, 1, 17, 17, 6, 17], [10, 3, ASYMMETRIC - 1, 0, 6, UINT64_MAX]].sort_by { |row| [row[4], row[0]] },
      physical_order: :ab,
    }.freeze,
    'target_wide' => {
      uuid: WIDE_TARGET_UUID, part: WIDE_PART, format: 'Wide', control: 'control_wide',
      control_uuid: 'f2940000-7b7f-4e2f-9e44-dc13a87b8810', variant: :count,
      columns: [
        ['key_b', 'UInt64'], ['key_a', 'UInt64'], ['count()', 'AggregateFunction(count)'],
      ].freeze,
      key_order: %w[key_b key_a], select: 'key_b, count()',
      ddl: 'SELECT key_b, count() GROUP BY key_b, key_a',
      leading_filter: 'key_b = 1',
      filter: 'key_b = 1 AND key_a <= 7',
      filter_rows: [[1, 4]],
      physical_order: :ba,
    }.freeze,
  }.freeze

  MEMORY_BYTES = 536_870_912
  PROCESS_MEMORY_MIB = 2048
  PROCESS_TIMEOUT_SECONDS = 90
  MAX_CAPTURE_BYTES = 16 * 1024 * 1024
  MAX_PART_FILES = 256
  MAX_PART_BYTES = 16 * 1024 * 1024
  INPUT_FILES = %w[
    scripts/verify_materialized_view_aggregate_projection_w294.rb
    scripts/check_materialized_view_aggregate_projection_w294.cr
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
      @controls = {}
      @metadata = {}
      @native_paths = {}
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
      publish = run_helper('publish')
      validate_publish!(publish)
      verify_generated_indexes!
      copy_to_detached!
      attach_and_check!
      native_state = verify_native_reads!
      copy_attached_to_catalog!
      reopen = run_helper('reopen', [@attached.fetch('target_compact').fetch(:part), @attached.fetch('target_wide').fetch(:part)])
      validate_reopen!(reopen)
      validate_inputs_unchanged!
      write_summary(
        status: 'two_key_wide_aggregate_children_attached_checked_and_offline_reopened',
        binary: {path: @binary, sha256: @binary_sha_before, version: VERSION, revision: REVISION},
        helper: {path: @helper, sha256: @helper_sha_before},
        run_safe: {path: @run_safe, sha256: @run_safe_sha_before},
        source: source, stock_controls: controls, offline_catalog: catalog,
        generated_parts: @generated, attached_parts: @attached, native_checks: native_state,
        reopen: reopen, invocations: @processes,
        cleanup_owner: 'orchestrator', retained_evidence_root: @root,
        generated_native_part_paths: @attached.values.map { |entry| entry.fetch(:path) },
      )
      puts "W294 two-key aggregate projection witness passed; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error = "#{error.class}: #{error.message}"
      write_summary(status: 'witness_failure_or_observations_differ', fatal_error: @fatal_error,
                    cleanup_owner: 'orchestrator', retained_evidence_root: @root) rescue nil
      warn "W294 probe failure (process failure is not native format evidence): #{@fatal_error}"
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
            key_a UInt64,
            key_b UInt64,
            value UInt64
        ) ENGINE = MergeTree ORDER BY source_id SETTINGS index_granularity=2, min_rows_for_wide_part=0, min_bytes_for_wide_part=0;
        SELECT version(), revision() FORMAT TSVRaw;
      SQL
      assert_bytes!(native('create_source', sql.b), "#{VERSION}\t#{REVISION}\n".b, 'pinned native version/revision')
    end

    def insert_source!
      bytes = SOURCE_ROWS.map { |row| row.pack('Q<Q<Q<Q<') }.join.b
      output = native('insert_source', "INSERT INTO #{DATABASE}.source FORMAT RowBinary\n".b + bytes)
      fail!('RowBinary source insert emitted unexpected stdout') unless output.empty?
    end

    def verify_source!
      check = query('source_check', "CHECK TABLE #{DATABASE}.source FORMAT TSV;")
      assert_bytes!(check, "#{SOURCE_PART}\t1\t\n".b, 'stock source CHECK TABLE')
      raw = query('source_rows', "SELECT source_id, key_a, key_b, value FROM #{DATABASE}.source ORDER BY source_id FORMAT RowBinary;")
      assert_bytes!(raw, SOURCE_ROWS.map { |row| row.pack('Q<Q<Q<Q<') }.join.b, 'stock source fixture RowBinary')
      row = query('source_part', <<~SQL)
        SELECT name, part_type, toString(rows), toString(marks), path
        FROM system.parts WHERE database='#{DATABASE}' AND table='source' AND active FORMAT TSVRaw;
      SQL
      fields = one_row(row, 5, 'source part')
      fail!('source part identity, type, or count differs') unless
        fields[0] == SOURCE_PART && fields[1] == 'Wide' && fields[2].to_i == SOURCE_ROWS.size && fields[3].to_i == 10
      data_path = query('source_data_path', "SELECT data_paths[1] FROM system.tables WHERE database='#{DATABASE}' AND name='source' FORMAT TSVRaw;").strip
      @native_paths['source'] = store_path!(data_path)
      @source_path = part_path!(fields[4], 'source', SOURCE_PART)
      @source_inventory = inventory(@source_path)
      {part: SOURCE_PART, format: fields[1], rows: fields[2].to_i, marks: fields[3].to_i,
       path: @source_path, rowbinary_sha256: Digest::SHA256.hexdigest(raw), inventory: @source_inventory}
    end

    def create_targets!
      sql = <<~SQL
        CREATE TABLE #{DATABASE}.target_compact UUID '#{COMPACT_TARGET_UUID}'
        (
            parent_id UInt64, key_a UInt64, key_b UInt64, value UInt64,
            PROJECTION #{PROJECTION} (#{TARGETS.fetch('target_compact').fetch(:ddl)})
        ) ENGINE = MergeTree ORDER BY parent_id SETTINGS index_granularity=2, min_rows_for_wide_part=0, min_bytes_for_wide_part=0;
        CREATE TABLE #{DATABASE}.target_wide UUID '#{WIDE_TARGET_UUID}'
        (
            parent_id UInt64, key_a UInt64, key_b UInt64, value UInt64,
            PROJECTION #{PROJECTION} (#{TARGETS.fetch('target_wide').fetch(:ddl)})
        ) ENGINE = MergeTree ORDER BY parent_id SETTINGS index_granularity=2, min_rows_for_wide_part=0, min_bytes_for_wide_part=0;
        CREATE MATERIALIZED VIEW #{DATABASE}.view_compact UUID '#{COMPACT_VIEW_UUID}' TO #{DATABASE}.target_compact
        (parent_id UInt64, key_a UInt64, key_b UInt64, value UInt64)
        AS SELECT source_id + 100 AS parent_id, key_a, key_b, value FROM #{DATABASE}.source;
        CREATE MATERIALIZED VIEW #{DATABASE}.view_wide UUID '#{WIDE_VIEW_UUID}' TO #{DATABASE}.target_wide
        (parent_id UInt64, key_a UInt64, key_b UInt64, value UInt64)
        AS SELECT source_id + 100 AS parent_id, key_a, key_b, value FROM #{DATABASE}.source;
      SQL
      native('create_targets', sql.b)
      TARGETS.each_key do |name|
        fail!("target #{name} was not empty") unless query("target_count_#{name}", "SELECT toString(count()) FROM #{DATABASE}.#{name} FORMAT TSVRaw;").strip == '0'
        fail!("target #{name} unexpectedly has active parts") unless
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

    def create_controls!
      sql = TARGETS.map do |_target_name, target|
        <<~SQL
          CREATE TABLE #{DATABASE}.#{target.fetch(:control)} UUID '#{target.fetch(:control_uuid)}'
          (
              parent_id UInt64, key_a UInt64, key_b UInt64, value UInt64,
              PROJECTION #{PROJECTION} (#{target.fetch(:ddl)})
          ) ENGINE = MergeTree ORDER BY parent_id SETTINGS index_granularity=2, compress_marks=0, compress_primary_key=0, replace_long_file_name_to_hash=0, min_rows_for_wide_part=0, min_bytes_for_wide_part=0;
        SQL
      end.join("\n")
      native('create_controls', sql.b)
      bytes = SOURCE_ROWS.map { |id, key_a, key_b, value| [id + 100, key_a, key_b, value].pack('Q<Q<Q<Q<') }.join.b
      TARGETS.each do |_target_name, target|
        output = native("insert_#{target.fetch(:control)}", "INSERT INTO #{DATABASE}.#{target.fetch(:control)} FORMAT RowBinary\n".b + bytes)
        fail!("#{target.fetch(:control)} RowBinary insert emitted unexpected stdout") unless output.empty?
      end
    end

    def verify_controls!
      TARGETS.to_h do |table, target|
        name = target.fetch(:control)
        check = query("check_#{name}", "CHECK TABLE #{DATABASE}.#{name} FORMAT TSV;")
        data_path = query("control_data_path_#{name}", "SELECT data_paths[1] FROM system.tables WHERE database='#{DATABASE}' AND name='#{name}' FORMAT TSVRaw;").strip
        @native_paths[name] = store_path!(data_path)
        active = query("control_parent_#{name}", <<~SQL)
          SELECT name, part_type, toString(rows), toString(marks), path FROM system.parts
          WHERE database='#{DATABASE}' AND table='#{name}' AND active FORMAT TSVRaw;
        SQL
        fields = one_row(active, 5, "#{name} active parent")
        assert_bytes!(check, "#{fields[0]}\t1\t\n".b, "#{name} CHECK TABLE")
        fail!("#{name} stock parent is not Wide adaptive MRK2") unless
          fields[1] == 'Wide' && fields[2].to_i == PARENT_ROWS.size && fields[3].to_i == 10
        parent_path = part_path!(fields[4], name, fields[0])
        projection = query("control_projection_#{name}", <<~SQL)
          SELECT name, parent_name, part_type, parent_part_type, toString(rows), toString(marks), path
          FROM system.projection_parts WHERE database='#{DATABASE}' AND table='#{name}' AND active FORMAT TSVRaw;
        SQL
        child = one_row(projection, 7, "#{name} stock projection")
        child_path = File.expand_path(child[6])
        fail!("#{name} stock projection identity or adaptive MRK2 shape differs") unless
          child[0] == PROJECTION && child[1] == fields[0] && child[2] == 'Wide' && child[3] == 'Wide' &&
          child[4].to_i == GROUPS.size && child[5].to_i == 5 && child_path == File.join(parent_path, "#{PROJECTION}.proj")
        assert_format!(child_path, 'Wide', "#{name} stock projection")
        fail!("#{name} stock projection marks are not plain .mrk2") unless
          Find.find(child_path).any? { |path| File.file?(path) && path.end_with?('.mrk2') } &&
          Find.find(child_path).none? { |path| File.file?(path) && path.end_with?('.mrk4') }
        index_bytes = File.binread(File.join(child_path, 'primary.idx'))
        assert_bytes!(index_bytes, expected_primary_index(target), "#{name} stock compound primary.idx")
        schema = child_schema(name)
        fail!("#{name} stock schema differs") unless schema == target.fetch(:columns)
        child_raw = query("control_raw_#{name}", <<~SQL)
          SELECT * FROM mergeTreeProjection('#{DATABASE}','#{name}','#{PROJECTION}')
          ORDER BY #{target.fetch(:key_order).join(',')} FORMAT RowBinary;
        SQL
        assert_bytes!(child_raw, expected_child_rowbinary(target), "#{name} stock projection aggregate state bytes")
        inventory = inventory(parent_path)
        @controls[name] = {
          part: fields[0], parent_path: parent_path, child_path: child_path,
          primary_index: index_bytes, inventory: inventory,
          child_rowbinary_sha256: Digest::SHA256.hexdigest(child_raw), schema: schema,
        }
        [table, {control_table: name, part: fields[0], parent_format: fields[1], parent_rows: fields[2].to_i,
                 parent_marks: fields[3].to_i, child_rows: child[4].to_i, child_marks: child[5].to_i,
                 primary_index_hex: index_bytes.unpack1('H*'), schema: schema,
                 child_rowbinary_sha256: Digest::SHA256.hexdigest(child_raw), path: child_path}]
      end
    end

    def build_catalog!
      database_path = uuid_path(DATABASE_UUID)
      source_path = uuid_path(SOURCE_UUID)
      target_paths = TARGETS.to_h { |name, target| [name, uuid_path(target.fetch(:uuid))] }
      [database_path, source_path, *target_paths.values].each { |path| FileUtils.mkdir_p(path, mode: 0o700) }
      FileUtils.mkdir_p(File.join(@catalog_root, 'metadata'), mode: 0o700)
      [source_path, *target_paths.values].each { |path| write_new(File.join(path, 'format_version.txt'), "1\n") }
      [*target_paths.values].each { |path| FileUtils.mkdir_p(File.join(path, 'detached'), mode: 0o700) }
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
        report['format'] == 'materialized_view_aggregate_projection_w294_helper_v1' && report['action'] == 'publish' && report['status'] == 'ok'
      fail!('publish source rows differ') unless report['source_row_count'] == SOURCE_ROWS.size && report['parent_rows'] == PARENT_ROWS.map { |row| row.map(&:to_s) }
      fail!('publish child rows differ') unless report['compact_child_rows'] == COMPACT_CHILD_ROWS && report['wide_child_rows'] == WIDE_CHILD_ROWS
      fail!('publish columns or aggregate order differ') unless
        report['compact_projection_columns'] == %w[key_a key_b count() sum(value) min(value) max(value)] &&
        report['wide_projection_columns'] == %w[key_b key_a count()] &&
        report['compact_aggregate_order'] == %w[count() sum(value) min(value) max(value)] && report['wide_aggregate_order'] == %w[count()]
      fail!('publish mark schedule differs') unless report['parent_mark_rows'] == Array.new(9, 2) && report['child_mark_rows'] == [2, 2, 2, 2]
      @generated = {}
      TARGETS.each do |table, target|
        path = report.fetch(table == 'target_compact' ? 'compact_parent_path' : 'wide_parent_path')
        expected = File.join(@catalog_root, 'store', target.fetch(:uuid)[0, 3], target.fetch(:uuid), 'detached', target.fetch(:part))
        fail!("#{table} transform destination differs") unless File.expand_path(path) == expected
        @generated[table] = {path: expected, table: table, part: target.fetch(:part)}
      end
    end

    def verify_generated_indexes!
      TARGETS.each do |table, target|
        generated_child = File.join(@generated.fetch(table).fetch(:path), "#{PROJECTION}.proj")
        bytes = File.binread(File.join(generated_child, 'primary.idx'))
        assert_bytes!(bytes, expected_primary_index(target), "#{table} generated compound primary.idx")
        control = @controls.fetch(target.fetch(:control))
        assert_bytes!(bytes, control.fetch(:primary_index), "#{table} generated vs stock compound primary.idx")
        @generated.fetch(table)[:primary_index_hex] = bytes.unpack1('H*')
      end
    end

    def copy_to_detached!
      @generated.each do |table, entry|
        entry[:inventory] = inventory(entry.fetch(:path))
        child_prefix = "#{PROJECTION}.proj/"
        fail!("#{table} omitted its Wide aggregate child") unless entry.fetch(:inventory).fetch(:files).any? { |file| file.fetch(:relative_path).start_with?(child_prefix) }
        native_table_path = @native_paths.fetch(table)
        detached = File.join(native_table_path, 'detached')
        if File.exist?(detached) || File.symlink?(detached)
          fail!("#{table} detached target is unsafe or occupied") unless File.directory?(detached) && !File.symlink?(detached) && Dir.children(detached).empty?
        else
          Dir.mkdir(detached, 0o700)
        end
        destination = File.join(detached, entry.fetch(:part))
        copy_tree(entry.fetch(:path), destination)
        entry[:native_detached_path] = destination
        entry[:native_detached_inventory] = inventory(destination)
        fail!("#{table} detached copy changed file hashes") unless entry.fetch(:native_detached_inventory) == entry.fetch(:inventory)
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
          fields[1] == target.fetch(:format) && fields[2].to_i == PARENT_ROWS.size && fields[3].to_i == 10
        parent_path = part_path!(fields[4], table, fields[0])
        projection = query("projection_#{table}", <<~SQL)
          SELECT name, parent_name, part_type, parent_part_type, toString(rows), toString(marks), path
          FROM system.projection_parts WHERE database='#{DATABASE}' AND table='#{table}' AND active FORMAT TSVRaw;
        SQL
        child = one_row(projection, 7, "#{table} active projection child")
        child_path = File.expand_path(child[6])
        fail!("#{table} projection identity, format, or axes differ") unless
          child[0] == PROJECTION && child[1] == fields[0] && child[2] == 'Wide' && child[3] == target.fetch(:format) &&
          child[4].to_i == GROUPS.size && child[5].to_i == 5 && child_path == File.join(parent_path, "#{PROJECTION}.proj")
        assert_format!(child_path, 'Wide', "#{table} aggregate child")
        index_bytes = File.binread(File.join(child_path, 'primary.idx'))
        assert_bytes!(index_bytes, expected_primary_index(target), "#{table} attached compound primary.idx")
        entry = @generated.fetch(table)
        attached_inventory = inventory(parent_path)
        assert_attached_files_preserved!(entry.fetch(:inventory), attached_inventory, table, parent_path)
        @attached[table] = {
          part: fields[0], format: fields[1], rows: fields[2].to_i, marks: fields[3].to_i,
          path: parent_path, child_path: child_path, inventory: attached_inventory,
          generated_inventory: entry.fetch(:inventory), primary_index_hex: index_bytes.unpack1('H*'),
        }
      end
    end

    def verify_native_reads!
      result = {}
      TARGETS.each do |table, target|
        parent = query("parent_read_#{table}", <<~SQL)
          SELECT parent_id, key_a, key_b, value FROM #{DATABASE}.#{table}
          ORDER BY parent_id SETTINGS optimize_use_projections=0 FORMAT RowBinary;
        SQL
        expected_parent = SOURCE_ROWS.map { |id, key_a, key_b, value| [id + 100, key_a, key_b, value].pack('Q<Q<Q<Q<') }.join.b
        assert_bytes!(parent, expected_parent, "#{table} parent rows with projections disabled")
        disabled = query("grouped_disabled_#{table}", grouped_sql(table, forced: false, filtered: false))
        forced = query("grouped_forced_#{table}", grouped_sql(table, forced: true, filtered: false))
        filtered_disabled = query("filtered_disabled_#{table}", grouped_sql(table, forced: false, filtered: true))
        filtered_forced = query("filtered_forced_#{table}", grouped_sql(table, forced: true, filtered: true))
        expected = expected_grouped(target, false)
        expected_filtered = expected_grouped(target, true)
        assert_bytes!(disabled, expected, "#{table} full grouping without projection")
        assert_bytes!(forced, expected, "#{table} full forced projection grouping")
        assert_bytes!(filtered_disabled, expected_filtered, "#{table} key-filtered grouping without projection")
        assert_bytes!(filtered_forced, expected_filtered, "#{table} key-filtered forced projection grouping")

        schema = child_schema(table)
        fail!("#{table} canonical child names/order/types differ") unless schema == target.fetch(:columns)
        raw = query("child_raw_#{table}", <<~SQL)
          SELECT * FROM mergeTreeProjection('#{DATABASE}','#{table}','#{PROJECTION}')
          ORDER BY #{target.fetch(:key_order).join(',')} FORMAT RowBinary;
        SQL
        assert_bytes!(raw, expected_child_rowbinary(target), "#{table} exact aggregate child RowBinary state order")
        attached_index = File.binread(File.join(@attached.fetch(table).fetch(:child_path), 'primary.idx'))
        assert_bytes!(attached_index, @controls.fetch(target.fetch(:control)).fetch(:primary_index), "#{table} attached index vs stock control")

        full_plan = forced_projection!(query("full_explain_#{table}", explain_sql(table, filtered: false)), table, filtered: false)
        filtered_plan = forced_projection!(query("filtered_explain_#{table}", explain_sql(table, filtered: true)), table,
                                           filtered: true, expected_keys: target.fetch(:key_order), expected_granules: [4, 1])
        leading_plan = forced_projection!(query("leading_explain_#{table}", explain_sql(table, leading: true)), table,
                                          filtered: true, expected_keys: target.fetch(:key_order).take(1),
                                          expected_granules: [4, 2])
        result[table] = {
          full_disabled_sha256: Digest::SHA256.hexdigest(disabled),
          full_forced_sha256: Digest::SHA256.hexdigest(forced),
          filtered_disabled_sha256: Digest::SHA256.hexdigest(filtered_disabled),
          filtered_forced_sha256: Digest::SHA256.hexdigest(filtered_forced),
          projection_schema: schema, child_rowbinary_hex: raw.unpack1('H*'),
          primary_index_hex: attached_index.unpack1('H*'),
          full_forced_plan: full_plan, filtered_forced_plan: filtered_plan, leading_only_forced_plan: leading_plan,
          stock_control_primary_index_hex: @controls.fetch(target.fetch(:control)).fetch(:primary_index).unpack1('H*'),
        }
      end
      result
    end

    def grouped_sql(table, forced:, filtered:)
      target = TARGETS.fetch(table)
      settings = forced ? "force_optimize_projection=1, force_optimize_projection_name='#{PROJECTION}'" : 'optimize_use_projections=0'
      predicate = filtered ? " WHERE #{target.fetch(:filter)}" : ''
      "SELECT #{target.fetch(:select)} FROM #{DATABASE}.#{table}#{predicate} GROUP BY #{target.fetch(:key_order).join(', ')} ORDER BY #{target.fetch(:key_order).join(', ')} SETTINGS #{settings} FORMAT TSVRaw;"
    end

    def explain_sql(table, filtered: false, leading: false)
      target = TARGETS.fetch(table)
      filter = if leading
                 target.fetch(:leading_filter)
               elsif filtered
                 target.fetch(:filter)
               end
      predicate = filter ? " WHERE #{filter}" : ''
      <<~SQL
        EXPLAIN json=1, description=1, projections=1, indexes=1
        SELECT #{target.fetch(:select)} FROM #{DATABASE}.#{table}#{predicate}
        GROUP BY #{target.fetch(:key_order).join(', ')} ORDER BY #{target.fetch(:key_order).join(', ')}
        SETTINGS force_optimize_projection=1, force_optimize_projection_name='#{PROJECTION}' FORMAT JSONEachRow;
      SQL
    end

    def expected_grouped(target, filtered)
      rows = if filtered
               target.fetch(:filter_rows)
             elsif target.fetch(:variant) == :all
               GROUPS.map { |key_a, key_b, count, sum, min, max| [key_b, count, sum, min, key_a, max] }
             else
               GROUPS_REVERSED.map { |_key_a, key_b, count, _sum, _min, _max| [key_b, count] }
             end
      rows.map { |row| row.join("\t") + "\n" }.join.b
    end

    def expected_primary_index(target)
      pairs = if target.fetch(:physical_order) == :ab
                GROUPS.map { |key_a, key_b, *_state| [key_a, key_b] }
              else
                GROUPS_REVERSED.map { |key_a, key_b, *_state| [key_b, key_a] }
              end
      bytes = +''.b
      (0...pairs.size).step(2) { |index| bytes << pairs.fetch(index).pack('Q<Q<') }
      bytes << pairs.last.pack('Q<Q<')
      bytes.b
    end

    def expected_child_rowbinary(target)
      groups = target.fetch(:physical_order) == :ab ? GROUPS : GROUPS_REVERSED
      groups.map do |key_a, key_b, count, sum, min, max|
        key_bytes = target.fetch(:physical_order) == :ab ? [key_a, key_b].pack('Q<Q<') : [key_b, key_a].pack('Q<Q<')
        if target.fetch(:variant) == :all
          key_bytes + varuint(count) + [sum].pack('Q<').b + minmax_state(min) + minmax_state(max)
        else
          key_bytes + varuint(count)
        end
      end.join.b
    end

    def child_schema(table)
      query("child_schema_#{table}", "DESCRIBE TABLE mergeTreeProjection('#{DATABASE}','#{table}','#{PROJECTION}') FORMAT TSVRaw;")
        .lines(chomp: true).map { |line| line.split("\t", -1).take(2) }
    end

    def forced_projection!(stdout, table, filtered:, expected_keys: nil, expected_granules: nil)
      rows = stdout.lines(chomp: true).filter_map { |line| JSON.parse(line) rescue nil }
      fail!("#{table} EXPLAIN output has no JSON rows") if rows.empty?
      objects = []
      walk_json(rows) { |object| objects << object if object.is_a?(Hash) }
      readers = objects.select { |object| object['Node Type'] == 'ReadFromMergeTree' }
      fail!("#{table} EXPLAIN did not expose exactly one MergeTree read") unless readers.size == 1
      reader = readers.first
      fail!("#{table} EXPLAIN did not name #{PROJECTION}") unless reader['Description'] == PROJECTION
      result = {node_type: reader['Node Type'], node_id: reader['Node Id'], description: reader['Description']}
      if filtered
        indexes = reader['Indexes']
        indexes = JSON.parse(indexes) if indexes.is_a?(String)
        primary = Array(indexes).find { |entry| entry.is_a?(Hash) && entry['Type'] == 'PrimaryKey' }
        fail!("#{table} filtered EXPLAIN omitted the primary-key index") unless primary
        fail!("#{table} filtered primary-key order differs") unless primary['Keys'] == expected_keys
        initial = Integer(primary.fetch('Initial Granules'))
        selected = Integer(primary.fetch('Selected Granules'))
        fail!("#{table} filtered primary-key granules were not reduced") unless initial > 0 && selected > 0 && selected < initial
        if expected_granules
          fail!("#{table} filtered primary-key granule counts differ") unless [initial, selected] == expected_granules
        end
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
      end
    end

    def validate_reopen!(report)
      fail!('reopen helper format/status/root differs') unless report.is_a?(Hash) &&
        report['format'] == 'materialized_view_aggregate_projection_w294_helper_v1' && report['action'] == 'reopen' &&
        report['status'] == 'ok' && File.expand_path(report['catalog_root']) == @catalog_root
      pairs = report.fetch('pairs')
      fail!('reopen helper table roster differs') unless pairs.map { |pair| pair.fetch('table') }.sort == TARGETS.keys.sort
      pairs.each do |pair|
        table = pair.fetch('table')
        target = TARGETS.fetch(table)
        attached = @attached.fetch(table)
        expected_child = target.fetch(:variant) == :all ? COMPACT_CHILD_ROWS : WIDE_CHILD_ROWS
        expected_window = expected_child[1, 5]
        expected_count_rows = expected_child.map { |row| row.fetch(2) }
        expected_count_window = expected_count_rows[1, 5]
        fail!("#{table} offline identity or format differs") unless pair['part_name'] == attached.fetch(:part) &&
          pair['parent_format'] == target.fetch(:format) && pair['child_format'] == 'Wide'
        fail!("#{table} offline full/window values or mark grids differ") unless
          pair['parent_rows'] == PARENT_ROWS.map { |row| row.map(&:to_s) } && pair['child_rows'] == expected_child &&
          pair['parent_mark_rows'] == Array.new(9, 2) && pair['child_mark_rows'] == [2, 2, 2, 2] &&
          pair['parent_window_start_1_count_5'] == PARENT_ROWS[1, 5].map { |row| row.map(&:to_s) } &&
          pair['child_window_start_1_count_5'] == expected_window &&
          pair['parent_window_mark_rows'] == [1, 2, 2] && pair['child_window_mark_rows'] == [1, 2, 2]
        fail!("#{table} offline Count-only selection differs") unless
          pair['child_count_only_rows'] == expected_count_rows && pair['child_count_only_window'] == expected_count_window &&
          pair['count_only_mark_rows'] == [2, 2, 2, 2] && pair['count_only_window_mark_rows'] == [1, 2, 2]
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
      fail!('W294 witness sources changed during witness') unless input_hashes == @input_hashes
      fail!('repository HEAD changed during witness') unless git_revision == @revision_before
      fail!('stock source part changed during witness') unless inventory(@source_path) == @source_inventory
      @generated.each do |table, entry|
        fail!("#{table} generated part changed after ATTACH") unless inventory(entry.fetch(:path)) == entry.fetch(:inventory)
      end
      true
    end

    def assert_attached_files_preserved!(expected_inventory, actual_inventory, table, attached_path)
      expected = expected_inventory.fetch(:files).to_h { |entry| [entry.fetch(:relative_path), entry] }
      actual = actual_inventory.fetch(:files).to_h { |entry| [entry.fetch(:relative_path), entry] }
      fail!("#{table} ATTACH changed or removed generated part files") unless expected.all? { |name, entry| actual[name] == entry }
      extras = actual.keys - expected.keys
      fail!("#{table} ATTACH added unexpected sidecars: #{extras.inspect}") unless extras == [ATTACH_SIDECAR]
      bytes = File.binread(File.join(attached_path, ATTACH_SIDECAR))
      sidecar_entry = actual.fetch(ATTACH_SIDECAR)
      fail!("#{table} ATTACH sidecar bytes or digest differ") unless
        bytes == ATTACH_SIDECAR_BYTES && sidecar_entry.fetch(:sha256) == ATTACH_SIDECAR_SHA256
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
        'RUN_SAFE_PASSTHROUGH_STDIO' => '1', 'COGNI_RUN_SAFE_MIN_FREE_PCT' => '50',
        'TMPDIR' => File.join(@root, 'tmp'), 'TMP' => File.join(@root, 'tmp'), 'TEMP' => File.join(@root, 'tmp'),
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

    def assert_format!(path, format, label)
      children = Dir.children(path)
      compact = File.file?(File.join(path, 'data.mrk4'))
      wide = children.any? { |name| name.end_with?('.mrk2') }
      actual = if compact && !wide then 'Compact' elsif wide && !compact then 'Wide' else 'ambiguous' end
      fail!("#{label} marker family was #{actual}, expected #{format}") unless actual == format
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
      args.banner = 'Usage: ruby scripts/verify_materialized_view_aggregate_projection_w294.rb --evidence-root PATH --helper PREBUILT --run-safe PATH [--binary PATH]'
      args.on('--evidence-root PATH', 'Fresh evidence directory on /opt/mldata_ssd') { |value| options[:evidence_root] = value }
      args.on('--helper PATH', 'Prebuilt executable W294 Crystal helper') { |value| options[:helper] = value }
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

exit VerifyMaterializedViewAggregateProjectionW294.run
