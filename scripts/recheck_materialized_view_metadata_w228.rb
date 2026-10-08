#!/usr/bin/env ruby
# Capture stock Atomic MATERIALIZED VIEW metadata and compare it with the
# bounded offline descriptor API. This is metadata/resolution evidence only.

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require_relative 'recheck_aggregate_recursive_w224'

module RecheckMaterializedViewMetadataW228
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

  EXPECTED = {
    'named_unqualified' => {
      'database' => MAIN_DB, 'name' => 'mv_unqualified', 'target_kind' => 'named',
      'target' => { 'database' => MAIN_DB, 'name' => 'dst', 'database_qualified' => true, 'uuid' => nil },
      'persisted_target_sql' => "TO #{MAIN_DB}.dst",
      'inner_engine' => nil, 'sources' => [{ 'database' => MAIN_DB, 'name' => 'src', 'database_qualified' => true }],
      'complete' => true, 'status' => 'complete',
    },
    'cross_database_target' => {
      'database' => MAIN_DB, 'name' => 'mv_cross_target', 'target_kind' => 'named',
      'target' => { 'database' => TARGET_DB, 'name' => 'dst', 'database_qualified' => true, 'uuid' => nil },
      'persisted_target_sql' => "TO #{TARGET_DB}.dst", 'authored_target_uuid' => TARGET_UUID,
      'inner_engine' => nil, 'sources' => [{ 'database' => MAIN_DB, 'name' => 'src', 'database_qualified' => true }],
      'complete' => true, 'status' => 'complete',
    },
    'cross_database_source' => {
      'database' => MAIN_DB, 'name' => 'mv_cross_source', 'target_kind' => 'named',
      'target' => { 'database' => MAIN_DB, 'name' => 'dst', 'database_qualified' => true, 'uuid' => nil },
      'persisted_target_sql' => "TO #{MAIN_DB}.dst",
      'inner_engine' => nil, 'sources' => [{ 'database' => SOURCE_DB, 'name' => 'src', 'database_qualified' => true }],
      'complete' => true, 'status' => 'complete',
    },
    'source_free_named_target' => {
      'database' => MAIN_DB, 'name' => 'mv_source_free', 'target_kind' => 'named',
      'target' => { 'database' => MAIN_DB, 'name' => 'dst', 'database_qualified' => true, 'uuid' => nil },
      'persisted_target_sql' => "TO #{MAIN_DB}.dst",
      'inner_engine' => nil, 'sources' => [],
      'complete' => true, 'status' => 'complete',
    },
    'cte_unknown' => {
      'database' => MAIN_DB, 'name' => 'mv_cte_unknown', 'target_kind' => 'named',
      'target' => { 'database' => MAIN_DB, 'name' => 'dst', 'database_qualified' => true, 'uuid' => nil },
      'persisted_target_sql' => "TO #{MAIN_DB}.dst",
      'inner_engine' => nil, 'sources' => [],
      'complete' => false, 'status' => 'unknown',
    },
    'inner_uuid_explicit' => {
      'database' => MAIN_DB, 'name' => 'mv_inner_uuid', 'target_kind' => 'inner_uuid',
      'target' => { 'database' => nil, 'name' => nil, 'database_qualified' => nil, 'uuid' => INNER_UUID },
      'persisted_target_sql' => "TO INNER UUID '#{INNER_UUID}'",
      'inner_engine' => 'MergeTree', 'sources' => [{ 'database' => MAIN_DB, 'name' => 'src', 'database_qualified' => true }],
      'complete' => true, 'status' => 'complete',
    },
    'engine_canonical_inner_uuid' => {
      'database' => MAIN_DB, 'name' => 'mv_engine_inner', 'target_kind' => 'inner_uuid',
      'target' => { 'database' => nil, 'name' => nil, 'database_qualified' => nil, 'uuid' => :physical_inner_uuid },
      'persisted_target_sql' => :physical_inner_uuid,
      'inner_engine' => 'MergeTree', 'sources' => [{ 'database' => MAIN_DB, 'name' => 'src', 'database_qualified' => true }],
      'complete' => true, 'status' => 'complete',
    },
    'join_unknown' => {
      'database' => MAIN_DB, 'name' => 'mv_join_unknown', 'target_kind' => 'named',
      'target' => { 'database' => MAIN_DB, 'name' => 'dst', 'database_qualified' => true, 'uuid' => nil },
      'persisted_target_sql' => "TO #{MAIN_DB}.dst",
      'inner_engine' => nil, 'sources' => [], 'complete' => false, 'status' => 'unknown',
    },
    'subquery_unknown' => {
      'database' => MAIN_DB, 'name' => 'mv_subquery_unknown', 'target_kind' => 'named',
      'target' => { 'database' => MAIN_DB, 'name' => 'dst', 'database_qualified' => true, 'uuid' => nil },
      'persisted_target_sql' => "TO #{MAIN_DB}.dst",
      'inner_engine' => nil, 'sources' => [], 'complete' => false, 'status' => 'unknown',
    },
    'literal_fake_from_to' => {
      'database' => MAIN_DB, 'name' => 'mv_literal_fake', 'target_kind' => 'named',
      'target' => { 'database' => MAIN_DB, 'name' => 'dst', 'database_qualified' => true, 'uuid' => nil },
      'persisted_target_sql' => "TO #{MAIN_DB}.dst",
      'inner_engine' => nil, 'sources' => [{ 'database' => MAIN_DB, 'name' => 'src', 'database_qualified' => true }],
      'complete' => true, 'status' => 'complete',
    },
    'quoted_identifiers' => {
      'database' => MAIN_DB, 'name' => 'mv_quoted', 'target_kind' => 'named',
      'target' => { 'database' => MAIN_DB, 'name' => 'dst.dot', 'database_qualified' => true, 'uuid' => nil },
      'persisted_target_sql' => "TO #{MAIN_DB}.`dst.dot`",
      'inner_engine' => nil, 'sources' => [{ 'database' => MAIN_DB, 'name' => 'src.dot', 'database_qualified' => true }],
      'complete' => true, 'status' => 'complete',
    },
  }.freeze

  def fail!(message)
    raise ArgumentError, message
  end

  def require_true(condition, message)
    fail!(message) unless condition
  end

  def write_new(path, bytes)
    File.open(path, 'wbx', 0o600) { |file| file.write(bytes) }
  rescue Errno::EEXIST
    fail!("refusing to overwrite W228 evidence: #{path}")
  end

  def write_json(path, object)
    write_new(path, JSON.pretty_generate(object) + "\n")
  end

  def validate_root(path, prefix, label)
    full = File.expand_path(path)
    require_true(File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full && Dir.children(full).empty?,
      "#{label} must be a fresh, empty, canonical directory")
    require_true(File.dirname(full) == File.realpath('/private/tmp') && full.start_with?(prefix),
      "#{label} must be a direct /private/tmp child with prefix #{prefix}")
    full
  end

  def expected_source_refs(case_id)
    EXPECTED.fetch(case_id).fetch('sources').map do |reference|
      { 'database' => reference.fetch('database'), 'name' => reference.fetch('name'),
        'database_qualified' => reference.fetch('database_qualified') }
    end
  end

  def build_input(store)
    {
      'format' => FORMAT_INPUT,
      'store_root' => store,
      'views' => VIEW_IDS.map do |id|
        item = EXPECTED.fetch(id)
        { 'id' => id, 'database' => item.fetch('database'), 'name' => item.fetch('name') }
      end,
      'unsupported_controls' => CONTROL_IDS.map do |id|
        item = CONTROL_CASES.fetch(id)
        { 'id' => id, 'database' => item.fetch('database'), 'name' => item.fetch('name') }
      end,
      'resolver_negative_cases' => [
        { 'id' => 'ordinary_table', 'database' => MAIN_DB, 'name' => 'src' },
        { 'id' => 'missing_view', 'database' => MAIN_DB, 'name' => 'mv_missing' },
      ],
      'projection_control' => { 'database' => MAIN_DB, 'name' => 'projection_source' },
    }
  end

  class Probe
    def initialize(options)
      @binary = R.validate_binary!(options.fetch(:clickhouse))
      @helper = R.validate_program!(options.fetch(:helper), 'prebuilt W228 Crystal helper')
      @helper_sha_expected = R.validate_sha256_pin!(options.fetch(:helper_sha256), 'external W228 helper SHA-256')
      @helper_sha_start = Digest::SHA256.file(@helper).hexdigest
      RecheckMaterializedViewMetadataW228.require_true(@helper_sha_start == @helper_sha_expected,
        "prebuilt helper SHA differs from external pin: #{@helper_sha_start}")
      @native_root = RecheckMaterializedViewMetadataW228.validate_root(options.fetch(:native_root), NATIVE_PREFIX, 'native root')
      @root = RecheckMaterializedViewMetadataW228.validate_root(options.fetch(:evidence_root), EVIDENCE_PREFIX, 'evidence root')
      @recorder = R::Recorder.new(@root, @binary)
      @fatal = nil
      @runtime_pin = nil
      @source_pin = nil
      @stock_observations = nil
      @helper_result = nil
      @helper_input_sha = nil
      @helper_sha_after = nil
    end

    def run
      prepare_layout
      pin_source_and_runtime
      create_catalogue
      capture_system_catalogue
      capture_metadata_files
      invoke_helper
      compare_helper
      verify_process_roster
      write_summary('paired_materialized_view_metadata_observed')
      puts "W228 stock MV metadata cases=#{VIEW_IDS.length}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal ||= "#{error.class}: #{error.message}"
      write_summary('runner_failure_or_observations_differ') rescue nil
      warn "W228 metadata probe failure: #{@fatal}"
      false
    end

    private

    def checked_success!(record, label)
      require_true(record.fetch('classification') == 'process_success' &&
        record.fetch('exitstatus') == 0 && !record.fetch('signaled') &&
        !record.fetch('timed_out') && record.fetch('spawn_error').nil?,
        "#{label} failed as a process; this is not a semantic refusal")
      record
    end

    def process(label, sql = nil, timeout: R::PROCESS_TIMEOUT_SECONDS, argv: nil)
      @recorder.run(label, @store, sql, timeout: timeout, argv: argv)
    end

    def prepare_layout
      %w[invocations].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      Dir.mkdir(File.join(@native_root, 'stores'), 0o700)
      @store = File.join(@native_root, 'stores', 'catalog')
      Dir.mkdir(@store, 0o700)
    end

    def pin_source_and_runtime
      require_true(File.directory?(SOURCE_ROOT) && File.realpath(SOURCE_ROOT) == SOURCE_ROOT,
        'pinned ClickHouse source root is absent or noncanonical')
      git_head, git_head_status = Open3.capture2('git', '-C', SOURCE_ROOT, 'rev-parse', 'HEAD')
      git_head = git_head.strip
      require_true(git_head_status.success? && git_head == SOURCE_REVISION, "ClickHouse source revision differs from pin: #{git_head.inspect}")
      git_dirty, git_dirty_status = Open3.capture2('git', '-C', SOURCE_ROOT, 'status', '--porcelain')
      require_true(git_dirty_status.success? && git_dirty.empty?, 'pinned ClickHouse source tree is dirty')
      @source_pin = { 'root' => SOURCE_ROOT, 'revision' => git_head, 'dirty' => false }
      version = checked_success!(process('runtime-version-pin', 'SELECT version() FORMAT TSVRaw'), 'runtime version')
      require_true(version.fetch('stdout').strip == VERSION, 'native version differs from exact pin')
      build = checked_success!(process('runtime-build-pin',
        "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw"), 'runtime build hash')
      require_true(build.fetch('stdout').strip == "VERSION_GITHASH=#{BUILD_HASH}", 'native build hash differs from exact pin')
      @runtime_pin = { 'version' => VERSION, 'build_hash' => BUILD_HASH,
        'sha256' => Digest::SHA256.file(@binary).hexdigest, 'source_correlation' => 'not_asserted' }
    end

    def create_catalogue
      bootstrap = <<~SQL
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
      checked_success!(process('stock-bootstrap', bootstrap), 'stock bootstrap')

      creates = {
        'named_unqualified' => "USE #{MAIN_DB}; CREATE MATERIALIZED VIEW mv_unqualified TO dst AS SELECT k, v FROM src;",
        'cross_database_target' => "CREATE MATERIALIZED VIEW #{MAIN_DB}.mv_cross_target TO #{TARGET_DB}.dst UUID '#{TARGET_UUID}' AS SELECT k, v FROM #{MAIN_DB}.src;",
        'cross_database_source' => "CREATE MATERIALIZED VIEW #{MAIN_DB}.mv_cross_source TO #{MAIN_DB}.dst AS SELECT k, v FROM #{SOURCE_DB}.src;",
        'inner_uuid_explicit' => "CREATE MATERIALIZED VIEW #{MAIN_DB}.mv_inner_uuid TO INNER UUID '#{INNER_UUID}' (k UInt64, v String) ENGINE = MergeTree ORDER BY k AS SELECT k, v FROM #{MAIN_DB}.src;",
        'source_free_named_target' => "CREATE MATERIALIZED VIEW #{MAIN_DB}.mv_source_free TO #{MAIN_DB}.dst AS SELECT toUInt64(0) AS k, 'constant' AS v;",
        'cte_unknown' => "CREATE MATERIALIZED VIEW #{MAIN_DB}.mv_cte_unknown TO #{MAIN_DB}.dst AS WITH source_cte AS (SELECT k, v FROM #{MAIN_DB}.src) SELECT k, v FROM source_cte;",
        'engine_canonical_inner_uuid' => "CREATE MATERIALIZED VIEW #{MAIN_DB}.mv_engine_inner ENGINE = MergeTree ORDER BY k AS SELECT k, v FROM #{MAIN_DB}.src;",
        'join_unknown' => "CREATE MATERIALIZED VIEW #{MAIN_DB}.mv_join_unknown TO #{MAIN_DB}.dst AS SELECT s.k, s.v FROM #{MAIN_DB}.src AS s INNER JOIN #{MAIN_DB}.src AS other ON s.k = other.k;",
        'subquery_unknown' => "CREATE MATERIALIZED VIEW #{MAIN_DB}.mv_subquery_unknown TO #{MAIN_DB}.dst AS SELECT k, v FROM (SELECT k, v FROM #{MAIN_DB}.src);",
        'literal_fake_from_to' => "CREATE MATERIALIZED VIEW #{MAIN_DB}.mv_literal_fake TO #{MAIN_DB}.dst AS SELECT k, 'TO fake FROM fake' AS v FROM #{MAIN_DB}.src;",
        'quoted_identifiers' => "CREATE MATERIALIZED VIEW #{MAIN_DB}.mv_quoted TO \"#{MAIN_DB}\".\"dst.dot\" AS SELECT k, v FROM \"#{MAIN_DB}\".\"src.dot\";",
      }
      VIEW_IDS.each do |id|
        checked_success!(process("stock-create-#{id}", creates.fetch(id)), "stock MV #{id}")
      end

      controls = {
        'refresh_control' => "CREATE MATERIALIZED VIEW #{MAIN_DB}.mv_refresh REFRESH EVERY 1 MINUTE ENGINE = MergeTree ORDER BY k AS SELECT k, v FROM #{MAIN_DB}.src;",
        'security_control' => "CREATE MATERIALIZED VIEW #{MAIN_DB}.mv_security TO #{MAIN_DB}.dst DEFINER = CURRENT_USER SQL SECURITY DEFINER AS SELECT k, v FROM #{MAIN_DB}.src;",
      }
      CONTROL_IDS.each do |id|
        checked_success!(process("stock-create-#{id}", controls.fetch(id)), "stock control #{id}")
      end

      table_function = "CREATE MATERIALIZED VIEW #{MAIN_DB}.mv_table_function TO #{MAIN_DB}.dst AS SELECT number AS k, toString(number) AS v FROM numbers(1);"
      refusal = process('stock-table-function-refusal', table_function)
      require_true(refusal.fetch('classification') == 'process_nonzero_or_signaled_exit' &&
        !refusal.fetch('timed_out') && !refusal.fetch('spawn_error'), 'table-function stock control was not a bounded process refusal')
      require_true(refusal.fetch('stderr').include?('QUERY_IS_NOT_SUPPORTED_IN_MATERIALIZED_VIEW'),
        'table-function refusal lacks the stock MATERIALIZED VIEW unsupported diagnostic')
    end

    def capture_system_catalogue
      quoted_dbs = DATABASES.map { |name| "'#{name}'" }.join(', ')
      database_sql = "SELECT name, toString(uuid) FROM system.databases WHERE name IN (#{quoted_dbs}) ORDER BY name FORMAT TSVRaw"
      table_sql = "SELECT database, name, toString(uuid), engine FROM system.tables WHERE database IN (#{quoted_dbs}) ORDER BY database, name FORMAT TSVRaw"
      db_record = checked_success!(process('stock-system-databases', database_sql), 'system.databases capture')
      table_record = checked_success!(process('stock-system-tables', table_sql), 'system.tables capture')
      databases = db_record.fetch('stdout').lines.map do |line|
        fields = line.chomp.split("\t", -1)
        require_true(fields.length == 2, "malformed system.databases row: #{line.inspect}")
        { 'name' => fields[0], 'uuid' => fields[1] }
      end
      tables = table_record.fetch('stdout').lines.map do |line|
        fields = line.chomp.split("\t", -1)
        require_true(fields.length == 4, "malformed system.tables row: #{line.inspect}")
        { 'database' => fields[0], 'name' => fields[1], 'uuid' => fields[2], 'engine' => fields[3] }
      end
      require_true(databases.map { |row| row.fetch('name') }.sort == DATABASES.sort, 'stock database roster differs')
      expected_names = %w[src dst src.dot dst.dot projection_source mv_unqualified mv_cross_target mv_cross_source
        mv_source_free mv_cte_unknown mv_inner_uuid mv_engine_inner mv_join_unknown mv_subquery_unknown mv_literal_fake mv_quoted mv_refresh mv_security]
      actual_hidden = tables.select { |row| row.fetch('database') == MAIN_DB && row.fetch('name').start_with?('.inner_id.') }.map { |row| row.fetch('name') }
      require_true(actual_hidden.length == 3, "expected exactly three hidden inline/refresh targets, got #{actual_hidden.length}")
      expected_names.concat(actual_hidden)
      main_names = tables.select { |row| row.fetch('database') == MAIN_DB }.map { |row| row.fetch('name') }
      require_true(main_names.sort == expected_names.sort, "stock main-table roster differs: #{main_names.sort.inspect}")
      require_true(tables.any? { |row| row.fetch('database') == SOURCE_DB && row.fetch('name') == 'src' }, 'cross-source fixture table is absent')
      require_true(tables.any? { |row| row.fetch('database') == TARGET_DB && row.fetch('name') == 'dst' }, 'cross-target fixture table is absent')
      @stock_observations = { 'format' => FORMAT_OBSERVATIONS, 'databases' => databases, 'tables' => tables,
        'system_databases_stdout' => db_record.fetch('stdout'), 'system_tables_stdout' => table_record.fetch('stdout') }
    end

    def encode_filename(name)
      name.b.bytes.map do |byte|
        char = byte.chr
        if /\A[A-Za-z0-9_]\z/.match?(char)
          char
        else
          format('%%%02X', byte)
        end
      end.join
    end

    def metadata_directory(database)
      db = @stock_observations.fetch('databases').find { |row| row.fetch('name') == database } || fail!("missing database row #{database}")
      uuid = db.fetch('uuid')
      path = File.join(@store, 'store', uuid[0, 3], uuid)
      require_true(File.directory?(path) && !File.symlink?(path) && File.realpath(path) == path, "missing canonical Atomic metadata directory for #{database}")
      path
    end

    def capture_metadata_files
      entries = []
      DATABASES.each do |database|
        directory = metadata_directory(database)
        Dir.children(directory).sort.each do |basename|
          next unless basename.end_with?('.sql')
          path = File.join(directory, basename)
          require_true(File.file?(path) && !File.symlink?(path) && File.realpath(path) == path, "invalid stock metadata file: #{path}")
          bytes = File.binread(path)
          entries << { 'database' => database, 'basename' => basename,
            'path' => path, 'byte_count' => bytes.bytesize, 'sha256' => Digest::SHA256.hexdigest(bytes),
            'ddl' => bytes.force_encoding(Encoding::UTF_8) }
        end
        database_path = File.join(@store, 'metadata', "#{database}.sql")
        require_true(File.file?(database_path) && !File.symlink?(database_path), "missing Atomic database metadata #{database_path}")
        bytes = File.binread(database_path)
        entries << { 'database' => database, 'basename' => "#{database}.sql", 'path' => database_path,
          'byte_count' => bytes.bytesize, 'sha256' => Digest::SHA256.hexdigest(bytes), 'ddl' => bytes.force_encoding(Encoding::UTF_8) }
      end
      table_roster = @stock_observations.fetch('tables').map { |row| [row.fetch('database'), "#{encode_filename(row.fetch('name'))}.sql"] }
      database_files = DATABASES.map { |database| "#{database}.sql" }
      metadata_roster = entries.reject { |item| database_files.include?(item.fetch('basename')) }
        .map { |item| [item.fetch('database'), item.fetch('basename')] }
      require_true(table_roster.sort == metadata_roster.sort,
        "Atomic table metadata filenames differ from system.tables: #{metadata_roster.sort.inspect}")
      @stock_observations['metadata_files'] = entries
      write_json(File.join(@root, 'stock_observations.json'), @stock_observations)
    end

    def build_helper_input
      input = RecheckMaterializedViewMetadataW228.build_input(@store)
      path = File.join(@root, 'helper_input.json')
      write_json(path, input)
      @helper_input_sha = Digest::SHA256.file(path).hexdigest
      path
    end

    def invoke_helper
      input_path = build_helper_input
      record = process('crystal-helper', nil, timeout: R::HELPER_TIMEOUT_SECONDS, argv: [@helper, input_path])
      checked_success!(record, 'W228 Crystal helper')
      @helper_sha_after = Digest::SHA256.file(@helper).hexdigest
      require_true(@helper_sha_after == @helper_sha_expected, 'prebuilt helper changed during capture')
      require_true(record.fetch('stderr').empty?, 'W228 helper wrote unexpected stderr')
      @helper_result = JSON.parse(record.fetch('stdout'))
      require_true(@helper_result.fetch('format') == FORMAT_HELPER, 'W228 helper output format differs')
      write_new(File.join(@root, 'helper.json'), record.fetch('stdout'))
    end

    def expected_ref(reference)
      { 'database' => reference.fetch('database'), 'name' => reference.fetch('name'),
        'database_qualified' => reference.fetch('database_qualified') }
    end

    def extract_query(ddl, case_id)
      marker = /\nAS[ \t]+(?:SELECT|WITH)\b/i.match(ddl)
      require_true(marker, "#{case_id} persisted ATTACH DDL has no top-level AS SELECT/WITH boundary")
      query = ddl[marker.begin(0) + 1..-1].sub(/\AAS[ \t]*/i, '').strip
      require_true(query.match?(/\A(?:SELECT|WITH)\b/i), "#{case_id} persisted query does not begin with SELECT or WITH")
      query
    end

    def stock_metadata(database, name)
      basename = "#{encode_filename(name)}.sql"
      item = @stock_observations.fetch('metadata_files').find do |entry|
        entry.fetch('database') == database && entry.fetch('basename') == basename
      end
      item || fail!("stock metadata is absent for #{database}.#{name}")
    end

    def system_table(database, name)
      @stock_observations.fetch('tables').find do |row|
        row.fetch('database') == database && row.fetch('name') == name
      end || fail!("system.tables has no #{database}.#{name}")
    end

    def compare_helper
      require_true(@helper_result.fetch('database_names').include?(MAIN_DB), 'catalog database naming omitted main DB')
      profiles = @helper_result.fetch('views')
      require_true(profiles.map { |item| item.fetch('id') } == VIEW_IDS, 'helper view roster/order differs')
      profiles.each do |profile|
        id = profile.fetch('id')
        expected = EXPECTED.fetch(id)
        metadata = stock_metadata(expected.fetch('database'), expected.fetch('name'))
        descriptor = profile.fetch('descriptor')
        target = descriptor.fetch('target')
        require_true(profile.fetch('database') == expected.fetch('database') && profile.fetch('name') == expected.fetch('name'), "#{id}: helper table identity differs")
        require_true(profile.fetch('kind') == 'materialized_view' && profile.fetch('engine') == 'MaterializedView', "#{id}: helper kind/engine differs")
        require_true(profile.fetch('uuid') == system_table(expected.fetch('database'), expected.fetch('name')).fetch('uuid'), "#{id}: helper UUID differs from raw system.tables")
        require_true(profile.fetch('metadata_ddl') == metadata.fetch('ddl') && profile.fetch('metadata_sha256') == metadata.fetch('sha256'), "#{id}: helper metadata differs from raw persisted ATTACH bytes")
        require_true(descriptor.fetch('declaring_database') == expected.fetch('database'), "#{id}: declaring database differs")
        require_true(descriptor.fetch('query') == extract_query(metadata.fetch('ddl'), id), "#{id}: query differs from raw persisted AS query")
        require_true(target.fetch('kind') == expected.fetch('target_kind'), "#{id}: target kind differs")
        header = metadata.fetch('ddl').lines.first || ''
        if expected.fetch('target_kind') == 'named'
          require_true(target.fetch('reference') == expected_ref(expected.fetch('target')), "#{id}: named target reference differs")
          require_true(target.fetch('uuid').nil?, "#{id}: target UUID should be absent")
          resolved = system_table(expected.fetch('target').fetch('database'), expected.fetch('target').fetch('name'))
          if expected.key?('authored_target_uuid')
            require_true(resolved.fetch('uuid') == expected.fetch('authored_target_uuid'), "#{id}: authored target UUID differs from the physical target")
          end
          persisted_target_sql = expected.fetch('persisted_target_sql')
        elsif expected.fetch('target_kind') == 'inner_uuid'
          resolved = system_table(expected.fetch('database'), ".inner_id.#{profile.fetch('uuid')}")
          target_uuid = expected.fetch('target').fetch('uuid') == :physical_inner_uuid ? resolved.fetch('uuid') : expected.fetch('target').fetch('uuid')
          require_true(target.fetch('reference').nil? && target.fetch('uuid') == target_uuid, "#{id}: persisted inner UUID target differs")
          require_true(resolved.fetch('uuid') == target_uuid, "#{id}: physical inner target UUID differs from persisted target UUID")
          persisted_target_sql = expected.fetch('persisted_target_sql')
          persisted_target_sql = "TO INNER UUID '#{resolved.fetch('uuid')}'" if persisted_target_sql == :physical_inner_uuid
          require_true(persisted_target_sql == "TO INNER UUID '#{target_uuid}'", "#{id}: fixed persisted inner target spelling differs")
        end
        expected_header = "ATTACH MATERIALIZED VIEW _ UUID '#{profile.fetch('uuid')}' #{persisted_target_sql}\n"
        require_true(header == expected_header, "#{id}: persisted ATTACH header differs from the canonical target (including optional UUID normalization)")
        require_true(descriptor.fetch('inner_engine') == expected.fetch('inner_engine'), "#{id}: inline engine differs")
        sources = descriptor.fetch('source_references')
        require_true(sources == RecheckMaterializedViewMetadataW228.expected_source_refs(id), "#{id}: source references differ from literal expectation")
        require_true(descriptor.fetch('source_references_complete') == expected.fetch('complete') &&
          descriptor.fetch('source_references_status') == expected.fetch('status'), "#{id}: source-reference certainty differs")
        if expected.fetch('status') == 'unknown'
          require_true(descriptor.fetch('source_references_reason').is_a?(String) && !descriptor.fetch('source_references_reason').empty?, "#{id}: UNKNOWN reason is empty")
        else
          require_true(descriptor.fetch('source_references_reason').nil?, "#{id}: complete reference list has an UNKNOWN reason")
        end
        actual_resolution = profile.fetch('resolved_target')
        expected_resolution = { 'name' => resolved.fetch('name'), 'uuid' => resolved.fetch('uuid'), 'engine' => resolved.fetch('engine') }
        require_true(actual_resolution == expected_resolution && profile.fetch('resolved_target_by_database') == expected_resolution,
          "#{id}: resolver overloads differ from independent system.tables target identity")
        guard = profile.fetch('data_access_guard')
        require_true(guard == { 'part_inventory' => 'unsupported', 'row_scan' => 'unsupported', 'callbacks' => 0 },
          "#{id}: materialized-view data access guard changed")
      end

      controls = @helper_result.fetch('unsupported_controls')
      require_true(controls.map { |item| item.fetch('id') } == CONTROL_IDS, 'unsupported-control roster differs')
      controls.each do |control|
        id = control.fetch('id')
        expected_control = CONTROL_CASES.fetch(id)
        require_true(control.fetch('database') == expected_control.fetch('database') &&
          control.fetch('name') == expected_control.fetch('name'), "#{id}: control identity differs from the fixed map")
        item = stock_metadata(expected_control.fetch('database'), expected_control.fetch('name'))
        case control.fetch('classification')
        when 'unsupported_error'
          require_true(control.fetch('error_class') == 'CrystalClick::UnsupportedFormatError',
            "#{id}: unsupported error has the wrong exception class")
          require_true(control.fetch('kind').nil? && control.fetch('engine').nil? && control.fetch('metadata_ddl').nil?,
            "#{id}: error result contains partial table metadata")
        when 'unsupported_no_descriptor'
          require_true(control.fetch('kind') == 'materialized_view' && control.fetch('engine') == 'MaterializedView',
            "#{id}: no-descriptor result is not a materialized view")
          require_true(control.fetch('metadata_ddl') == item.fetch('ddl'), "#{id}: no-descriptor raw DDL differs")
          require_true(control.fetch('error_class').nil? && control.fetch('error_message').nil?,
            "#{id}: no-descriptor result unexpectedly carries an error")
        else
          fail!("#{id}: unsupported control became available")
        end
      end

      negatives = @helper_result.fetch('resolver_negative_cases')
      require_true(negatives.map { |item| item.fetch('id') } == NEGATIVE_IDS, 'resolver-negative roster differs')
      negatives.each do |item|
        require_true(item.fetch('classification') == 'rejected' && item.fetch('resolved_name').nil? && item.fetch('resolved_uuid').nil?,
          "#{item.fetch('id')}: resolver did not fail closed")
        require_true(%w[CrystalClick::InvalidPartError CrystalClick::UnsupportedFormatError].include?(item.fetch('error_class')),
          "#{item.fetch('id')}: unexpected resolver rejection class")
      end

      projection = @helper_result.fetch('projection_control')
      require_true(projection.fetch('database') == MAIN_DB && projection.fetch('name') == 'projection_source' &&
        projection.fetch('kind') == 'table' && projection.fetch('engine') == 'MergeTree', 'ordinary projection control identity differs')
      require_true(projection.fetch('columns') == %w[k v], 'projection declaration leaked into columns')
      projection_pairs = projection.fetch('projections').map { |item| [item.fetch('name'), item.fetch('definition').gsub(/\s+/, ' ').strip] }
      require_true(projection_pairs == [['by_v', 'SELECT v, k ORDER BY v']], 'ordinary projection metadata differs')
      projected_metadata = stock_metadata(MAIN_DB, 'projection_source')
      require_true(projection.fetch('metadata_ddl') == projected_metadata.fetch('ddl'), 'projection-control DDL differs from stock metadata')
    end

    def expected_process_labels
      labels = %w[runtime-version-pin runtime-build-pin stock-bootstrap]
      labels.concat(VIEW_IDS.map { |id| "stock-create-#{id}" })
      labels.concat(CONTROL_IDS.map { |id| "stock-create-#{id}" })
      labels.concat(%w[stock-table-function-refusal stock-system-databases stock-system-tables crystal-helper])
      labels
    end

    def verify_process_roster
      labels = @recorder.records.map { |item| item.fetch('label') }
      require_true(labels.uniq.length == labels.length && labels.sort == expected_process_labels.sort, 'W228 process invocation roster differs')
      @recorder.records.each do |record|
        next if record.fetch('label') == 'stock-table-function-refusal'
        require_true(record.fetch('classification') == 'process_success' && record.fetch('exitstatus') == 0 &&
          !record.fetch('signaled') && !record.fetch('timed_out') && !record.fetch('spawn_error'), "W228 process failed: #{record.fetch('label')}")
      end
    end

    def write_summary(classification)
      return unless @root && File.directory?(@root) && !File.exist?(File.join(@root, 'summary.json'))
      summary = { 'format' => FORMAT_SUMMARY, 'classification' => classification,
        'success' => classification == 'paired_materialized_view_metadata_observed', 'error' => @fatal,
        'native_root' => @native_root, 'evidence_root' => @root, 'store_root' => @store,
        'source_pin' => @source_pin, 'runtime_pin' => @runtime_pin,
        'helper_sha256_expected' => @helper_sha_expected, 'helper_sha256_at_start' => @helper_sha_start,
        'helper_sha256_after_execute' => @helper_sha_after, 'helper_input_sha256' => @helper_input_sha,
        'counts' => { 'views_expected' => VIEW_IDS.length,
          'views_observed' => @helper_result && @helper_result.fetch('views', []).length,
          'stock_metadata_files' => @stock_observations && @stock_observations.fetch('metadata_files', []).length,
          'processes' => @recorder ? @recorder.records.length : 0 },
        'process_status_counts' => { 'success_exit0' => @recorder.records.count { |item| item.fetch('classification') == 'process_success' },
          'nonzero_or_signaled' => @recorder.records.count { |item| item.fetch('classification') == 'process_nonzero_or_signaled_exit' },
          'timeout' => @recorder.records.count { |item| item.fetch('classification') == 'process_timeout' },
          'spawn_failure' => @recorder.records.count { |item| item.fetch('classification') == 'spawn_failure' } } }
      write_json(File.join(@root, 'summary.json'), summary)
      write_json(File.join(@root, 'source_pin.json'), @source_pin) if @source_pin
    end

    def require_true(condition, message)
      RecheckMaterializedViewMetadataW228.require_true(condition, message)
    end

    def write_new(path, bytes)
      RecheckMaterializedViewMetadataW228.write_new(path, bytes)
    end

    def write_json(path, object)
      RecheckMaterializedViewMetadataW228.write_json(path, object)
    end

    def fail!(message)
      RecheckMaterializedViewMetadataW228.fail!(message)
    end
  end

  def main(argv)
    options = {}
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: ruby scripts/recheck_materialized_view_metadata_w228.rb --clickhouse BIN --helper HELPER --helper-sha256 HEX --native-root EMPTY_DIR --evidence-root EMPTY_DIR'
      opts.on('--clickhouse PATH') { |value| options[:clickhouse] = value }
      opts.on('--helper PATH') { |value| options[:helper] = value }
      opts.on('--helper-sha256 HEX') { |value| options[:helper_sha256] = value }
      opts.on('--native-root PATH') { |value| options[:native_root] = value }
      opts.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
    end
    parser.parse!(argv)
    require_true(argv.empty? && %i[clickhouse helper helper_sha256 native_root evidence_root].all? { |key| options.key?(key) }, parser.to_s)
    Probe.new(options).run
  rescue StandardError => error
    warn "W228 runner setup failure: #{error.class}: #{error.message}"
    false
  end
end

exit(RecheckMaterializedViewMetadataW228.main(ARGV) ? 0 : 1) if $PROGRAM_NAME == __FILE__
