#!/usr/bin/env ruby
# Bounded native witness for N-lane UInt64 aggregate projection children.
# Build the Crystal helper separately; this runner never starts a compiler.

require 'base64'
require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'open3'
require 'optparse'

module VerifyMaterializedViewAggregateProjectionW298
  extend self

  REPO_ROOT = File.expand_path('..', __dir__).freeze
  FORMAT = 'materialized_view_aggregate_projection_w298_native_v1'.freeze
  HELPER_FORMAT = 'materialized_view_aggregate_projection_w298_helper_v1'.freeze
  BINARY = '/opt/mldata_ssd/cache/crystal-click-w283.PDWAiK/recovery/runtime/clickhouse'.freeze
  BINARY_SHA256 = '5bb43958f4c0806cc363b84b9858e7206e56ac80263a24acc704271322e531ae'.freeze
  VERSION = '26.10.1.1201'.freeze
  REVISION = '54515'.freeze
  RUN_SAFE_SHA256 = 'fbfa0fd9d717eb24c1a3f829d464188110e505c7ae311eee2e95cbe7cefab011'.freeze
  DATABASE = 'lab'.freeze
  DATABASE_UUID = 'f2980000-7b7f-4e2f-9e44-dc13a8788001'.freeze
  SOURCE_UUID = 'f2980000-7b7f-4e2f-9e44-dc13a8788002'.freeze
  SOURCE_PART = 'all_1_1_0'.freeze
  PROJECTION = 'by_group'.freeze
  KEY_NAMES = %w[key_a key_b key_c key_d].freeze
  AGGREGATES = %w[count() sum(value) min(value) max(value)].freeze
  PARENT_COLUMNS = [['parent_id', 'UInt64'], *KEY_NAMES.map { |name| [name, 'UInt64'] }, ['value', 'UInt64']].freeze
  SOURCE_COLUMNS = [['source_id', 'UInt64'], *KEY_NAMES.map { |name| [name, 'UInt64'] }, ['value', 'UInt64']].freeze
  ASYMMETRIC = 0x0102030405060708
  UINT64_MAX = (1 << 64) - 1
  SOURCE_ROWS = [
    [1, 6, 10, 5, 100, 0], [2, 6, 10, 5, 100, ASYMMETRIC],
    [3, 6, 10, 5, 200, UINT64_MAX], [4, 6, 10, 7, 1, 17],
    [5, 5, 0, 0, 0, 42], [6, 6, 11, 0, 0, 23], [7, 6, 11, 0, 0, 99],
    [8, 7, 0, 3, 4, 1], [9, 7, 0, 3, 4, 2], [10, 7, 1, 2, 0, 3],
    [11, 8, 1, 0, 5, 4],
    [12, UINT64_MAX, 0, ASYMMETRIC, 0, ASYMMETRIC],
    [13, UINT64_MAX, 0, ASYMMETRIC, 1, UINT64_MAX],
    [14, UINT64_MAX, 0, UINT64_MAX, 0, 0],
    [15, UINT64_MAX, ASYMMETRIC, 0, 0, 17],
    [16, UINT64_MAX, UINT64_MAX, UINT64_MAX, UINT64_MAX, 42],
  ].map(&:freeze).freeze
  PARENT_ROWS = SOURCE_ROWS.map { |row| [row[0] + 100, *row.drop(1)].freeze }.freeze
  PARENT_ROWS_PER_MARK = 2
  CHILD_ROWS_PER_MARK = 2
  PARENT_MARK_ROWS = Array.new(PARENT_ROWS.size / 2, 2).freeze
  GROUPS = begin
    grouped = SOURCE_ROWS.group_by { |row| row[1, 4] }
    grouped.to_h do |keys, rows|
      values = rows.map(&:last)
      [keys.freeze, {count: values.size, sum: values.sum & UINT64_MAX, min: values.min, max: values.max}.freeze]
    end.freeze
  end
  TARGETS = [
    {table: 'target_ww', control: 'control_ww', uuid: 'f2980000-7b7f-4e2f-9e44-dc13a8788010', control_uuid: 'f2980000-7b7f-4e2f-9e44-dc13a8788020', view: 'view_ww', view_uuid: 'f2980000-7b7f-4e2f-9e44-dc13a8788030', part: SOURCE_PART, parent_format: 'Wide', child_format: 'Wide', order: %w[key_a key_b key_c key_d]},
    {table: 'target_wc', control: 'control_wc', uuid: 'f2980000-7b7f-4e2f-9e44-dc13a8788011', control_uuid: 'f2980000-7b7f-4e2f-9e44-dc13a8788021', view: 'view_wc', view_uuid: 'f2980000-7b7f-4e2f-9e44-dc13a8788031', part: SOURCE_PART, parent_format: 'Wide', child_format: 'Compact', order: %w[key_d key_c key_b key_a]},
    {table: 'target_cw', control: 'control_cw', uuid: 'f2980000-7b7f-4e2f-9e44-dc13a8788012', control_uuid: 'f2980000-7b7f-4e2f-9e44-dc13a8788022', view: 'view_cw', view_uuid: 'f2980000-7b7f-4e2f-9e44-dc13a8788032', part: SOURCE_PART, parent_format: 'Compact', child_format: 'Wide', order: %w[key_b key_d key_a key_c]},
    {table: 'target_cc', control: 'control_cc', uuid: 'f2980000-7b7f-4e2f-9e44-dc13a8788013', control_uuid: 'f2980000-7b7f-4e2f-9e44-dc13a8788023', view: 'view_cc', view_uuid: 'f2980000-7b7f-4e2f-9e44-dc13a8788033', part: SOURCE_PART, parent_format: 'Compact', child_format: 'Compact', order: %w[key_c key_a key_d key_b]},
  ].map(&:freeze).freeze
  MEMORY_BYTES = 536_870_912
  PROCESS_MEMORY_MIB = 2048
  PROCESS_TIMEOUT_SECONDS = 90
  MAX_CAPTURE_BYTES = 16 * 1024 * 1024
  MAX_PART_FILES = 256
  MAX_PART_BYTES = 32 * 1024 * 1024
  ATTACH_SIDECAR = 'invalidated_system_columns.txt'.freeze
  ATTACH_SIDECAR_BYTES = "_block_offset\n_block_number\n".b.freeze
  INPUT_FILES = %w[
    scripts/verify_materialized_view_aggregate_projection_w298.rb
    scripts/check_materialized_view_aggregate_projection_w298.cr
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
      @parts = {}
      @stock = {}
      @generated = {}
      @attached = {}
    end

    def run
      prepare!
      create_source!
      insert_source!
      create_targets_and_controls!
      insert_controls!
      discover_native_parts!
      verify_stock_controls!
      build_catalog!
      publish = helper('publish')
      validate_publish!(publish)
      verify_generated_parts!
      copy_to_detached!
      attach_and_check!
      native_checks = verify_native_reads!
      copy_attached_to_catalog!
      reopened = helper('reopen')
      validate_reopen!(reopened)
      validate_inputs_unchanged!
      write_summary(
        status: 'four_parent_child_layout_pairings_attached_checked_and_offline_scanned',
        binary: {path: @binary, sha256: @binary_sha, version: VERSION, revision: REVISION},
        helper: {path: @helper, sha256: @helper_sha}, run_safe: {path: @run_safe, sha256: @guard_sha},
        source: @source_part, stock_controls: stock_control_summary, published: publish, generated: @generated,
        attached: @attached, native_checks: native_checks, offline_reopen: reopened,
        invocations: @processes, evidence_root: @root,
      )
      puts "W298 four-layout N-key projection witness passed; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error = "#{error.class}: #{error.message}"
      write_summary(status: 'witness_failure_or_observations_differ', fatal_error: @fatal_error,
                    evidence_root: @root) rescue nil
      warn "W298 probe failure (process failure is not native format evidence): #{@fatal_error}"
      false
    end

    private

    def prepare!
      @root = validate_evidence_root(@root_arg)
      @binary = validate_pinned_file!(@binary_arg, BINARY_SHA256, 'ClickHouse runtime')
      @helper = validate_executable!(@helper_arg, 'prebuilt Crystal helper')
      @run_safe = validate_pinned_file!(@run_safe_arg, RUN_SAFE_SHA256, 'run_safe guard')
      @binary_sha = sha_file(@binary)
      @helper_sha = sha_file(@helper)
      @guard_sha = sha_file(@run_safe)
      @input_hashes = input_hashes
      @revision = git_revision
      %w[native catalog helper tmp processes].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      @native_store = File.join(@root, 'native', 'store')
      @catalog_root = File.join(@root, 'catalog', 'offline_catalog')
    end

    def validate_evidence_root(path)
      fail!('fresh evidence root is required') unless path.is_a?(String) && !path.empty?
      expanded = File.expand_path(path)
      parent = File.dirname(expanded)
      fail!('evidence root parent must exist') unless File.directory?(parent)
      real_parent = File.realpath(parent)
      parent_stat = File.stat(real_parent)
      fail!('evidence root must be on the non-system volume') if parent_stat.dev == File.stat('/').dev
      full = File.join(real_parent, File.basename(expanded))
      fail!('evidence root already exists or is a symlink') if File.exist?(full) || File.symlink?(full)
      Dir.mkdir(full, 0o700)
      stat = File.lstat(full)
      fail!('evidence root ownership, device, or canonicality differs') unless
        File.realpath(full) == full && stat.directory? && !stat.symlink? && stat.uid == Process.uid && stat.dev == parent_stat.dev
      full
    rescue Errno::ENOENT
      fail!('evidence root parent or path is absent')
    end

    def validate_pinned_file!(path, sha, label)
      full = File.realpath(File.expand_path(path))
      fail!("#{label} is absent or not executable") unless File.file?(full) && File.executable?(full)
      fail!("#{label} SHA-256 differs from the pin") unless sha_file(full) == sha
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
      native('create_source', <<~SQL)
        CREATE DATABASE #{DATABASE} UUID '#{DATABASE_UUID}' ENGINE = Atomic;
        CREATE TABLE #{DATABASE}.source UUID '#{SOURCE_UUID}'
        (
          source_id UInt64, key_a UInt64, key_b UInt64, key_c UInt64, key_d UInt64, value UInt64
        ) ENGINE = MergeTree ORDER BY source_id
        SETTINGS index_granularity=2, min_rows_for_wide_part=0, min_bytes_for_wide_part=0,
                 compress_marks=0, compress_primary_key=0, replace_long_file_name_to_hash=0;
        SELECT version(), revision() FORMAT TSVRaw;
      SQL
    end

    def insert_source!
      bytes = SOURCE_ROWS.map { |row| row.pack('Q<' * row.size) }.join.b
      out = native('insert_source', "INSERT INTO #{DATABASE}.source FORMAT RowBinary\n".b + bytes)
      fail!('source RowBinary insert emitted stdout') unless out.empty?
    end

    def create_targets_and_controls!
      sql = TARGETS.map do |target|
        table_sql(target, target.fetch(:table), target.fetch(:uuid), materialized_view: true) +
          table_sql(target, target.fetch(:control), target.fetch(:control_uuid), materialized_view: false)
      end.join("\n")
      native('create_targets_and_controls', sql.b)
      TARGETS.each do |target|
        fail!("#{target.fetch(:table)} target was not empty") unless
          query("empty_#{target.fetch(:table)}", "SELECT toString(count()) FROM system.parts WHERE database='#{DATABASE}' AND table='#{target.fetch(:table)}' AND active FORMAT TSVRaw;").strip == '0'
      end
    end

    def table_sql(target, table, uuid, materialized_view:)
      keys = target.fetch(:order)
      child_threshold = target.fetch(:child_format) == 'Wide' ? 0 : 1000
      parent_threshold = target.fetch(:parent_format) == 'Wide' ? 0 : 1000
      compressed = target.fetch(:parent_format) == 'Compact' ? 1 : 0
      # The offline Object-stream reader intentionally rejects compressed MRK2.
      # Keep this one stock Compact-parent/Wide-child control readable while
      # retaining compressed marks in the Compact/Compact stock cell.
      if !materialized_view && target.fetch(:parent_format) == 'Compact' && target.fetch(:child_format) == 'Wide'
        compressed = 0
      end
      projection = "PROJECTION #{PROJECTION} (SELECT #{(keys + AGGREGATES).join(', ')} GROUP BY #{keys.join(', ')}) WITH SETTINGS (min_rows_for_wide_part = #{child_threshold}, index_granularity = 2)"
      schema = 'parent_id UInt64, key_a UInt64, key_b UInt64, key_c UInt64, key_d UInt64, value UInt64'
      statement = <<~SQL
        CREATE TABLE #{DATABASE}.#{table} UUID '#{uuid}'
        (#{schema}, #{projection}) ENGINE = MergeTree ORDER BY parent_id
        SETTINGS index_granularity=2, min_rows_for_wide_part=#{parent_threshold}, min_bytes_for_wide_part=0,
                 compress_marks=#{compressed}, compress_primary_key=0, replace_long_file_name_to_hash=0;
      SQL
      return statement unless materialized_view

      <<~SQL
        #{statement}
        CREATE MATERIALIZED VIEW #{DATABASE}.#{target.fetch(:view)} UUID '#{target.fetch(:view_uuid)}'
        TO #{DATABASE}.#{table} (#{schema})
        AS SELECT source_id + 100 AS parent_id, key_a, key_b, key_c, key_d, value FROM #{DATABASE}.source;
      SQL
    end

    def insert_controls!
      sql = TARGETS.map do |target|
        "INSERT INTO #{DATABASE}.#{target.fetch(:control)} SELECT source_id + 100, key_a, key_b, key_c, key_d, value FROM #{DATABASE}.source;"
      end.join("\n")
      native('insert_controls', sql.b)
    end

    def discover_native_parts!
      names = ['source'] + TARGETS.flat_map { |target| [target.fetch(:table), target.fetch(:control), target.fetch(:view)] }
      sql = <<~SQL
        SELECT '__TABLES__' FORMAT TSVRaw;
        SELECT name, base64Encode(metadata_path), arrayElement(data_paths, 1)
        FROM system.tables WHERE database='#{DATABASE}' AND name IN (#{names.map { |name| "'#{name}'" }.join(',')})
        ORDER BY name FORMAT TSVRaw;
        SELECT '__PARTS__' FORMAT TSVRaw;
        SELECT table, name, part_type, toString(rows), toString(marks), path FROM system.parts
        WHERE database='#{DATABASE}' AND active AND table IN (#{(['source'] + TARGETS.map { |target| target.fetch(:control) }).map { |name| "'#{name}'" }.join(',')})
        ORDER BY table FORMAT TSVRaw;
        SELECT '__PROJECTIONS__' FORMAT TSVRaw;
        SELECT table, name, parent_name, part_type, parent_part_type, toString(rows), toString(marks), path
        FROM system.projection_parts WHERE database='#{DATABASE}' AND active
        ORDER BY table FORMAT TSVRaw;
        SELECT version(), revision() FORMAT TSVRaw;
      SQL
      sections = {}
      current = nil
      query('discover_native_parts', sql).lines(chomp: true).reject(&:empty?).each do |line|
        case line
        when '__TABLES__' then current = :tables; next
        when '__PARTS__' then current = :parts; next
        when '__PROJECTIONS__' then current = :projections; next
        when "#{VERSION}\t#{REVISION}" then next
        end
        (sections[current] ||= []) << line
      end
      table_rows = Array(sections[:tables])
      expected_names = names.sort
      fail!('native metadata table roster differs') unless table_rows.size == expected_names.size
      observed_names = table_rows.map { |line| line.split("\t", 2).first }
      fail!('native metadata table names differ') unless observed_names.sort == expected_names
      table_rows.each do |line|
        name, encoded, path = line.split("\t", -1)
        fail!('native metadata row malformed') unless name && encoded && path
        begin
          @metadata[name] = Base64.strict_decode64(encoded)
        rescue ArgumentError
          fail!('native metadata path is malformed base64')
        end
        @native_paths[name] = store_path!(path) unless path.empty?
      end
      Array(sections[:parts]).each do |line|
        table, name, format, rows, marks, path = line.split("\t", -1)
        @parts[table] = {name: name, format: format, rows: rows.to_i, marks: marks.to_i,
                         path: part_path!(path, table, name)}
      end
      Array(sections[:projections]).each do |line|
        table, name, parent_name, format, parent_format, rows, marks, path = line.split("\t", -1)
        @stock[table] = {name: name, parent_name: parent_name, format: format, parent_format: parent_format,
                         rows: rows.to_i, marks: marks.to_i, path: File.expand_path(path)}
      end
      fail!('native version/revision does not match pinned ClickHouse') unless
        query('version_check', 'SELECT version(), revision() FORMAT TSVRaw;').strip == "#{VERSION}\t#{REVISION}"
    end

    def verify_stock_controls!
      expected_control_names = TARGETS.map { |target| target.fetch(:control) }
      fail!('source active part identity or axes differ') unless @parts['source'] == {
        name: SOURCE_PART, format: 'Wide', rows: SOURCE_ROWS.size, marks: PARENT_ROWS.size / 2 + 1,
        path: File.join(@native_paths.fetch('source'), SOURCE_PART),
      }
      source_check = query('source_check', "CHECK TABLE #{DATABASE}.source FORMAT TSV;")
      assert_bytes!(source_check, "#{SOURCE_PART}\t1\t\n".b, 'stock source CHECK TABLE')
      raw_source = query('source_rows', "SELECT source_id, key_a, key_b, key_c, key_d, value FROM #{DATABASE}.source ORDER BY source_id FORMAT RowBinary;")
      assert_bytes!(raw_source, SOURCE_ROWS.map { |row| row.pack('Q<' * row.size) }.join.b, 'stock source RowBinary')
      fail!('stock source row format is not Wide') unless @parts.fetch('source').fetch(:format) == 'Wide'
      TARGETS.each do |target|
        table = target.fetch(:control)
        part = @parts.fetch(table)
        expected_marks = (PARENT_ROWS.size / 2) + 1
        fail!("#{table} stock parent identity, type, or axes differ") unless
          part.fetch(:name) == SOURCE_PART && part.fetch(:format) == target.fetch(:parent_format) &&
          part.fetch(:rows) == PARENT_ROWS.size && part.fetch(:marks) == expected_marks
        child = @stock.fetch(table)
        fail!("#{table} stock projection identity, child format, parent format, or axes differ") unless
          child.fetch(:name) == PROJECTION && child.fetch(:parent_name) == SOURCE_PART &&
          child.fetch(:format) == target.fetch(:child_format) && child.fetch(:parent_format) == target.fetch(:parent_format) &&
          child.fetch(:rows) == GROUPS.size && child.fetch(:marks) == child_system_marks
        parent_path = part.fetch(:path)
        child_path = File.join(parent_path, "#{PROJECTION}.proj")
        fail!("#{table} stock projection path differs") unless child.fetch(:path) == child_path
        stock_compressed = stock_control_marks_compressed?(target)
        assert_format!(parent_path, target.fetch(:parent_format), "#{table} stock parent", compressed: stock_compressed)
        assert_format!(child_path, target.fetch(:child_format), "#{table} stock projection", compressed: stock_compressed)
        schema = child_schema(table)
        expected_schema = target.fetch(:order).map { |name| [name, 'UInt64'] } + [
          ['count()', 'AggregateFunction(count)'], ['sum(value)', 'AggregateFunction(sum, UInt64)'],
          ['min(value)', 'AggregateFunction(min, UInt64)'], ['max(value)', 'AggregateFunction(max, UInt64)'],
        ]
        fail!("#{table} stock child schema differs") unless schema == expected_schema
        index = File.binread(File.join(child_path, 'primary.idx'))
        assert_bytes!(index, expected_primary_index(target), "#{table} stock primary.idx vs literal N-key schedule")
        raw = query("stock_raw_#{table}", <<~SQL)
          SELECT * FROM mergeTreeProjection('#{DATABASE}','#{table}','#{PROJECTION}')
          ORDER BY #{target.fetch(:order).join(',')} FORMAT RowBinary;
        SQL
        assert_bytes!(raw, expected_child_rowbinary(target), "#{table} stock child state RowBinary vs literal states")
        @stock[table].merge!(primary_index: index, child_rowbinary: raw, schema: schema,
                             parent_marks_compressed: stock_compressed, child_marks_compressed: stock_compressed,
                             inventory: inventory(parent_path), child_inventory: inventory(child_path))
      end
      control_checks = expected_control_names.map { |name| "CHECK TABLE #{DATABASE}.#{name} FORMAT TSV;" }.join("\n")
      check = query('control_checks', control_checks)
      expected = expected_control_names.map { |name| "#{@parts.fetch(name).fetch(:name)}\t1\t\n" }.join.b
      assert_bytes!(check, expected, 'native stock control CHECK TABLE roster')
      @source_part = {part: SOURCE_PART, rows: SOURCE_ROWS.size, path: @parts.fetch('source').fetch(:path),
                      inventory: inventory(@parts.fetch('source').fetch(:path)), rowbinary_sha256: Digest::SHA256.hexdigest(raw_source)}
    end

    def build_catalog!
      FileUtils.mkdir_p(File.join(@catalog_root, 'metadata'), mode: 0o700)
      write_new(File.join(@catalog_root, 'metadata', 'lab.sql'), "ATTACH DATABASE _ UUID '#{DATABASE_UUID}'\nENGINE = Atomic\n")
      catalog_tables = {'source' => [SOURCE_UUID, 'TABLE']}
      TARGETS.each do |target|
        catalog_tables[target.fetch(:table)] = [target.fetch(:uuid), 'TABLE']
        catalog_tables[target.fetch(:control)] = [target.fetch(:control_uuid), 'TABLE']
        catalog_tables[target.fetch(:view)] = [target.fetch(:view_uuid), 'MATERIALIZED VIEW']
      end
      database_path = uuid_path(DATABASE_UUID)
      FileUtils.mkdir_p(database_path, mode: 0o700)
      catalog_tables.each do |name, (uuid, kind)|
        table_path = uuid_path(uuid)
        FileUtils.mkdir_p(table_path, mode: 0o700)
        write_new(File.join(table_path, 'format_version.txt'), "1\n") unless kind == 'MATERIALIZED VIEW'
        FileUtils.mkdir_p(File.join(table_path, 'detached'), mode: 0o700) if TARGETS.any? { |target| target.fetch(:table) == name }
        metadata = File.realpath(File.expand_path(@metadata.fetch(name), @native_store))
        fail!("#{name} metadata path escaped native store") unless metadata.start_with?(File.realpath(@native_store) + File::SEPARATOR)
        ddl = File.binread(metadata)
        fail!("#{name} persisted metadata is oversized or invalid UTF-8") if ddl.bytesize > 1_048_576 || !ddl.dup.force_encoding(Encoding::UTF_8).valid_encoding?
        fail!("#{name} persisted metadata identity differs") unless /\A\s*ATTACH\s+#{Regexp.escape(kind)}\s+_\s+UUID\s+'#{Regexp.escape(uuid)}'/im.match?(ddl)
        if target = TARGETS.find { |entry| entry.fetch(:table) == name }
          ddl = sanitize_catalog_target_ddl!(target, ddl)
        end
        write_new(File.join(database_path, "#{name}.sql"), ddl)
      end
      source_copy = File.join(uuid_path(SOURCE_UUID), SOURCE_PART)
      copy_tree(@parts.fetch('source').fetch(:path), source_copy)
      fail!('OfflineCatalog source copy differs') unless inventory(source_copy) == @source_part.fetch(:inventory)
      TARGETS.each do |target|
        control = target.fetch(:control)
        destination = File.join(uuid_path(target.fetch(:control_uuid)), SOURCE_PART)
        copy_tree(@parts.fetch(control).fetch(:path), destination)
        fail!("#{control} stock copy differs") unless inventory(destination) == @stock.fetch(control).fetch(:inventory)
      end
      {root: @catalog_root, source_copy: source_copy, controls: TARGETS.map { |target| target.fetch(:control) }}
    end

    def sanitize_catalog_target_ddl!(target, ddl)
      # The native fixture explicitly selects these writer details and verifies
      # their stock bytes. OfflineCatalog transform admission consumes only the
      # layout settings, so strip exactly the already-checked writer flags from
      # this copied metadata and retain the live native metadata untouched.
      setting_start = ddl.rindex(/\bSETTINGS\b/i)
      fail!("#{target.fetch(:table)} metadata has no trailing table SETTINGS") unless setting_start
      body_start = setting_start + 'SETTINGS'.bytesize
      body = ddl[body_start..]
      fail!("#{target.fetch(:table)} metadata SETTINGS body is absent") unless body
      settings = {}
      body.split(',', -1).each do |entry|
        match = /\A\s*([a-z][a-z0-9_]*)\s*=\s*([0-9]+)\s*\z/i.match(entry)
        fail!("#{target.fetch(:table)} metadata has unsupported SETTINGS syntax") unless match
        key = match[1].downcase
        fail!("#{target.fetch(:table)} metadata repeats a SETTINGS key") if settings.key?(key)
        settings[key] = match[2]
      end

      expected = {
        'index_granularity' => '2',
        'min_rows_for_wide_part' => target.fetch(:parent_format) == 'Wide' ? '0' : '1000',
        'min_bytes_for_wide_part' => '0',
        'compress_marks' => target.fetch(:parent_format) == 'Compact' ? '1' : '0',
        'compress_primary_key' => '0',
        'replace_long_file_name_to_hash' => '0',
      }
      fail!("#{target.fetch(:table)} metadata SETTINGS differ from the fixture-selected writer options") unless settings == expected

      newline = body.end_with?("\n") ? "\n" : ''
      layout_settings = "SETTINGS index_granularity = 2, min_rows_for_wide_part = #{expected.fetch('min_rows_for_wide_part')}, min_bytes_for_wide_part = 0#{newline}"
      ddl[0...setting_start] + layout_settings
    end

    def validate_publish!(report)
      fail!('publish helper format/action/status differs') unless report.is_a?(Hash) &&
        report['format'] == HELPER_FORMAT && report['action'] == 'publish' && report['status'] == 'ok'
      fail!('publish source row count differs') unless report['source_row_count'] == SOURCE_ROWS.size
      targets = Array(report['targets']).to_h { |entry| [entry.fetch('table'), entry] }
      fail!('publish helper target roster differs') unless targets.keys.sort == TARGETS.map { |target| target.fetch(:table) }.sort
      TARGETS.each do |target|
        entry = targets.fetch(target.fetch(:table))
        expected_rows = expected_child_rows(target).map { |row| row.map(&:to_s) }
        fail!("#{target.fetch(:table)} published rows or formats differ") unless
          entry['part'] == target.fetch(:part) && entry['parent_format'] == target.fetch(:parent_format) &&
          entry['child_format'] == target.fetch(:child_format) && entry['keys'] == target.fetch(:order) &&
          entry['rows'] == expected_rows && entry['parent_rows'] == PARENT_ROWS.map { |row| row.map(&:to_s) } &&
          entry['parent_mark_rows'] == PARENT_MARK_ROWS && entry['child_mark_rows'] == child_mark_rows
        path = File.expand_path(entry.fetch('path'))
        expected = File.join(@catalog_root, 'store', target.fetch(:uuid)[0, 3], target.fetch(:uuid), 'detached', target.fetch(:part))
        fail!("#{target.fetch(:table)} published destination differs") unless path == expected
        @generated[target.fetch(:table)] = {path: path, table: target.fetch(:table), part: target.fetch(:part),
                                             inventory: inventory(path), child_inventory: inventory(File.join(path, "#{PROJECTION}.proj"))}
      end
      report
    end

    def verify_generated_parts!
      TARGETS.each do |target|
        table = target.fetch(:table)
        child_path = File.join(@generated.fetch(table).fetch(:path), "#{PROJECTION}.proj")
        assert_format!(@generated.fetch(table).fetch(:path), target.fetch(:parent_format), "#{table} generated parent", compressed: target.fetch(:parent_format) == 'Compact')
        # Native ClickHouse projections inherit the parent's mark compression
        # setting. Crystal's Wide projection writer emits plain marks; Compact
        # children use the explicit child option selected in the helper.
        assert_format!(child_path, target.fetch(:child_format), "#{table} generated child", compressed: generated_child_marks_compressed?(target))
        index = File.binread(File.join(child_path, 'primary.idx'))
        assert_bytes!(index, expected_primary_index(target), "#{table} generated primary.idx vs literal schedule")
        assert_bytes!(index, @stock.fetch(target.fetch(:control)).fetch(:primary_index), "#{table} generated primary.idx vs stock")
        @generated.fetch(table)[:primary_index_hex] = index.unpack1('H*')
      end
    end

    def copy_to_detached!
      TARGETS.each do |target|
        table = target.fetch(:table)
        detached = File.join(@native_paths.fetch(table), 'detached')
        if File.exist?(detached) || File.symlink?(detached)
          fail!("#{table} detached directory is unsafe or occupied") unless File.directory?(detached) && !File.symlink?(detached) && Dir.children(detached).empty?
        else
          Dir.mkdir(detached, 0o700)
        end
        destination = File.join(detached, target.fetch(:part))
        copy_tree(@generated.fetch(table).fetch(:path), destination)
        fail!("#{table} detached copy changed hashes") unless inventory(destination) == @generated.fetch(table).fetch(:inventory)
        @generated.fetch(table)[:native_detached_path] = destination
      end
    end

    def attach_and_check!
      TARGETS.each do |target|
        table = target.fetch(:table)
        native("attach_#{table}", "ALTER TABLE #{DATABASE}.#{table} ATTACH PART '#{target.fetch(:part)}';\n".b)
        check = query("check_#{table}", "CHECK TABLE #{DATABASE}.#{table} FORMAT TSV;")
        assert_bytes!(check, "#{target.fetch(:part)}\t1\t\n".b, "#{table} CHECK TABLE")
        parent = one_row(query("attached_parent_#{table}", <<~SQL), 5, "#{table} attached parent")
          SELECT name, part_type, toString(rows), toString(marks), path FROM system.parts
          WHERE database='#{DATABASE}' AND table='#{table}' AND active FORMAT TSVRaw;
        SQL
        fail!("#{table} attached parent identity/type/axes differ") unless parent[0] == target.fetch(:part) &&
          parent[1] == target.fetch(:parent_format) && parent[2].to_i == PARENT_ROWS.size && parent[3].to_i == (PARENT_ROWS.size / PARENT_ROWS_PER_MARK) + 1
        parent_path = part_path!(parent[4], table, target.fetch(:part))
        child = one_row(query("attached_child_#{table}", <<~SQL), 7, "#{table} attached projection")
          SELECT name, parent_name, part_type, parent_part_type, toString(rows), toString(marks), path
          FROM system.projection_parts WHERE database='#{DATABASE}' AND table='#{table}' AND active FORMAT TSVRaw;
        SQL
        child_path = File.join(parent_path, "#{PROJECTION}.proj")
        fail!("#{table} attached child identity/type/axes differ") unless child[0] == PROJECTION && child[1] == parent[0] &&
          child[2] == target.fetch(:child_format) && child[3] == target.fetch(:parent_format) &&
          child[4].to_i == GROUPS.size && child[5].to_i == child_system_marks && File.expand_path(child[6]) == child_path
        expected_inventory = @generated.fetch(table).fetch(:inventory)
        attached_inventory = inventory(parent_path)
        assert_attached_files_preserved!(expected_inventory, attached_inventory, table, parent_path)
        assert_format!(parent_path, target.fetch(:parent_format), "#{table} attached parent", compressed: target.fetch(:parent_format) == 'Compact')
        assert_format!(child_path, target.fetch(:child_format), "#{table} attached child", compressed: generated_child_marks_compressed?(target))
        @attached[table] = {part: parent[0], parent_path: parent_path, child_path: child_path,
                            inventory: attached_inventory, primary_index_hex: File.binread(File.join(child_path, 'primary.idx')).unpack1('H*')}
      end
    end

    def verify_native_reads!
      TARGETS.to_h do |target|
        table = target.fetch(:table)
        control = target.fetch(:control)
        keys = target.fetch(:order)
        all = verify_query_pair(table, target, nil, 'full')
        prefix_filter = prefix_filter_for(target)
        boundary_filter = {'key_a' => UINT64_MAX, 'key_b' => UINT64_MAX,
                           'key_c' => UINT64_MAX, 'key_d' => UINT64_MAX}
        prefix = verify_query_pair(table, target, prefix_filter, 'multi_key_prefix')
        boundary = verify_query_pair(table, target, boundary_filter, 'uint64_max_boundary')
        refinement = nil
        if table == 'target_ww'
          prefix_group = ordered_groups(target, filters: prefix_filter).first
          fail!('target_ww chosen three-key prefix has no literal group') unless prefix_group
          exact_filter = prefix_filter.merge(keys.fetch(3) => prefix_group.first.fetch(3))
          refinement = verify_query_pair(table, target, exact_filter, 'fourth_key_refinement')
          prefix_key = prefix.fetch(:plan).fetch(:primary_key)
          exact_key = refinement.fetch(:plan).fetch(:primary_key)
          prefix_initial = Integer(prefix_key.fetch('Initial Granules'))
          prefix_selected = Integer(prefix_key.fetch('Selected Granules'))
          exact_initial = Integer(exact_key.fetch('Initial Granules'))
          exact_selected = Integer(exact_key.fetch('Selected Granules'))
          fail!('target_ww three-key prefix must select two of the seven granules') unless
            prefix_initial == 7 && prefix_selected == 2
          fail!('target_ww fourth key did not narrow that prefix to one of its two granules') unless
            exact_initial == prefix_initial && exact_selected == 1 && prefix_selected > exact_selected
        end
        raw = query("attached_raw_#{table}", <<~SQL)
          SELECT * FROM mergeTreeProjection('#{DATABASE}','#{table}','#{PROJECTION}')
          ORDER BY #{keys.join(',')} FORMAT RowBinary;
        SQL
        assert_bytes!(raw, expected_child_rowbinary(target), "#{table} attached state RowBinary vs literal")
        assert_bytes!(raw, @stock.fetch(control).fetch(:child_rowbinary), "#{table} attached state RowBinary vs stock")
        index = File.binread(File.join(@attached.fetch(table).fetch(:child_path), 'primary.idx'))
        assert_bytes!(index, expected_primary_index(target), "#{table} attached primary.idx vs literal")
        assert_bytes!(index, @stock.fetch(control).fetch(:primary_index), "#{table} attached primary.idx vs stock")
        parent_raw = query("parent_rows_#{table}", <<~SQL)
          SELECT parent_id, key_a, key_b, key_c, key_d, value FROM #{DATABASE}.#{table}
          ORDER BY parent_id SETTINGS optimize_use_projections=0 FORMAT RowBinary;
        SQL
        assert_bytes!(parent_raw, PARENT_ROWS.map { |row| row.pack('Q<' * row.size) }.join.b, "#{table} parent rows")
        [table, {full: all, multi_key_prefix: prefix, fourth_key_refinement: refinement,
                 uint64_max_boundary: boundary,
                 state_rowbinary_sha256: Digest::SHA256.hexdigest(raw), primary_index_hex: index.unpack1('H*'),
                 parent_rowbinary_sha256: Digest::SHA256.hexdigest(parent_raw), schema: child_schema(table)}]
      end
    end

    def verify_query_pair(table, target, filters, label)
      disabled = query("#{label}_disabled_#{table}", grouped_sql(table, target, filters, forced: false))
      forced = query("#{label}_forced_#{table}", grouped_sql(table, target, filters, forced: true))
      expected = expected_grouped(target, filters: filters)
      assert_bytes!(disabled, expected, "#{table} #{label} aggregation without projection")
      assert_bytes!(forced, expected, "#{table} #{label} forced projection aggregation")
      plan = assert_projection_plan!(query("#{label}_explain_#{table}", explain_sql(table, target, filters)), table, target, filters)
      {expected_sha256: Digest::SHA256.hexdigest(expected), disabled_sha256: Digest::SHA256.hexdigest(disabled),
       forced_sha256: Digest::SHA256.hexdigest(forced), filters: filters, plan: plan}
    end

    def grouped_sql(table, target, filters, forced:)
      order = target.fetch(:order)
      selected = (order + AGGREGATES).join(', ')
      where = filters && !filters.empty? ? " WHERE #{filters.map { |key, value| "#{key} = #{value}" }.join(' AND ')}" : ''
      settings = forced ? "force_optimize_projection=1, force_optimize_projection_name='#{PROJECTION}'" : 'optimize_use_projections=0'
      "SELECT #{selected} FROM #{DATABASE}.#{table}#{where} GROUP BY #{order.join(', ')} ORDER BY #{order.join(', ')} SETTINGS #{settings} FORMAT TSVRaw;"
    end

    def explain_sql(table, target, filters)
      order = target.fetch(:order)
      where = filters && !filters.empty? ? " WHERE #{filters.map { |key, value| "#{key} = #{value}" }.join(' AND ')}" : ''
      <<~SQL
        EXPLAIN json=1, description=1, projections=1, indexes=1
        SELECT #{(order + AGGREGATES).join(', ')} FROM #{DATABASE}.#{table}#{where}
        GROUP BY #{order.join(', ')} ORDER BY #{order.join(', ')}
        SETTINGS force_optimize_projection=1, force_optimize_projection_name='#{PROJECTION}' FORMAT JSONEachRow;
      SQL
    end

    def assert_projection_plan!(output, table, target, filters)
      rows = output.lines(chomp: true).filter_map { |line| JSON.parse(line) rescue nil }
      fail!("#{table} EXPLAIN output has no JSON rows") if rows.empty?
      objects = []
      walk_json(rows) { |object| objects << object if object.is_a?(Hash) }
      readers = objects.select { |object| object['Node Type'] == 'ReadFromMergeTree' }
      fail!("#{table} EXPLAIN did not expose one MergeTree read") unless readers.size == 1
      reader = readers.first
      fail!("#{table} EXPLAIN did not name #{PROJECTION}") unless reader['Description'] == PROJECTION
      result = {node_type: reader['Node Type'], description: reader['Description']}
      return result unless filters
      indexes = reader['Indexes']
      indexes = JSON.parse(indexes) if indexes.is_a?(String)
      primary = Array(indexes).find { |entry| entry.is_a?(Hash) && entry['Type'] == 'PrimaryKey' }
      fail!("#{table} EXPLAIN omitted its projection primary key") unless primary
      expected_keys = target.fetch(:order).take_while { |name| filters.key?(name) }
      fail!("#{table} EXPLAIN has no constrained leading projection key") if expected_keys.empty?
      fail!("#{table} EXPLAIN leading key order differs") unless primary['Keys'] == expected_keys
      initial = Integer(primary.fetch('Initial Granules'))
      selected = Integer(primary.fetch('Selected Granules'))
      fail!("#{table} filtered projection primary key did not prune granules") unless initial > 0 && selected > 0 && selected < initial
      result[:primary_key] = primary
      result
    rescue JSON::ParserError, KeyError, ArgumentError => error
      fail!("#{table} EXPLAIN validation failed: #{error.message}")
    end

    def expected_grouped(target, filters: nil)
      ordered_groups(target, filters: filters).map do |keys, values|
        (keys + target.fetch(:aggregates, AGGREGATES).map { |name| aggregate_value(values, name) }).join("\t") + "\n"
      end.join.b
    end

    def expected_child_rows(target)
      ordered_groups(target).map do |keys, values|
        keys + AGGREGATES.map { |name| aggregate_value(values, name) }
      end
    end

    def expected_child_rowbinary(target)
      ordered_groups(target).map do |keys, values|
        keys.pack('Q<' * keys.size).b + AGGREGATES.map { |name| aggregate_state(values, name) }.join.b
      end.join.b
    end

    def expected_primary_index(target)
      rows = expected_child_rows(target)
      entries = (0...rows.size).step(CHILD_ROWS_PER_MARK).map { |index| rows.fetch(index).take(KEY_NAMES.size) }
      entries << rows.last.take(KEY_NAMES.size)
      entries.map { |row| row.pack('Q<' * row.size) }.join.b
    end

    def ordered_groups(target, filters: nil)
      order = target.fetch(:order)
      groups = GROUPS.map do |canonical_keys, aggregate|
        canonical = KEY_NAMES.zip(canonical_keys).to_h
        [canonical, order.map { |name| canonical.fetch(name) }, aggregate]
      end
      groups.sort_by! { |_canonical, ordered, _aggregate| ordered }
      if filters
        groups.select! do |canonical, _ordered, _aggregate|
          filters.all? { |name, value| canonical.fetch(name) == value }
        end
      end
      groups.map { |_canonical, ordered, aggregate| [ordered, aggregate] }
    end

    def prefix_filter_for(target)
      order = target.fetch(:order)
      groups = ordered_groups(target)
      repeated_prefix = groups.group_by { |keys, _aggregate| keys.take(3) }.values.find { |matches| matches.size > 1 }
      keys = (repeated_prefix || groups).first.fetch(0)
      order.take(3).zip(keys.take(3)).to_h
    end

    def aggregate_value(values, name)
      case name
      when 'count()' then values.fetch(:count)
      when 'sum(value)' then values.fetch(:sum)
      when 'min(value)' then values.fetch(:min)
      when 'max(value)' then values.fetch(:max)
      else fail!("unsupported aggregate #{name}")
      end
    end

    def aggregate_state(values, name)
      value = aggregate_value(values, name)
      case name
      when 'count()' then varuint(value)
      when 'sum(value)' then [value].pack('Q<').b
      when 'min(value)', 'max(value)' then "\x01".b + [value].pack('Q<').b
      else fail!("unsupported state #{name}")
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

    def child_schema(table)
      query("schema_#{table}", "DESCRIBE TABLE mergeTreeProjection('#{DATABASE}','#{table}','#{PROJECTION}') FORMAT TSVRaw;")
        .lines(chomp: true).map { |line| line.split("\t", -1).take(2) }
    end

    def copy_attached_to_catalog!
      TARGETS.each do |target|
        table = target.fetch(:table)
        source = @attached.fetch(table).fetch(:parent_path)
        destination = File.join(uuid_path(target.fetch(:uuid)), target.fetch(:part))
        copy_tree(source, destination)
        fail!("#{table} attached offline copy differs") unless inventory(destination) == @attached.fetch(table).fetch(:inventory)
        @attached.fetch(table)[:catalog_copy] = destination
      end
    end

    def validate_reopen!(report)
      fail!('reopen helper format/action/status differs') unless report.is_a?(Hash) &&
        report['format'] == HELPER_FORMAT && report['action'] == 'reopen' && report['status'] == 'ok'
      pairs = Array(report['pairs']).to_h { |pair| [pair.fetch('table'), pair] }
      expected_names = TARGETS.flat_map { |target| [target.fetch(:control), target.fetch(:table)] }.sort
      fail!('offline reopen table roster differs') unless pairs.keys.sort == expected_names
      TARGETS.each do |target|
        [target.fetch(:control), target.fetch(:table)].each do |table|
          pair = pairs.fetch(table)
          rows = expected_child_rows(target).map { |row| row.map(&:to_s) }
          expected_states = AGGREGATES.to_h do |name|
            [name, ordered_groups(target).map { |_keys, values| aggregate_state(values, name).unpack1('H*') }]
          end
          expected_window_states = expected_states.transform_values { |values| values[1, 5] }
          expected_window_rows = rows[1, 5]
          fail!("#{table} offline full/window state or mark scans differ") unless
            pair['parent_format'] == target.fetch(:parent_format) && pair['child_format'] == target.fetch(:child_format) &&
            pair['child_rows'] == rows && pair['child_state_hex'] == expected_states &&
            pair['child_window_rows'] == expected_window_rows && pair['child_window_state_hex'] == expected_window_states &&
            pair['parent_mark_rows'] == PARENT_MARK_ROWS && pair['child_mark_rows'] == child_mark_rows &&
            pair['window_parent_mark_rows'] == [1, 2, 2] && pair['window_child_mark_rows'] == [1, 2, 2]
          expected_path = table == target.fetch(:control) ?
            File.join(uuid_path(target.fetch(:control_uuid)), SOURCE_PART) : @attached.fetch(table).fetch(:catalog_copy)
          fail!("#{table} offline part path differs") unless pair['path'] == expected_path
        end
      end
      report
    end

    def validate_inputs_unchanged!
      fail!('pinned runtime changed during witness') unless sha_file(@binary) == @binary_sha
      fail!('prebuilt helper changed during witness') unless sha_file(@helper) == @helper_sha
      fail!('run_safe guard changed during witness') unless sha_file(@run_safe) == @guard_sha
      fail!('W298 witness sources changed during run') unless input_hashes == @input_hashes
      fail!('repository HEAD changed during run') unless git_revision == @revision
      fail!('source part changed during witness') unless inventory(@parts.fetch('source').fetch(:path)) == @source_part.fetch(:inventory)
      true
    end

    def assert_attached_files_preserved!(expected, actual, table, attached_path)
      expected_files = expected.fetch(:files).to_h { |entry| [entry.fetch(:relative_path), entry] }
      actual_files = actual.fetch(:files).to_h { |entry| [entry.fetch(:relative_path), entry] }
      fail!("#{table} ATTACH changed/removed generated files") unless expected_files.all? { |name, file| actual_files[name] == file }
      extras = actual_files.keys - expected_files.keys
      fail!("#{table} ATTACH added unexpected sidecars #{extras.inspect}") unless extras == [ATTACH_SIDECAR]
      fail!("#{table} ATTACH sidecar bytes differ") unless File.binread(File.join(attached_path, ATTACH_SIDECAR)) == ATTACH_SIDECAR_BYTES
    end

    def native(label, input)
      args = ['local', '--path', @native_store, '--session_timezone=UTC', '--max_threads=1',
              "--max_memory_usage=#{MEMORY_BYTES}", '--multiquery']
      run_process(label, @binary, args, input, 'ClickHouse local')
    end

    def query(label, sql)
      native(label, (sql.end_with?("\n") ? sql : sql + "\n").b)
    end

    def helper(action)
      output = run_process("helper_#{action}", @helper, [@catalog_root, action], ''.b, 'prebuilt Crystal helper')
      fail!("helper #{action} must emit one JSON line") unless output.lines.size == 1
      JSON.parse(output)
    rescue JSON::ParserError => error
      fail!("helper #{action} emitted invalid JSON: #{error.message}")
    end

    def run_process(label, executable, args, input, kind)
      cell_name = format('%03d_%s', @processes.size + 1, label.gsub(/[^a-zA-Z0-9_-]/, '_'))
      cell = File.join(@root, 'processes', cell_name)
      Dir.mkdir(cell, 0o700)
      argv = [@run_safe, executable, PROCESS_TIMEOUT_SECONDS.to_s, PROCESS_MEMORY_MIB.to_s, *args]
      env = {
        'RUN_SAFE_PASSTHROUGH_STDIO' => '1', 'COGNI_RUN_SAFE_MIN_FREE_PCT' => '40',
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
      record = {label: label, argv: argv, argv_sha256: Digest::SHA256.hexdigest(JSON.generate(argv)), kind: kind,
                run_safe_sha256: @guard_sha, timeout_seconds: PROCESS_TIMEOUT_SECONDS,
                process_tree_memory_limit_bytes: PROCESS_MEMORY_MIB * 1024 * 1024,
                input_bytes: input.bytesize, input_sha256: Digest::SHA256.hexdigest(input),
                duration_seconds: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3),
                exitstatus: status.exitstatus, termsig: status.termsig, stdout_bytes: stdout.bytesize,
                stdout_sha256: Digest::SHA256.hexdigest(stdout), stderr_bytes: stderr.bytesize,
                stderr_sha256: Digest::SHA256.hexdigest(stderr)}
      write_new(File.join(cell, 'process.json'), JSON.pretty_generate(record) + "\n")
      @processes << record
      fail!("#{label}: exit=#{status.exitstatus} signal=#{status.termsig}: #{stderr}") unless status.success? && status.termsig.nil?
      stdout
    rescue Errno::ENOENT => error
      fail!("#{label} spawn failed: #{error.class}: #{error.message}")
    end

    def store_path!(path)
      full = File.expand_path(path)
      real = File.realpath(full)
      fail!('native path escaped isolated store') unless real.start_with?(File.realpath(@native_store) + File::SEPARATOR)
      fail!('native path is symlinked or noncanonical') unless full == real && !File.symlink?(full)
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
      root = File.realpath(path)
      files = []
      bytes = 0
      Find.find(root) do |entry|
        stat = File.lstat(entry)
        fail!("part contains symlink or special file: #{entry}") if stat.symlink? || !(stat.file? || stat.directory?)
        next if stat.directory?
        bytes += stat.size
        files << {relative_path: entry.delete_prefix(root + File::SEPARATOR), bytes: stat.size, sha256: sha_file(entry)}
        fail!('part file count exceeds 256') if files.size > MAX_PART_FILES
        fail!('part bytes exceed bound') if bytes > MAX_PART_BYTES
      end
      {files: files.sort_by { |entry| entry.fetch(:relative_path) }, total_bytes: bytes}
    end

    def assert_format!(path, format, label, compressed:)
      names = Dir.children(path)
      wide = names.grep(/\.(?:c?mrk2)\z/)
      compact = names.grep(/\.(?:c?mrk4)\z/)
      actual = if !wide.empty? && compact.empty? then 'Wide' elsif !compact.empty? && wide.empty? then 'Compact' else 'ambiguous' end
      fail!("#{label} marker family is #{actual}, expected #{format}") unless actual == format
      marks = format == 'Wide' ? wide : compact
      fail!("#{label} compressed mark choice differs") unless !marks.empty? && marks.all? { |name| name.include?('.cmrk') } == compressed
      fail!("#{label} primary.idx missing or compressed") unless File.file?(File.join(path, 'primary.idx')) && !File.exist?(File.join(path, 'primary.cidx'))
    end

    def generated_child_marks_compressed?(target)
      target.fetch(:child_format) == 'Compact' && target.fetch(:parent_format) == 'Compact'
    end

    def stock_control_marks_compressed?(target)
      target.fetch(:child_format) == 'Compact' && target.fetch(:parent_format) == 'Compact'
    end

    def copy_tree(source, destination)
      fail!("copy destination exists: #{destination}") if File.exist?(destination) || File.symlink?(destination)
      Find.find(source) do |entry|
        stat = File.lstat(entry)
        fail!("part contains symlink or special file: #{entry}") if stat.symlink? || !(stat.file? || stat.directory?)
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

    def child_mark_rows
      Array.new((GROUPS.size + CHILD_ROWS_PER_MARK - 1) / CHILD_ROWS_PER_MARK) do |index|
        [GROUPS.size - index * CHILD_ROWS_PER_MARK, CHILD_ROWS_PER_MARK].min
      end
    end

    def child_system_marks
      child_mark_rows.size + 1
    end

    def stock_control_summary
      @stock.to_h do |table, entry|
        summary = entry.reject { |key, _value| key == :primary_index || key == :child_rowbinary }
        summary[:primary_index_hex] = entry.fetch(:primary_index).unpack1('H*')
        summary[:child_rowbinary_hex] = entry.fetch(:child_rowbinary).unpack1('H*')
        summary[:child_rowbinary_sha256] = Digest::SHA256.hexdigest(entry.fetch(:child_rowbinary))
        [table, summary]
      end
    end

    def assert_bytes!(actual, expected, label)
      fail!("#{label}: byte mismatch (expected #{expected.unpack1('H*')}, saw #{actual.unpack1('H*')})") unless actual == expected
    end

    def walk_json(value, &block)
      yield value
      case value
      when Hash then value.each_value { |item| walk_json(item, &block) }
      when Array then value.each { |item| walk_json(item, &block) }
      when String
        parsed = JSON.parse(value) rescue nil
        walk_json(parsed, &block) if parsed.is_a?(Hash) || parsed.is_a?(Array)
      end
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
      payload = {format: FORMAT, repository_head: @revision, fatal_error: @fatal_error}.merge(values)
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
      args.banner = 'Usage: ruby scripts/verify_materialized_view_aggregate_projection_w298.rb --evidence-root PATH --helper PREBUILT --run-safe PATH [--binary PATH]'
      args.on('--evidence-root PATH', 'Fresh directory below an existing non-system-volume parent') { |value| options[:evidence_root] = value }
      args.on('--helper PATH', 'Prebuilt executable W298 Crystal helper') { |value| options[:helper] = value }
      args.on('--run-safe PATH', 'Pinned process resource guard') { |value| options[:run_safe] = value }
      args.on('--binary PATH', 'Pinned stock ClickHouse executable') { |value| options[:binary] = value }
    end
    parser.parse!(argv)
    Driver.new(options).run ? 0 : 1
  rescue OptionParser::ParseError => error
    warn error.message
    2
  end
end

exit VerifyMaterializedViewAggregateProjectionW298.run
