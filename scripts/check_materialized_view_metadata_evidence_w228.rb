#!/usr/bin/env ruby
# Independent audit of W228 raw ClickHouse metadata and helper observations.

require 'digest'
require 'find'
require 'json'
require 'open3'
require 'optparse'
require_relative 'recheck_aggregate_recursive_w224'

module CheckMaterializedViewMetadataEvidenceW228
  extend self

  R = RecheckAggregateRecursiveW224
  VERSION = R::VERSION.freeze
  BUILD_HASH = R::BUILD_HASH.freeze
  RUNTIME_SHA256 = R::RUNTIME_SHA256.freeze
  SOURCE_ROOT = R::SOURCE_ROOT.freeze
  SOURCE_REVISION = R::SOURCE_REVISION.freeze
  NATIVE_PREFIX = '/private/tmp/crystal-click-w228-native.'.freeze
  EVIDENCE_PREFIX = '/private/tmp/crystal-click-w228-evidence.'.freeze
  FORMAT_INPUT = 'materialized_view_metadata_w228_input_v1'.freeze
  FORMAT_HELPER = 'materialized_view_metadata_w228_helper_v1'.freeze
  FORMAT_SUMMARY = 'materialized_view_metadata_w228_summary_v1'.freeze
  FORMAT_OBSERVATIONS = 'materialized_view_metadata_w228_stock_observations_v1'.freeze
  MAIN_DB = 'w228_main'.freeze
  SOURCE_DB = 'w228_source'.freeze
  TARGET_DB = 'w228_target'.freeze
  DATABASES = [MAIN_DB, SOURCE_DB, TARGET_DB].freeze
  INNER_UUID = 'a2280000-0000-4000-8000-000000000001'.freeze
  TARGET_UUID = 'a2280000-0000-4000-8000-000000000002'.freeze
  VIEW_IDS = %w[
    named_unqualified
    cross_database_target
    cross_database_source
    source_free_named_target
    cte_unknown
    inner_uuid_explicit
    engine_canonical_inner_uuid
    join_unknown
    subquery_unknown
    literal_fake_from_to
    quoted_identifiers
  ].freeze
  CONTROL_IDS = %w[refresh_control security_control].freeze
  CONTROL_CASES = {
    'refresh_control' => { 'database' => MAIN_DB, 'name' => 'mv_refresh' },
    'security_control' => { 'database' => MAIN_DB, 'name' => 'mv_security' },
  }.freeze
  NEGATIVE_IDS = %w[ordinary_table missing_view].freeze
  VIEW_CASES = {
    'named_unqualified' => {
      'database' => MAIN_DB, 'name' => 'mv_unqualified', 'target_kind' => 'named',
      'target' => { 'database' => MAIN_DB, 'name' => 'dst', 'database_qualified' => true, 'uuid' => nil },
      'target_sql' => "TO #{MAIN_DB}.dst", 'inner_engine' => nil,
      'sources' => [{ 'database' => MAIN_DB, 'name' => 'src', 'database_qualified' => true }], 'complete' => true, 'status' => 'complete',
      'create_sql' => "USE #{MAIN_DB}; CREATE MATERIALIZED VIEW mv_unqualified TO dst AS SELECT k, v FROM src;",
    },
    'cross_database_target' => {
      'database' => MAIN_DB, 'name' => 'mv_cross_target', 'target_kind' => 'named',
      'target' => { 'database' => TARGET_DB, 'name' => 'dst', 'database_qualified' => true, 'uuid' => nil },
      'target_sql' => "TO #{TARGET_DB}.dst", 'inner_engine' => nil,
      'sources' => [{ 'database' => MAIN_DB, 'name' => 'src', 'database_qualified' => true }], 'complete' => true, 'status' => 'complete',
      'authored_target_uuid' => TARGET_UUID,
      'create_sql' => "CREATE MATERIALIZED VIEW #{MAIN_DB}.mv_cross_target TO #{TARGET_DB}.dst UUID '#{TARGET_UUID}' AS SELECT k, v FROM #{MAIN_DB}.src;",
    },
    'cross_database_source' => {
      'database' => MAIN_DB, 'name' => 'mv_cross_source', 'target_kind' => 'named',
      'target' => { 'database' => MAIN_DB, 'name' => 'dst', 'database_qualified' => true, 'uuid' => nil },
      'target_sql' => "TO #{MAIN_DB}.dst", 'inner_engine' => nil,
      'sources' => [{ 'database' => SOURCE_DB, 'name' => 'src', 'database_qualified' => true }], 'complete' => true, 'status' => 'complete',
      'create_sql' => "CREATE MATERIALIZED VIEW #{MAIN_DB}.mv_cross_source TO #{MAIN_DB}.dst AS SELECT k, v FROM #{SOURCE_DB}.src;",
    },
    'source_free_named_target' => {
      'database' => MAIN_DB, 'name' => 'mv_source_free', 'target_kind' => 'named',
      'target' => { 'database' => MAIN_DB, 'name' => 'dst', 'database_qualified' => true, 'uuid' => nil },
      'target_sql' => "TO #{MAIN_DB}.dst", 'inner_engine' => nil,
      'sources' => [], 'complete' => true, 'status' => 'complete',
      'create_sql' => "CREATE MATERIALIZED VIEW #{MAIN_DB}.mv_source_free TO #{MAIN_DB}.dst AS SELECT toUInt64(0) AS k, 'constant' AS v;",
    },
    'cte_unknown' => {
      'database' => MAIN_DB, 'name' => 'mv_cte_unknown', 'target_kind' => 'named',
      'target' => { 'database' => MAIN_DB, 'name' => 'dst', 'database_qualified' => true, 'uuid' => nil },
      'target_sql' => "TO #{MAIN_DB}.dst", 'inner_engine' => nil,
      'sources' => [], 'complete' => false, 'status' => 'unknown',
      'create_sql' => "CREATE MATERIALIZED VIEW #{MAIN_DB}.mv_cte_unknown TO #{MAIN_DB}.dst AS WITH source_cte AS (SELECT k, v FROM #{MAIN_DB}.src) SELECT k, v FROM source_cte;",
    },
    'inner_uuid_explicit' => {
      'database' => MAIN_DB, 'name' => 'mv_inner_uuid', 'target_kind' => 'inner_uuid',
      'target' => { 'database' => nil, 'name' => nil, 'database_qualified' => nil, 'uuid' => INNER_UUID },
      'target_sql' => "TO INNER UUID '#{INNER_UUID}'", 'inner_engine' => 'MergeTree',
      'sources' => [{ 'database' => MAIN_DB, 'name' => 'src', 'database_qualified' => true }], 'complete' => true, 'status' => 'complete',
      'create_sql' => "CREATE MATERIALIZED VIEW #{MAIN_DB}.mv_inner_uuid TO INNER UUID '#{INNER_UUID}' (k UInt64, v String) ENGINE = MergeTree ORDER BY k AS SELECT k, v FROM #{MAIN_DB}.src;",
    },
    'engine_canonical_inner_uuid' => {
      'database' => MAIN_DB, 'name' => 'mv_engine_inner', 'target_kind' => 'inner_uuid',
      'target' => { 'database' => nil, 'name' => nil, 'database_qualified' => nil, 'uuid' => :physical_inner_uuid },
      'target_sql' => nil, 'inner_engine' => 'MergeTree',
      'sources' => [{ 'database' => MAIN_DB, 'name' => 'src', 'database_qualified' => true }], 'complete' => true, 'status' => 'complete',
      'create_sql' => "CREATE MATERIALIZED VIEW #{MAIN_DB}.mv_engine_inner ENGINE = MergeTree ORDER BY k AS SELECT k, v FROM #{MAIN_DB}.src;",
    },
    'join_unknown' => {
      'database' => MAIN_DB, 'name' => 'mv_join_unknown', 'target_kind' => 'named',
      'target' => { 'database' => MAIN_DB, 'name' => 'dst', 'database_qualified' => true, 'uuid' => nil },
      'target_sql' => "TO #{MAIN_DB}.dst", 'inner_engine' => nil, 'sources' => [], 'complete' => false, 'status' => 'unknown',
      'create_sql' => "CREATE MATERIALIZED VIEW #{MAIN_DB}.mv_join_unknown TO #{MAIN_DB}.dst AS SELECT s.k, s.v FROM #{MAIN_DB}.src AS s INNER JOIN #{MAIN_DB}.src AS other ON s.k = other.k;",
    },
    'subquery_unknown' => {
      'database' => MAIN_DB, 'name' => 'mv_subquery_unknown', 'target_kind' => 'named',
      'target' => { 'database' => MAIN_DB, 'name' => 'dst', 'database_qualified' => true, 'uuid' => nil },
      'target_sql' => "TO #{MAIN_DB}.dst", 'inner_engine' => nil, 'sources' => [], 'complete' => false, 'status' => 'unknown',
      'create_sql' => "CREATE MATERIALIZED VIEW #{MAIN_DB}.mv_subquery_unknown TO #{MAIN_DB}.dst AS SELECT k, v FROM (SELECT k, v FROM #{MAIN_DB}.src);",
    },
    'literal_fake_from_to' => {
      'database' => MAIN_DB, 'name' => 'mv_literal_fake', 'target_kind' => 'named',
      'target' => { 'database' => MAIN_DB, 'name' => 'dst', 'database_qualified' => true, 'uuid' => nil },
      'target_sql' => "TO #{MAIN_DB}.dst", 'inner_engine' => nil,
      'sources' => [{ 'database' => MAIN_DB, 'name' => 'src', 'database_qualified' => true }], 'complete' => true, 'status' => 'complete',
      'create_sql' => "CREATE MATERIALIZED VIEW #{MAIN_DB}.mv_literal_fake TO #{MAIN_DB}.dst AS SELECT k, 'TO fake FROM fake' AS v FROM #{MAIN_DB}.src;",
    },
    'quoted_identifiers' => {
      'database' => MAIN_DB, 'name' => 'mv_quoted', 'target_kind' => 'named',
      'target' => { 'database' => MAIN_DB, 'name' => 'dst.dot', 'database_qualified' => true, 'uuid' => nil },
      'target_sql' => "TO #{MAIN_DB}.`dst.dot`", 'inner_engine' => nil,
      'sources' => [{ 'database' => MAIN_DB, 'name' => 'src.dot', 'database_qualified' => true }], 'complete' => true, 'status' => 'complete',
      'create_sql' => "CREATE MATERIALIZED VIEW #{MAIN_DB}.mv_quoted TO \"#{MAIN_DB}\".\"dst.dot\" AS SELECT k, v FROM \"#{MAIN_DB}\".\"src.dot\";",
    },
  }.freeze
  CONTROL_CREATE_SQL = {
    'refresh_control' => "CREATE MATERIALIZED VIEW #{MAIN_DB}.mv_refresh REFRESH EVERY 1 MINUTE ENGINE = MergeTree ORDER BY k AS SELECT k, v FROM #{MAIN_DB}.src;",
    'security_control' => "CREATE MATERIALIZED VIEW #{MAIN_DB}.mv_security TO #{MAIN_DB}.dst DEFINER = CURRENT_USER SQL SECURITY DEFINER AS SELECT k, v FROM #{MAIN_DB}.src;",
  }.freeze
  TABLE_FUNCTION_SQL = "CREATE MATERIALIZED VIEW #{MAIN_DB}.mv_table_function TO #{MAIN_DB}.dst AS SELECT number AS k, toString(number) AS v FROM numbers(1);".freeze
  SYSTEM_DATABASES_SQL = "SELECT name, toString(uuid) FROM system.databases WHERE name IN ('#{MAIN_DB}', '#{SOURCE_DB}', '#{TARGET_DB}') ORDER BY name FORMAT TSVRaw".freeze
  SYSTEM_TABLES_SQL = "SELECT database, name, toString(uuid), engine FROM system.tables WHERE database IN ('#{MAIN_DB}', '#{SOURCE_DB}', '#{TARGET_DB}') ORDER BY database, name FORMAT TSVRaw".freeze

  def fail!(message)
    raise ArgumentError, message
  end

  def require_true(condition, message)
    fail!(message) unless condition
  end

  def canonical_root(path, prefix, label)
    full = File.expand_path(path)
    require_true(File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full,
      "#{label} is absent, symlinked, or noncanonical")
    require_true(File.dirname(full) == File.realpath('/private/tmp') && full.start_with?(prefix),
      "#{label} is outside the fixed direct /private/tmp prefix")
    full
  end

  def read_file(path, root = nil)
    full = File.expand_path(path)
    require_true(File.file?(full) && !File.symlink?(full) && File.realpath(full) == full,
      "missing, symlinked, or noncanonical file: #{full}")
    require_true(full.start_with?(File.realpath(root) + File::SEPARATOR), "file escaped evidence root: #{full}") if root
    File.binread(full)
  end

  def json_file(path, root = nil)
    JSON.parse(read_file(path, root).force_encoding(Encoding::UTF_8))
  rescue JSON::ParserError => error
    fail!("invalid JSON evidence #{path}: #{error.message}")
  end

  def encode_filename(name)
    name.b.bytes.map do |byte|
      char = byte.chr
      /\A[A-Za-z0-9_]\z/.match?(char) ? char : format('%%%02X', byte)
    end.join
  end

  def extract_query(ddl, label)
    marker = /\nAS[ \t]+(?:SELECT|WITH)\b/i.match(ddl)
    require_true(marker, "#{label}: no top-level ATTACH AS SELECT/WITH boundary")
    query = ddl[marker.begin(0) + 1..-1].sub(/\AAS[ \t]*/i, '').strip
    require_true(query.match?(/\A(?:SELECT|WITH)\b/i), "#{label}: persisted query does not start with SELECT or WITH")
    query
  end

  def expected_labels
    labels = %w[runtime-version-pin runtime-build-pin stock-bootstrap]
    labels.concat(VIEW_IDS.map { |id| "stock-create-#{id}" })
    labels.concat(CONTROL_IDS.map { |id| "stock-create-#{id}" })
    labels.concat(%w[stock-table-function-refusal stock-system-databases stock-system-tables crystal-helper])
    labels
  end

  def database_rows(stdout)
    stdout.lines.map do |line|
      fields = line.chomp.split("\t", -1)
      require_true(fields.length == 2, "malformed system.databases row #{line.inspect}")
      { 'name' => fields[0], 'uuid' => fields[1] }
    end
  end

  def table_rows(stdout)
    stdout.lines.map do |line|
      fields = line.chomp.split("\t", -1)
      require_true(fields.length == 4, "malformed system.tables row #{line.inspect}")
      { 'database' => fields[0], 'name' => fields[1], 'uuid' => fields[2], 'engine' => fields[3] }
    end
  end

  def table_row(tables, database, name)
    tables.find { |row| row.fetch('database') == database && row.fetch('name') == name } || fail!("system.tables lacks #{database}.#{name}")
  end

  def database_row(databases, name)
    databases.find { |row| row.fetch('name') == name } || fail!("system.databases lacks #{name}")
  end

  def metadata_record(observations, database, basename)
    observations.fetch('metadata_files').find do |row|
      row.fetch('database') == database && row.fetch('basename') == basename
    end || fail!("metadata manifest lacks #{database}/#{basename}")
  end

  def profile_source_refs(case_item)
    case_item.fetch('sources').map do |reference|
      { 'database' => reference.fetch('database'), 'name' => reference.fetch('name'),
        'database_qualified' => reference.fetch('database_qualified') }
    end
  end

  def audit_invocations(root, native_root, summary, input_path)
    directory = File.join(root, 'invocations')
    require_true(File.directory?(directory) && !File.symlink?(directory), 'missing invocation evidence directory')
    files = Dir.children(directory).sort
    require_true(files.length == expected_labels.length * 5, 'invocation evidence file count differs')
    by_label = {}
    files.select { |name| name.end_with?('.argv.json') }.each do |argv_name|
      base = File.join(directory, argv_name.sub(/\.argv\.json\z/, ''))
      argv_record = json_file(base + '.argv.json', root)
      label = argv_record.fetch('label')
      require_true(!by_label.key?(label), "duplicate invocation label #{label}")
      status = json_file(base + '.status.json', root)
      stdout = read_file(base + '.stdout', root)
      stderr = read_file(base + '.stderr', root)
      sql = read_file(base + '.sql', root)
      require_true(status.fetch('label') == label, "#{label}: status label mismatch")
      require_true(status.fetch('stdout_bytes') == stdout.bytesize && status.fetch('stderr_bytes') == stderr.bytesize,
        "#{label}: raw stream byte counts differ")
      require_true(argv_record.fetch('environment') == { 'TZ' => 'UTC' }, "#{label}: process environment differs")
      require_true(argv_record.fetch('timeout_seconds').is_a?(Numeric) && argv_record.fetch('timeout_seconds') > 0 &&
        argv_record.fetch('timeout_seconds') <= R::HELPER_TIMEOUT_SECONDS, "#{label}: timeout bound differs")
      require_true(!status.fetch('timed_out') && status.fetch('spawn_error').nil?, "#{label}: process timed out or failed to spawn")
      expected_success = label != 'stock-table-function-refusal'
      if expected_success
        require_true(status.fetch('classification') == 'process_success' && status.fetch('exitstatus') == 0 &&
          !status.fetch('signaled'), "#{label}: nonzero process cannot establish metadata evidence")
      else
        require_true(status.fetch('classification') == 'process_nonzero_or_signaled_exit' && status.fetch('exitstatus') != 0,
          'table-function probe did not remain a raw process refusal')
        require_true(stderr.include?('QUERY_IS_NOT_SUPPORTED_IN_MATERIALIZED_VIEW'), 'table-function refusal diagnostic differs')
      end
      argv = argv_record.fetch('argv')
      if label == 'crystal-helper'
        require_true(argv.length == 2 && argv[1] == input_path, 'helper argv differs from input path')
        helper_path = argv.fetch(0)
        require_true(File.file?(helper_path) && File.executable?(helper_path) && !File.symlink?(helper_path) && File.realpath(helper_path) == helper_path,
          'helper executable is missing or noncanonical')
        helper_hash = Digest::SHA256.file(helper_path).hexdigest
        require_true(helper_hash == summary.fetch('helper_sha256_expected'), 'current helper binary differs from recorded pin')
        require_true(summary.fetch('helper_sha256_expected') == summary.fetch('helper_sha256_at_start') &&
          summary.fetch('helper_sha256_expected') == summary.fetch('helper_sha256_after_execute'), 'helper binary pin changed during capture')
        require_true(sql == "\n", 'helper invocation SQL carrier differs')
      else
        binary = argv.fetch(0)
        require_true(File.file?(binary) && File.executable?(binary) && !File.symlink?(binary) && File.realpath(binary) == binary,
          "#{label}: ClickHouse executable is missing or noncanonical")
        require_true(Digest::SHA256.file(binary).hexdigest == RUNTIME_SHA256, "#{label}: ClickHouse executable differs from pinned SHA")
        require_true(argv[1, 3] == ['local', '--path', File.join(native_root, 'stores', 'catalog')], "#{label}: ClickHouse store argv differs")
        require_true(argv[-2] == '--query', "#{label}: ClickHouse query argv is absent")
        require_true(sql == argv[-1] + (argv[-1].end_with?("\n") ? '' : "\n"), "#{label}: raw SQL carrier differs from argv")
        expected_sql = expected_sql_for(label)
        require_true(argv[-1] == expected_sql, "#{label}: argv SQL differs from the fixed fixture")
      end
      by_label[label] = { 'status' => status, 'stdout' => stdout, 'stderr' => stderr, 'sql' => sql, 'argv' => argv }
    end
    require_true(by_label.keys.sort == expected_labels.sort, 'invocation labels differ from exact W228 roster')
    require_true(summary.fetch('counts').fetch('processes') == expected_labels.length, 'summary process count differs from raw invocation roster')
    expected_status_counts = {
      'success_exit0' => expected_labels.length - 1,
      'nonzero_or_signaled' => 1,
      'timeout' => 0,
      'spawn_failure' => 0,
    }
    require_true(summary.fetch('process_status_counts') == expected_status_counts, 'summary process status totals differ from raw process records')
    actual_status_counts = {
      'success_exit0' => by_label.values.count { |item| item.fetch('status').fetch('classification') == 'process_success' },
      'nonzero_or_signaled' => by_label.values.count { |item| item.fetch('status').fetch('classification') == 'process_nonzero_or_signaled_exit' },
      'timeout' => by_label.values.count { |item| item.fetch('status').fetch('classification') == 'process_timeout' },
      'spawn_failure' => by_label.values.count { |item| item.fetch('status').fetch('classification') == 'spawn_failure' },
    }
    require_true(actual_status_counts == expected_status_counts, 'raw process status totals differ from exact expected matrix')
    by_label
  end

  def expected_sql_for(label)
    case label
    when 'runtime-version-pin'
      'SELECT version() FORMAT TSVRaw'
    when 'runtime-build-pin'
      "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw"
    when 'stock-bootstrap'
      return <<~SQL
        CREATE DATABASE #{MAIN_DB} ENGINE = Atomic;
        CREATE DATABASE #{SOURCE_DB} ENGINE = Atomic;
        CREATE DATABASE #{TARGET_DB} ENGINE = Atomic;
        CREATE TABLE #{MAIN_DB}.src (k UInt64, v String) ENGINE = MergeTree ORDER BY k;
        CREATE TABLE #{MAIN_DB}.dst (k UInt64, v String) ENGINE = MergeTree ORDER BY k;
        CREATE TABLE #{MAIN_DB}.`src.dot` (k UInt64, v String) ENGINE = MergeTree ORDER BY k;
        CREATE TABLE #{MAIN_DB}.`dst.dot` (k UInt64, v String) ENGINE = MergeTree ORDER BY k;
        CREATE TABLE #{SOURCE_DB}.src (k UInt64, v String) ENGINE = MergeTree ORDER BY k;
        CREATE TABLE #{TARGET_DB}.dst UUID '#{TARGET_UUID}' (k UInt64, v String) ENGINE = MergeTree ORDER BY k;
        CREATE TABLE #{MAIN_DB}.projection_source
        (
            k UInt64,
            v String,
            PROJECTION by_v (SELECT v, k ORDER BY v)
        ) ENGINE = MergeTree ORDER BY k;
      SQL
    when 'stock-create-named_unqualified'
      VIEW_CASES.fetch('named_unqualified').fetch('create_sql')
    when 'stock-create-cross_database_target'
      VIEW_CASES.fetch('cross_database_target').fetch('create_sql')
    when 'stock-create-cross_database_source'
      VIEW_CASES.fetch('cross_database_source').fetch('create_sql')
    when 'stock-create-source_free_named_target'
      VIEW_CASES.fetch('source_free_named_target').fetch('create_sql')
    when 'stock-create-cte_unknown'
      VIEW_CASES.fetch('cte_unknown').fetch('create_sql')
    when 'stock-create-inner_uuid_explicit'
      VIEW_CASES.fetch('inner_uuid_explicit').fetch('create_sql')
    when 'stock-create-engine_canonical_inner_uuid'
      VIEW_CASES.fetch('engine_canonical_inner_uuid').fetch('create_sql')
    when 'stock-create-join_unknown'
      VIEW_CASES.fetch('join_unknown').fetch('create_sql')
    when 'stock-create-subquery_unknown'
      VIEW_CASES.fetch('subquery_unknown').fetch('create_sql')
    when 'stock-create-literal_fake_from_to'
      VIEW_CASES.fetch('literal_fake_from_to').fetch('create_sql')
    when 'stock-create-quoted_identifiers'
      VIEW_CASES.fetch('quoted_identifiers').fetch('create_sql')
    when 'stock-create-refresh_control'
      CONTROL_CREATE_SQL.fetch('refresh_control')
    when 'stock-create-security_control'
      CONTROL_CREATE_SQL.fetch('security_control')
    when 'stock-table-function-refusal'
      TABLE_FUNCTION_SQL
    when 'stock-system-databases'
      SYSTEM_DATABASES_SQL
    when 'stock-system-tables'
      SYSTEM_TABLES_SQL
    else
      fail!("unlisted W228 process label #{label.inspect}")
    end
  end

  def verify_metadata_inventory!(native_root, observations, databases, tables)
    store = File.join(native_root, 'stores', 'catalog')
    captured = observations.fetch('metadata_files')
    expected_entries = []
    DATABASES.each do |database|
      db_uuid = database_row(databases, database).fetch('uuid')
      db_dir = File.join(store, 'store', db_uuid[0, 3], db_uuid)
      require_true(File.directory?(db_dir) && !File.symlink?(db_dir) && File.realpath(db_dir) == db_dir,
        "noncanonical Atomic metadata directory for #{database}")
      Dir.children(db_dir).sort.each do |basename|
        next unless basename.end_with?('.sql')
        path = File.join(db_dir, basename)
        bytes = read_file(path, native_root)
        expected_entries << { 'database' => database, 'basename' => basename, 'path' => path,
          'byte_count' => bytes.bytesize, 'sha256' => Digest::SHA256.hexdigest(bytes),
          'ddl' => bytes.force_encoding(Encoding::UTF_8) }
      end
      database_path = File.join(store, 'metadata', "#{database}.sql")
      bytes = read_file(database_path, native_root)
      expected_entries << { 'database' => database, 'basename' => "#{database}.sql", 'path' => database_path,
        'byte_count' => bytes.bytesize, 'sha256' => Digest::SHA256.hexdigest(bytes),
        'ddl' => bytes.force_encoding(Encoding::UTF_8) }
    end
    expected_entries.sort_by! { |item| [item.fetch('database'), item.fetch('basename')] }
    actual_entries = captured.sort_by { |item| [item.fetch('database'), item.fetch('basename')] }
    require_true(actual_entries == expected_entries, 'raw Atomic metadata inventory differs from recorded capture')

    expected_table_paths = tables.map { |row| [row.fetch('database'), "#{encode_filename(row.fetch('name'))}.sql"] }.sort
    actual_table_paths = expected_entries.reject do |item|
      DATABASES.any? { |database| item.fetch('database') == database && item.fetch('basename') == "#{database}.sql" }
    end.map { |item| [item.fetch('database'), item.fetch('basename')] }.sort
    require_true(actual_table_paths == expected_table_paths, 'system.tables roster and persisted metadata filenames differ')
  end

  def verify_stock_roster!(databases, tables)
    require_true(databases.map { |row| row.fetch('name') }.sort == DATABASES.sort, 'captured database roster differs')
    main_names = tables.select { |row| row.fetch('database') == MAIN_DB }.map { |row| row.fetch('name') }
    expected_base = %w[src dst src.dot dst.dot projection_source mv_unqualified mv_cross_target mv_cross_source
      mv_source_free mv_cte_unknown mv_inner_uuid mv_engine_inner mv_join_unknown mv_subquery_unknown mv_literal_fake mv_quoted mv_refresh mv_security]
    require_true(main_names.count { |name| name.start_with?('.inner_id.') } == 3, 'unexpected physical implicit/explicit inner-table count')
    view_ids = %w[mv_inner_uuid mv_engine_inner mv_refresh]
    expected_hidden = view_ids.map do |name|
      view = table_row(tables, MAIN_DB, name)
      ".inner_id.#{view.fetch('uuid')}"
    end.sort
    actual_hidden = main_names.select { |name| name.start_with?('.inner_id.') }.sort
    require_true(actual_hidden == expected_hidden, 'hidden target names do not derive exactly from their view UUIDs')
    expected_pairs = (expected_base + expected_hidden).map { |name| [MAIN_DB, name] }
    expected_pairs.concat([[SOURCE_DB, 'src'], [TARGET_DB, 'dst']])
    actual_pairs = tables.map { |row| [row.fetch('database'), row.fetch('name')] }
    require_true(actual_pairs.sort == expected_pairs.sort, 'system.tables database/table roster differs from the exact fixture')
    require_true(table_row(tables, TARGET_DB, 'dst').fetch('uuid') == TARGET_UUID, 'fixed UUID target table differs')
    require_true(table_row(tables, MAIN_DB, 'mv_inner_uuid').fetch('uuid') != INNER_UUID, 'MV UUID unexpectedly equals explicit inner UUID')
  end

  def audit_profiles!(helper, observations, tables)
    require_true(helper.fetch('format') == FORMAT_HELPER, 'helper format differs')
    required_databases = DATABASES
    names = helper.fetch('database_names')
    required_databases.each { |name| require_true(names.include?(name), "offline catalog omitted database #{name}") }
    profiles = helper.fetch('views')
    require_true(profiles.map { |item| item.fetch('id') } == VIEW_IDS, 'helper profile roster/order differs')
    profiles.each do |profile|
      id = profile.fetch('id')
      expected = VIEW_CASES.fetch(id)
      descriptor = profile.fetch('descriptor')
      table = table_row(tables, expected.fetch('database'), expected.fetch('name'))
      metadata = metadata_record(observations, expected.fetch('database'), "#{encode_filename(expected.fetch('name'))}.sql")
      require_true(profile.fetch('database') == expected.fetch('database') && profile.fetch('name') == expected.fetch('name'), "#{id}: helper table identity differs")
      require_true(profile.fetch('kind') == 'materialized_view' && profile.fetch('engine') == 'MaterializedView', "#{id}: kind/engine differs")
      require_true(profile.fetch('uuid') == table.fetch('uuid'), "#{id}: view UUID differs from system.tables")
      require_true(profile.fetch('metadata_ddl') == metadata.fetch('ddl') && profile.fetch('metadata_sha256') == metadata.fetch('sha256'), "#{id}: helper did not report exact persisted DDL bytes")
      require_true(descriptor.fetch('declaring_database') == expected.fetch('database'), "#{id}: declaring database differs")
      require_true(descriptor.fetch('query') == extract_query(metadata.fetch('ddl'), id), "#{id}: query differs from persisted ATTACH query")
      require_true(descriptor.fetch('inner_engine') == expected.fetch('inner_engine'), "#{id}: inner engine differs")

      header = metadata.fetch('ddl').lines.first || ''
      target = descriptor.fetch('target')
      require_true(target.fetch('kind') == expected.fetch('target_kind'), "#{id}: target kind differs")
      expected_target_sql = nil
      if expected.fetch('target_kind') == 'named'
        ref = expected.fetch('target')
        require_true(target.fetch('reference') == { 'database' => ref.fetch('database'), 'name' => ref.fetch('name'),
          'database_qualified' => ref.fetch('database_qualified') }, "#{id}: target reference differs from fixed map")
        require_true(target.fetch('uuid').nil?, "#{id}: named target has unexpected UUID")
        resolved_table = table_row(tables, ref.fetch('database'), ref.fetch('name'))
        if expected.key?('authored_target_uuid')
          require_true(resolved_table.fetch('uuid') == expected.fetch('authored_target_uuid'), "#{id}: authored target UUID differs from its physical table")
        end
        expected_target_sql = expected.fetch('target_sql')
      elsif expected.fetch('target_kind') == 'inner_uuid'
        resolved_table = table_row(tables, expected.fetch('database'), ".inner_id.#{table.fetch('uuid')}")
        target_uuid = expected.fetch('target').fetch('uuid') == :physical_inner_uuid ? resolved_table.fetch('uuid') : expected.fetch('target').fetch('uuid')
        require_true(target.fetch('reference').nil? && target.fetch('uuid') == target_uuid, "#{id}: persisted inner UUID target differs")
        require_true(resolved_table.fetch('uuid') == target_uuid, "#{id}: inner UUID did not bind to the exact physical row")
        expected_target_sql = "TO INNER UUID '#{target_uuid}'"
      end
      expected_header = "ATTACH MATERIALIZED VIEW _ UUID '#{table.fetch('uuid')}' #{expected_target_sql}\n"
      require_true(header == expected_header, "#{id}: persisted ATTACH header differs from the canonical target (including optional UUID normalization)")

      expected_sources = profile_source_refs(expected)
      require_true(descriptor.fetch('source_references') == expected_sources, "#{id}: refs differ from independent literal source map")
      require_true(descriptor.fetch('source_references_complete') == expected.fetch('complete') &&
        descriptor.fetch('source_references_status') == expected.fetch('status'), "#{id}: source-ref certainty differs")
      if expected.fetch('status') == 'unknown'
        reason = descriptor.fetch('source_references_reason')
        require_true(reason.is_a?(String) && !reason.empty?, "#{id}: UNKNOWN lacks a reason")
      else
        require_true(descriptor.fetch('source_references_reason').nil?, "#{id}: complete refs unexpectedly carry an UNKNOWN reason")
      end
      expected_resolution = { 'name' => resolved_table.fetch('name'),
        'uuid' => resolved_table.fetch('uuid'), 'engine' => resolved_table.fetch('engine') }
      require_true(profile.fetch('resolved_target') == expected_resolution &&
        profile.fetch('resolved_target_by_database') == expected_resolution,
        "#{id}: resolver overloads differ from independent system.tables identity")
      require_true(profile.fetch('data_access_guard') == { 'part_inventory' => 'unsupported', 'row_scan' => 'unsupported', 'callbacks' => 0 },
        "#{id}: MV data access was not rejected before callbacks")
    end

    controls = helper.fetch('unsupported_controls')
    require_true(controls.map { |item| item.fetch('id') } == CONTROL_IDS, 'unsupported-control roster differs')
    controls.each do |control|
      id = control.fetch('id')
      expected_control = CONTROL_CASES.fetch(id)
      require_true(control.fetch('database') == expected_control.fetch('database') &&
        control.fetch('name') == expected_control.fetch('name'), "#{id}: control identity differs from the fixed map")
      metadata = metadata_record(observations, expected_control.fetch('database'), "#{encode_filename(expected_control.fetch('name'))}.sql")
      case control.fetch('classification')
      when 'unsupported_error'
        require_true(control.fetch('error_class') == 'CrystalClick::UnsupportedFormatError',
          "#{id}: unsupported error has the wrong exception class")
        require_true(control.fetch('kind').nil? && control.fetch('engine').nil? && control.fetch('metadata_ddl').nil?,
          "#{id}: error result contains partial table metadata")
      when 'unsupported_no_descriptor'
        require_true(control.fetch('kind') == 'materialized_view' && control.fetch('engine') == 'MaterializedView',
          "#{id}: no-descriptor result is not a materialized view")
        require_true(control.fetch('metadata_ddl') == metadata.fetch('ddl'), "#{id}: no-descriptor raw DDL differs")
        require_true(control.fetch('error_class').nil? && control.fetch('error_message').nil?,
          "#{id}: no-descriptor result unexpectedly carries an error")
      else
        fail!("#{id}: REFRESH/SECURITY control was admitted")
      end
    end

    negatives = helper.fetch('resolver_negative_cases')
    require_true(negatives.map { |item| item.fetch('id') } == NEGATIVE_IDS, 'resolver negative roster differs')
    negatives.each do |item|
      require_true(item.fetch('classification') == 'rejected' && item.fetch('resolved_name').nil? && item.fetch('resolved_uuid').nil?,
        "#{item.fetch('id')}: resolver had a fallback/success")
      require_true(%w[CrystalClick::InvalidPartError CrystalClick::UnsupportedFormatError].include?(item.fetch('error_class')),
        "#{item.fetch('id')}: unexpected resolver rejection class")
    end

    projection = helper.fetch('projection_control')
    require_true(projection.fetch('database') == MAIN_DB && projection.fetch('name') == 'projection_source' &&
      projection.fetch('kind') == 'table' && projection.fetch('engine') == 'MergeTree', 'projection table identity differs')
    require_true(projection.fetch('columns') == %w[k v], 'projection metadata leaked into ordinary columns')
    pairs = projection.fetch('projections').map { |item| [item.fetch('name'), item.fetch('definition').gsub(/\s+/, ' ').strip] }
    require_true(pairs == [['by_v', 'SELECT v, k ORDER BY v']], 'projection declaration differs from stock CREATE metadata')
    projection_metadata = metadata_record(observations, MAIN_DB, 'projection_source.sql')
    require_true(projection.fetch('metadata_ddl') == projection_metadata.fetch('ddl'), 'projection DDL differs from raw Atomic metadata')
  end

  def audit(native_root, evidence_root, expected_helper_sha)
    native_root = canonical_root(native_root, NATIVE_PREFIX, 'native root')
    root = canonical_root(evidence_root, EVIDENCE_PREFIX, 'evidence root')
    summary = json_file(File.join(root, 'summary.json'), root)
    require_true(summary.fetch('format') == FORMAT_SUMMARY && summary.fetch('classification') == 'paired_materialized_view_metadata_observed' && summary.fetch('success') == true,
      'summary is not a successful W228 capture')
    require_true(summary.fetch('native_root') == native_root && summary.fetch('evidence_root') == root,
      'summary root paths differ from audit arguments')
    require_true(summary.fetch('store_root') == File.join(native_root, 'stores', 'catalog'), 'summary store path differs')
    require_true(summary.fetch('source_pin') == { 'root' => SOURCE_ROOT, 'revision' => SOURCE_REVISION, 'dirty' => false },
      'source pin differs from fixed source state')
    source_head, source_head_status = Open3.capture2('git', '-C', SOURCE_ROOT, 'rev-parse', 'HEAD')
    source_dirty, source_dirty_status = Open3.capture2('git', '-C', SOURCE_ROOT, 'status', '--porcelain')
    require_true(source_head_status.success? && source_head.strip == SOURCE_REVISION &&
      source_dirty_status.success? && source_dirty.empty?, 'live pinned ClickHouse source state drifted')
    require_true(summary.fetch('runtime_pin').fetch('version') == VERSION &&
      summary.fetch('runtime_pin').fetch('build_hash') == BUILD_HASH &&
      summary.fetch('runtime_pin').fetch('sha256') == RUNTIME_SHA256, 'runtime pin differs from exact binary')
    require_true(summary.fetch('helper_sha256_expected') == expected_helper_sha &&
      summary.fetch('helper_sha256_at_start') == expected_helper_sha &&
      summary.fetch('helper_sha256_after_execute') == expected_helper_sha, 'helper SHA pin differs')

    input_path = File.join(root, 'helper_input.json')
    input_bytes = read_file(input_path, root)
    require_true(Digest::SHA256.hexdigest(input_bytes) == summary.fetch('helper_input_sha256'), 'helper input digest differs')
    input = JSON.parse(input_bytes.force_encoding(Encoding::UTF_8))
    require_true(input.fetch('format') == FORMAT_INPUT && input.fetch('store_root') == summary.fetch('store_root'), 'helper input format/store differs')
    expected_views = VIEW_IDS.map do |id|
      item = VIEW_CASES.fetch(id)
      { 'id' => id, 'database' => item.fetch('database'), 'name' => item.fetch('name') }
    end
    require_true(input.fetch('views') == expected_views, 'helper input view roster differs from independent fixture map')
    expected_controls = CONTROL_IDS.map do |id|
      item = CONTROL_CASES.fetch(id)
      { 'id' => id, 'database' => item.fetch('database'), 'name' => item.fetch('name') }
    end
    require_true(input.fetch('unsupported_controls') == expected_controls, 'helper input unsupported control roster differs')
    require_true(input.fetch('resolver_negative_cases') == [
      { 'id' => 'ordinary_table', 'database' => MAIN_DB, 'name' => 'src' },
      { 'id' => 'missing_view', 'database' => MAIN_DB, 'name' => 'mv_missing' },
    ], 'helper input negative resolver cases differ')
    require_true(input.fetch('projection_control') == { 'database' => MAIN_DB, 'name' => 'projection_source' }, 'helper projection input differs')

    invocations = audit_invocations(root, native_root, summary, input_path)
    require_true(invocations.fetch('runtime-version-pin').fetch('stdout').strip == VERSION, 'raw version output differs')
    require_true(invocations.fetch('runtime-build-pin').fetch('stdout').strip == "VERSION_GITHASH=#{BUILD_HASH}", 'raw build output differs')
    observations = json_file(File.join(root, 'stock_observations.json'), root)
    require_true(observations.fetch('format') == FORMAT_OBSERVATIONS, 'stock observation format differs')
    require_true(observations.fetch('system_databases_stdout') == invocations.fetch('stock-system-databases').fetch('stdout'),
      'raw system.databases output differs from process evidence')
    require_true(observations.fetch('system_tables_stdout') == invocations.fetch('stock-system-tables').fetch('stdout'),
      'raw system.tables output differs from process evidence')
    databases = database_rows(invocations.fetch('stock-system-databases').fetch('stdout'))
    tables = table_rows(invocations.fetch('stock-system-tables').fetch('stdout'))
    require_true(observations.fetch('databases') == databases && observations.fetch('tables') == tables,
      'structured stock observations differ from raw TSV process outputs')
    verify_stock_roster!(databases, tables)
    verify_metadata_inventory!(native_root, observations, databases, tables)

    helper_bytes = read_file(File.join(root, 'helper.json'), root)
    require_true(helper_bytes == invocations.fetch('crystal-helper').fetch('stdout'), 'helper JSON differs from raw stdout')
    helper = JSON.parse(helper_bytes.force_encoding(Encoding::UTF_8))
    audit_profiles!(helper, observations, tables)
    require_true(summary.fetch('counts').fetch('views_expected') == VIEW_IDS.length &&
      summary.fetch('counts').fetch('views_observed') == VIEW_IDS.length, 'summary profile counts differ from audited roster')
    puts "PASS W228 raw metadata/helper evidence audit views=#{VIEW_IDS.length} processes=#{invocations.length}"
    true
  end

  def main(argv)
    options = {}
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: ruby scripts/check_materialized_view_metadata_evidence_w228.rb --native-root PATH --evidence-root PATH --helper-sha256 HEX'
      opts.on('--native-root PATH') { |value| options[:native_root] = value }
      opts.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
      opts.on('--helper-sha256 HEX') { |value| options[:helper_sha256] = value }
    end
    parser.parse!(argv)
    require_true(argv.empty? && %i[native_root evidence_root helper_sha256].all? { |key| options.key?(key) }, parser.to_s)
    expected_sha = R.validate_sha256_pin!(options.fetch(:helper_sha256), 'external W228 helper SHA-256')
    audit(options.fetch(:native_root), options.fetch(:evidence_root), expected_sha)
    true
  rescue StandardError => error
    warn "W228 evidence audit rejected: #{error.class}: #{error.message}"
    false
  end
end

exit(CheckMaterializedViewMetadataEvidenceW228.main(ARGV) ? 0 : 1) if $PROGRAM_NAME == __FILE__
