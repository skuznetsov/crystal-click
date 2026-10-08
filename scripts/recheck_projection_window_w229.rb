#!/usr/bin/env ruby
# Paired native/library projection-window probe over a separately generated
# W217 stock fixture. This runner consumes a prebuilt Crystal helper.

require 'digest'
require 'json'
require 'open3'
require 'optparse'
require_relative 'recheck_aggregate_recursive_w224'

module RecheckProjectionWindowW229
  extend self

  REPO_ROOT = '/Users/sergey/Projects/Crystal/crystal-click'.freeze
  SOURCE_ROOT = '/Users/sergey/SrcArchives/clickhouse-2026-10-07-depth1'.freeze
  SOURCE_REVISION = '0ca8150d9b1d0886edb2e3b4ab65eebb768d0357'.freeze
  SOURCE_FILES = {
    'src/TableFunctions/TableFunctionProjection.cpp' => 'dfbfcfed90a53783f8d7ce39b941b81573d798d57714600db3616f1f4a26f508',
    'src/Storages/System/StorageSystemProjectionParts.cpp' => '4fb8e8dffa71361c3aeb901a6c3e30226ecc1c3fb917105f9b1dea523ac411a5',
    'src/Storages/System/StorageSystemProjectionPartsColumns.cpp' => '5e239e54d422cd3c06150e2aa83926dac81b5de8ba8f9b2c2597d750aa9fa59b',
    'src/Storages/MergeTree/IMergeTreeDataPart.h' => '5f6efa47dcece1a1506b87f10d0370eecc1f3665be031702bec92d3e8d82e0ad',
    'src/Storages/MergeTree/MergeTreeDataWriter.cpp' => '7da96e0583100c60c5c09a3a3f099d99367d8fbb3c4cb03e7bad66e571b8b751',
  }.freeze
  PINNED_CODE_FILES = {
    'src/crystal_click/wide_part_table.cr' => '813846246ec25f252f983cf7ceb9ac0dfbc36094ac182d591afa88e22e8de09f',
    'src/crystal_click/offline_table.cr' => '672b3cf27081e2b66de296ad715d1a3392d5240f87f8eea7bc1cf889f55243c7',
    'src/crystal_click/offline_table/projection_reader_admission.cr' => '6c33011e0caac5c6ffc54229fdec82da9d5683722e71242185d57d047e97eb06',
    'src/crystal_click/wide_part_table/wide_part_table_batch.cr' => '56056e99bb1593f295a83c9ea16a597a1030b1ff17c0f1e49ab92567dc80ce08',
    'scripts/recheck_aggregate_recursive_w224.rb' => 'd1b7ad1c63ad265fce05a6d9b0b241e1d659f60eb1b533215a78f944a28f0831',
  }.freeze
  CLICKHOUSE_BIN = '/private/tmp/crystal-click-w216-runtime-recovery.DmL9Kw/clickhouse-stripped'.freeze
  CLICKHOUSE_SHA256 = 'bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2'.freeze
  CLICKHOUSE_VERSION = '26.10.1.1201'.freeze
  CLICKHOUSE_BUILD = 'd9bcb5ab007f0f6299f7f973f2642245bab3d028'.freeze
  DATABASE = 'w217_specialized_projection'.freeze
  PARENT_PARTS = %w[all_1_1_0 all_2_2_0].freeze
  PROFILES = {
    'whole_json' => { 'table' => 'whole_json', 'kind' => 'object', 'columns' => %w[pk payload], 'child_rows' => 6,
      'child_schema' => [['pk', 'UInt64'], ['payload', 'JSON(max_dynamic_types=0, max_dynamic_paths=0, t UInt64)']] },
    'array_json' => { 'table' => 'array_json', 'kind' => 'array_object', 'columns' => %w[pk a], 'child_rows' => 6,
      'child_schema' => [['pk', 'UInt64'], ['a', 'Array(JSON(max_dynamic_types=0, max_dynamic_paths=0, t UInt8))']] },
    'recursive_json' => { 'table' => 'recursive_json', 'kind' => 'recursive', 'columns' => %w[pk payload], 'child_rows' => 6,
      'child_schema' => [['pk', 'UInt64'], ['payload', 'Tuple(doc JSON(max_dynamic_types=0, max_dynamic_paths=0, t UInt8), n UInt64)']] },
    'dynamic_root' => { 'table' => 'dynamic_root', 'kind' => 'dynamic', 'columns' => %w[pk payload], 'child_rows' => 6,
      'child_schema' => [['pk', 'UInt64'], ['payload', 'Dynamic(max_types=1)']] },
    'dynamic_array' => { 'table' => 'dynamic_array', 'kind' => 'dynamic_array', 'columns' => %w[pk wrapped], 'child_rows' => 6,
      'child_schema' => [['pk', 'UInt64'], ['wrapped', 'Array(Dynamic(max_types=1))']] },
    'count' => { 'table' => 'count_parent', 'kind' => 'count', 'columns' => ['intDiv(pk, 2)', 'count()'], 'child_rows' => 3,
      'child_schema' => [['intDiv(pk, 2)', 'UInt64'], ['count()', 'AggregateFunction(count)']] },
  }.freeze
  TIMEOUT_SECONDS = 30
  TERM_GRACE_SECONDS = 2
  MEMORY_LIMIT_BYTES = 536_870_912
  MAX_TREE_ENTRIES = 4_096
  MAX_TREE_BYTES = 64 * 1024 * 1024
  MAX_TREE_DEPTH = 32

  def fail!(message)
    raise ArgumentError, message
  end

  def require_true(condition, message)
    fail!(message) unless condition
  end

  def sha256_file(path)
    Digest::SHA256.file(path).hexdigest
  end

  def write_new(path, bytes)
    File.open(path, 'wbx', 0o600) { |file| file.write(bytes) }
  rescue Errno::EEXIST
    fail!("refusing to overwrite W229 evidence: #{path}")
  end

  def write_json(path, object)
    write_new(path, JSON.pretty_generate(object) + "\n")
  end

  def plain_file!(path, label, executable: false)
    require_true(!File.symlink?(path) && File.file?(path), "#{label} must be a plain regular file: #{path}")
    require_true(File.realpath(path) == File.expand_path(path), "#{label} is not canonical: #{path}")
    require_true(!executable || File.executable?(path), "#{label} is not executable: #{path}")
    path
  end

  def plain_dir!(path, label)
    require_true(!File.symlink?(path) && File.directory?(path), "#{label} must be a plain directory: #{path}")
    require_true(File.realpath(path) == File.expand_path(path), "#{label} is not canonical: #{path}")
    path
  end

  def validate_root(path, prefix, label, empty: false)
    full = File.expand_path(path)
    plain_dir!(full, label)
    require_true(File.dirname(full) == File.realpath('/private/tmp') && File.basename(full).start_with?(prefix),
      "#{label} must be a direct /private/tmp child with prefix #{prefix}")
    require_true(Dir.children(full).empty?, "#{label} must be empty") if empty
    full
  end

  def validate_binary!(path)
    full = File.expand_path(path)
    plain_file!(full, 'ClickHouse binary', executable: true)
    require_true(full == CLICKHOUSE_BIN, "ClickHouse binary path differs from pin: #{full}")
    actual = sha256_file(full)
    require_true(actual == CLICKHOUSE_SHA256, "ClickHouse binary SHA-256 differs: #{actual}")
    full
  end

  def validate_helper!(path, expected_sha)
    require_true(/\A[0-9a-f]{64}\z/.match?(expected_sha), 'helper SHA-256 must be 64 lowercase hex characters')
    full = File.expand_path(path)
    plain_file!(full, 'prebuilt Crystal helper', executable: true)
    actual = sha256_file(full)
    require_true(actual == expected_sha, "helper SHA-256 differs from supplied pin: #{actual}")
    [full, actual]
  end

  def source_manifest
    entries = SOURCE_FILES.map do |relative, expected|
      path = File.join(SOURCE_ROOT, relative)
      plain_file!(path, "pinned source #{relative}")
      actual = sha256_file(path)
      require_true(actual == expected, "pinned ClickHouse source changed: #{relative} #{actual}")
      { 'path' => relative, 'sha256' => actual }
    end
    { 'source_root' => SOURCE_ROOT, 'revision' => SOURCE_REVISION, 'files' => entries }
  end

  def validate_fixture!(root)
    full = File.expand_path(root)
    plain_dir!(full, 'W217 fixture root')
    require_true(File.dirname(full) == File.realpath('/private/tmp') && File.basename(full).start_with?('crystal-click-w229-fixtures-'),
      'fixture root must be a direct W229 fixture child of /private/tmp')
    stores = File.join(full, 'stores')
    plain_dir!(stores, 'W217 stores root')
    require_true(Dir.children(stores).sort == PROFILES.keys.sort, 'W217 fixture store roster differs')
    result = JSON.parse(File.binread(plain_file!(File.join(full, 'result.json'), 'W217 result.json')))
    require_true(result['format'] == 'w217_specialized_projection_result_v1', 'W217 result format differs')
    cases = result.fetch('cases')
    require_true(cases.map { |entry| entry.fetch('case') }.sort == PROFILES.keys.sort && cases.all? { |entry| entry.fetch('success') == true },
      'W217 stock/library fixture result is not six-case successful')
    pre = JSON.parse(File.binread(plain_file!(File.join(full, 'source_manifest.pre.json'), 'W217 source manifest pre')))
    post = JSON.parse(File.binread(plain_file!(File.join(full, 'source_manifest.post.json'), 'W217 source manifest post')))
    require_true(pre == post && result['source_manifest_unchanged'] == true, 'W217 source manifest changed during fixture generation')
    PROFILES.each_key do |id|
      store = File.join(stores, id)
      plain_dir!(store, "W217 store #{id}")
      input = JSON.parse(File.binread(plain_file!(File.join(full, 'cases', id, 'input_manifest.json'), "W217 #{id} input")))
      require_true(input['case'] == id && input['store'] == store && input['projection'] == 'p', "W217 #{id} input identity differs")
      result_dir = File.join(full, 'results', id)
      physical_pre = JSON.parse(File.binread(plain_file!(File.join(result_dir, 'physical_inputs.pre.json'), "W217 #{id} physical pre")))
      physical_post = JSON.parse(File.binread(plain_file!(File.join(result_dir, 'physical_inputs.post.json'), "W217 #{id} physical post")))
      require_true(physical_pre == physical_post && physical_pre['complete'] == true, "W217 #{id} physical manifest is incomplete or changed")
      require_true(physical_pre['parent_parts'].map { |part| File.basename(part.fetch('canonical_path')) }.sort == PARENT_PARTS.sort,
        "W217 #{id} parent part roster differs")
    end
    full
  end

  def manifest_profile_tree(root, id)
    store = File.join(root, 'stores', id)
    pre_path = File.join(root, 'results', id, 'physical_inputs.pre.json')
    source = JSON.parse(File.binread(pre_path))
    files = []
    entry_count = 0
    total_bytes = 0
    source.fetch('parent_parts').sort_by { |part| part.fetch('name') }.each do |parent|
      name = parent.fetch('name')
      parent_path = parent.fetch('canonical_path')
      plain_dir!(parent_path, "#{id}/#{name} parent part")
      require_true(File.dirname(parent_path).start_with?(store + '/') && File.basename(parent_path) == name,
        "#{id}/#{name} parent path escaped its store")
      walk = lambda do |path, depth|
        require_true(depth <= MAX_TREE_DEPTH, "#{id}/#{name} physical tree exceeds depth cap")
        Dir.children(path).sort.each do |child_name|
          entry_count += 1
          require_true(entry_count <= MAX_TREE_ENTRIES, "#{id} physical tree exceeds entry cap")
          child = File.join(path, child_name)
          require_true(!File.symlink?(child), "#{id} physical tree contains symlink: #{child}")
          canonical = File.realpath(child)
          require_true(canonical == File.expand_path(child) && canonical.start_with?(parent_path + '/'),
            "#{id} physical path escaped parent: #{child}")
          if File.directory?(child)
            walk.call(child, depth + 1)
          elsif File.file?(child)
            size = File.size(child)
            total_bytes += size
            require_true(total_bytes <= MAX_TREE_BYTES, "#{id} physical tree exceeds byte cap")
            files << { 'parent' => name, 'relative_path' => canonical.delete_prefix(parent_path + '/'),
              'size_bytes' => size, 'sha256' => sha256_file(child) }
          else
            fail!("#{id} physical tree contains unsupported entry: #{child}")
          end
        end
      end
      walk.call(parent_path, 0)
    end
    require_true(files.any? { |file| file['relative_path'].start_with?('p.proj/') }, "#{id} manifest has no projection child files")
    { 'profile' => id, 'store' => store, 'parents' => PARENT_PARTS, 'entry_count' => entry_count,
      'file_count' => files.size, 'total_bytes' => total_bytes, 'files' => files.sort_by { |file| [file['parent'], file['relative_path']] } }
  end

  def fixture_manifest(root)
    PROFILES.keys.map { |id| manifest_profile_tree(root, id) }
  end

  def terminate_child(waiter)
    return unless waiter && waiter.alive?
    Process.kill('TERM', waiter.pid)
    waiter.join(TERM_GRACE_SECONDS) || Process.kill('KILL', waiter.pid)
  rescue Errno::ESRCH
    nil
  ensure
    waiter.join if waiter
  end

  class Recorder
    def initialize(root, binary)
      @binary = binary
      @records = []
      @delegate = RecheckAggregateRecursiveW224::Recorder.new(root, binary)
    end

    attr_reader :records

    def run(label, store, sql)
      argv = [@binary, 'local', '--multiquery', '--path', store, '--session_timezone=UTC', '--max_threads=1',
        '--max_insert_threads=1', '--max_execution_time=30', "--max_memory_usage=#{MEMORY_LIMIT_BYTES}",
        '--print_pretty_type_names=0', '--query', sql]
      raw = @delegate.run(label, store, sql, timeout: TIMEOUT_SECONDS, argv: argv)
      stdout = raw.fetch('stdout')
      stderr = raw.fetch('stderr')
      record = raw.reject { |key, _| key == 'stdout' || key == 'stderr' }.merge(
        'sql_sha256' => Digest::SHA256.hexdigest(sql.b),
        'stdout_sha256' => Digest::SHA256.hexdigest(stdout),
        'stderr_sha256' => Digest::SHA256.hexdigest(stderr),
      )
      @records << record
      raw.merge(record)
    end
  end

  def value_expressions(profile)
    case profile.fetch('kind')
    when 'object' then ['toString(pk)', 'toString(payload.t)']
    when 'array_object'
      ['toString(pk)', 'toString(length(a))', "if(length(a)=0, '-', arrayStringConcat(arrayMap(x -> toString(x.t), a), ','))"]
    when 'recursive' then ['toString(pk)', 'toString(payload.doc.t)', 'toString(payload.n)']
    when 'dynamic' then ['toString(pk)', 'dynamicType(payload)', "ifNull(toString(dynamicElement(payload, 'UInt64')), '')"]
    when 'dynamic_array'
      ['toString(pk)', 'toString(length(wrapped))', "if(length(wrapped)=0, '-', arrayStringConcat(arrayMap(x -> dynamicType(x), wrapped), ','))",
       "if(length(wrapped)=0, '-', arrayStringConcat(arrayMap(x -> ifNull(toString(dynamicElement(x, 'UInt64')), ''), wrapped), ','))"]
    when 'count' then ['toString(`intDiv(pk, 2)`)', 'toString(finalizeAggregation(`count()`))']
    else fail!("unhandled profile kind #{profile.fetch('kind')}")
    end
  end

  def window_matrix(profile)
    child_rows = profile.fetch('child_rows')
    total = child_rows * PARENT_PARTS.size
    middle_start, middle_length = profile.fetch('kind') == 'count' ? [1, 3] : [2, 4]
    [
      ['full', 0, total], ['middle', middle_start, middle_length], ['cross_child', child_rows - 1, 3],
      ['eof', total, 2], ['past_eof', total + 1, 1],
    ]
  end

  def query_for_window(profile, name, start_row, max_rows)
    fields = ['_part', 'toString(_part_offset)'] + value_expressions(profile)
    "SELECT #{fields.join(', ')} FROM mergeTreeProjection('#{DATABASE}', '#{profile.fetch('table')}', 'p') " \
      "ORDER BY _part, _part_offset LIMIT #{start_row}, #{max_rows} FORMAT TSVRaw;"
  end

  def table_for_label(label)
    return PROFILES.fetch(PROFILES.keys.first).fetch('table') if label.start_with?('runtime-')
    id = PROFILES.keys.find do |candidate|
      label == "check-#{candidate}" || label.end_with?("-#{candidate}") || label.start_with?("window-#{candidate}-")
    end
    fail!("cannot resolve profile for invocation #{label}") unless id
    PROFILES.fetch(id).fetch('table')
  end

  def native_query(label, query)
    "SYSTEM STOP MERGES #{DATABASE}.#{table_for_label(label)}; #{query}"
  end

  def expected_invocations
    labels = ['runtime-version-pin', 'runtime-build-pin']
    PROFILES.each_key do |id|
      labels.concat(["check-#{id}", "parent-schema-#{id}", "parent-parts-#{id}", "projection-parts-#{id}", "projection-columns-#{id}"])
      window_matrix(PROFILES.fetch(id)).each { |name, _, _| labels << "window-#{id}-#{name}" }
    end
    labels
  end

  def run_helper(helper, fixture_root, evidence_root, expected_sha)
    base = File.join(evidence_root, 'helper')
    argv = [helper, '--fixture-root', fixture_root]
    write_new(base + '.argv.json', JSON.pretty_generate({ 'argv' => argv, 'helper_sha256' => expected_sha }) + "\n")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    stdout = ''.b
    stderr = ''.b
    status = nil
    spawn_error = nil
    timed_out = false
    stdin = out = err = waiter = nil
    readers = []
    begin
      stdin, out, err, waiter = Open3.popen3(*argv)
      [stdin, out, err].each(&:binmode)
      readers = [Thread.new { out.read }, Thread.new { err.read }]
      stdin.close
      unless waiter.join(600)
        timed_out = true
        terminate_child(waiter)
      end
      status = waiter.value
      stdout = readers[0].value
      stderr = readers[1].value
    rescue StandardError => error
      spawn_error = "#{error.class}: #{error.message}"
    ensure
      terminate_child(waiter) if waiter && waiter.alive?
      [stdin, out, err].compact.each { |pipe| pipe.close unless pipe.closed? rescue nil }
      readers.each(&:join)
    end
    classification = if spawn_error then 'spawn_failure' elsif timed_out then 'process_timeout' elsif status&.success? then 'process_success' else 'process_nonzero_or_signaled_exit' end
    record = { 'classification' => classification, 'exitstatus' => status&.exitstatus, 'signaled' => status&.signaled? || false,
      'termsig' => status&.termsig, 'timed_out' => timed_out, 'duration_ms' => ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round,
      'spawn_error' => spawn_error, 'stdout_bytes' => stdout.bytesize, 'stderr_bytes' => stderr.bytesize }
    write_new(base + '.stdout', stdout)
    write_new(base + '.stderr', stderr)
    write_new(base + '.status.json', JSON.pretty_generate(record) + "\n")
    record.merge('stdout_sha256' => Digest::SHA256.hexdigest(stdout), 'stderr_sha256' => Digest::SHA256.hexdigest(stderr))
  end

  def run(options)
    fixture_root = validate_fixture!(options.fetch(:fixture_root))
    evidence_root = validate_root(options.fetch(:evidence_root), 'crystal-click-w229-native-', 'W229 evidence root', empty: true)
    binary = validate_binary!(options.fetch(:clickhouse, CLICKHOUSE_BIN))
    helper, helper_sha = validate_helper!(options.fetch(:helper), options.fetch(:helper_sha256))
    runner_path = File.realpath(__FILE__)
    auditor_path = File.join(REPO_ROOT, 'scripts/check_projection_window_evidence_w229.rb')
    oracle_path = File.join(REPO_ROOT, 'scripts/check_projection_window_w229.cr')
    [runner_path, auditor_path, oracle_path].each { |path| plain_file!(path, 'W229 implementation source') }
    PINNED_CODE_FILES.each do |relative, expected|
      path = File.join(REPO_ROOT, relative)
      plain_file!(path, "pinned production source #{relative}")
      require_true(sha256_file(path) == expected, "pinned production source changed: #{relative}")
    end
    pinned_paths = PINNED_CODE_FILES.keys.map { |relative| File.join(REPO_ROOT, relative) }
    code_paths = [runner_path, auditor_path, oracle_path] + pinned_paths
    code_pins = code_paths.to_h { |path| [path.delete_prefix(REPO_ROOT + '/'), sha256_file(path)] }
    helper_sha_start = sha256_file(helper)
    require_true(helper_sha_start == helper_sha, 'prebuilt helper changed after validation')
    source_pre = source_manifest
    physical_pre = fixture_manifest(fixture_root)
    write_json(File.join(evidence_root, 'source_pin.pre.json'), source_pre)
    write_json(File.join(evidence_root, 'fixture_physical.pre.json'), { 'format' => 'w229_fixture_physical_v1', 'profiles' => physical_pre })
    %w[invocations].each { |name| Dir.mkdir(File.join(evidence_root, name), 0o700) }
    recorder = Recorder.new(evidence_root, binary)
    stores = File.join(fixture_root, 'stores')
    version_label = 'runtime-version-pin'
    version = recorder.run(version_label, File.join(stores, PROFILES.keys.first), native_query(version_label, 'SELECT version() FORMAT TSVRaw;'))
    require_true(version.fetch('classification') == 'process_success' && File.binread(version.fetch('path') + '.stdout').strip == CLICKHOUSE_VERSION,
      'runtime version pin failed')
    build_sql = "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw;"
    build_label = 'runtime-build-pin'
    build = recorder.run(build_label, File.join(stores, PROFILES.keys.first), native_query(build_label, build_sql))
    require_true(build.fetch('classification') == 'process_success' && File.binread(build.fetch('path') + '.stdout').strip == "VERSION_GITHASH=#{CLICKHOUSE_BUILD}",
      'runtime build pin failed')

    PROFILES.each do |id, profile|
      store = File.join(stores, id)
      table = profile.fetch('table')
      check_label = "check-#{id}"
      check = recorder.run(check_label, store, native_query(check_label, "CHECK TABLE #{DATABASE}.#{table} FORMAT TSVRaw;"))
      require_true(check.fetch('classification') == 'process_success', "CHECK TABLE failed for #{id}")
      schema_sql = "SELECT name, type FROM system.columns WHERE database='#{DATABASE}' AND table='#{table}' ORDER BY position FORMAT TSVRaw;"
      schema_label = "parent-schema-#{id}"
      schema = recorder.run(schema_label, store, native_query(schema_label, schema_sql))
      require_true(schema.fetch('classification') == 'process_success', "parent schema query failed for #{id}")
      parent_sql = "SELECT name, toString(rows), toString(marks), part_type FROM system.parts WHERE database='#{DATABASE}' AND table='#{table}' AND active ORDER BY min_block_number FORMAT TSVRaw;"
      parent_label = "parent-parts-#{id}"
      parents = recorder.run(parent_label, store, native_query(parent_label, parent_sql))
      require_true(parents.fetch('classification') == 'process_success', "parent axes query failed for #{id}")
      child_sql = "SELECT parent_name, name, toString(rows), toString(marks), toString(parent_rows), toString(parent_marks), part_type, parent_part_type FROM system.projection_parts WHERE database='#{DATABASE}' AND table='#{table}' AND name='p' AND active ORDER BY parent_name FORMAT TSVRaw;"
      child_label = "projection-parts-#{id}"
      children = recorder.run(child_label, store, native_query(child_label, child_sql))
      require_true(children.fetch('classification') == 'process_success', "projection child axes query failed for #{id}")
      columns_sql = "SELECT parent_name, name, column, type, toString(column_position) FROM system.projection_parts_columns WHERE database='#{DATABASE}' AND table='#{table}' AND name='p' AND active ORDER BY parent_name, column_position FORMAT TSVRaw;"
      columns_label = "projection-columns-#{id}"
      columns = recorder.run(columns_label, store, native_query(columns_label, columns_sql))
      require_true(columns.fetch('classification') == 'process_success', "projection child schema query failed for #{id}")
      window_matrix(profile).each do |name, start_row, max_rows|
        window_label = "window-#{id}-#{name}"
        record = recorder.run(window_label, store, native_query(window_label, query_for_window(profile, name, start_row, max_rows)))
        require_true(record.fetch('classification') == 'process_success', "native projection window query failed: #{id}/#{name}")
      end
    end

    helper_record = run_helper(helper, fixture_root, evidence_root, helper_sha)
    require_true(helper_record.fetch('classification') == 'process_success', 'library helper process failed')
    helper_json = JSON.parse(File.binread(File.join(evidence_root, 'helper.stdout')))
    require_true(helper_json['format'] == 'projection_window_w229_helper_v1' && helper_json['fixture_root'] == fixture_root,
      'library helper JSON identity differs')
    physical_post = fixture_manifest(fixture_root)
    source_post = source_manifest
    require_true(physical_pre == physical_post, 'W217 physical parent/child files changed during W229 reads')
    require_true(source_pre == source_post, 'pinned ClickHouse source files changed during W229 run')
    require_true(sha256_file(helper) == helper_sha_start, 'prebuilt helper changed during W229 run')
    write_json(File.join(evidence_root, 'source_pin.post.json'), source_post)
    write_json(File.join(evidence_root, 'fixture_physical.post.json'), { 'format' => 'w229_fixture_physical_v1', 'profiles' => physical_post })
    require_true(code_pins == code_paths.to_h { |path| [path.delete_prefix(REPO_ROOT + '/'), sha256_file(path)] },
      'W229 source scripts changed during native/helper work')
    expected = expected_invocations
    labels = recorder.records.map { |entry| entry.fetch('label') }
    require_true(labels == expected, "native invocation roster differs: #{labels.inspect}")
    write_json(File.join(evidence_root, 'result.json'), {
      'format' => 'projection_window_w229_result_v1', 'fixture_root' => fixture_root,
      'clickhouse_binary' => binary, 'clickhouse_sha256' => CLICKHOUSE_SHA256,
      'clickhouse_version' => CLICKHOUSE_VERSION, 'clickhouse_build' => CLICKHOUSE_BUILD,
      'stock_source_revision' => SOURCE_REVISION, 'stock_source_manifest' => source_pre,
      'helper_path' => helper, 'helper_sha256' => helper_sha, 'helper_status' => helper_record,
      'helper_json_sha256' => Digest::SHA256.file(File.join(evidence_root, 'helper.stdout')).hexdigest,
      'code_pins' => code_pins, 'physical_pre_sha256' => Digest::SHA256.hexdigest(JSON.generate(physical_pre)),
      'physical_post_sha256' => Digest::SHA256.hexdigest(JSON.generate(physical_post)),
      'source_unchanged' => source_pre == source_post, 'fixture_physical_unchanged' => physical_pre == physical_post,
      'invocation_labels' => labels, 'invocations' => recorder.records,
      'scope' => 'bounded direct projection-child read windows and library window consumers; no optimizer, write path, server lifecycle, or performance claim',
    })
    puts "W229 paired projection windows captured: #{labels.size} raw ClickHouse invocations; evidence=#{evidence_root}"
    true
  rescue StandardError => error
    warn "W229 runner failure (process refusal is retained as raw evidence): #{error.class}: #{error.message}"
    begin
      path = File.join(options.fetch(:evidence_root), 'runner_failure.json')
      write_json(path, { 'format' => 'projection_window_w229_failure_v1', 'error_class' => error.class.name, 'error' => error.message })
    rescue StandardError
      # Preserve the original runner diagnostic if an incomplete root prevents a failure record.
    end
    false
  end
end

options = {}
OptionParser.new do |parser|
  parser.banner = 'Usage: ruby scripts/recheck_projection_window_w229.rb --fixture-root ROOT --helper PATH --helper-sha256 SHA --evidence-root EMPTY_ROOT [--clickhouse PATH]'
  parser.on('--fixture-root PATH') { |value| options[:fixture_root] = value }
  parser.on('--helper PATH') { |value| options[:helper] = value }
  parser.on('--helper-sha256 SHA') { |value| options[:helper_sha256] = value }
  parser.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
  parser.on('--clickhouse PATH') { |value| options[:clickhouse] = value }
end.parse!
%i[fixture_root helper helper_sha256 evidence_root].each do |key|
  RecheckProjectionWindowW229.fail!("--#{key.to_s.tr('_', '-')} is required") unless options.key?(key)
end
exit(RecheckProjectionWindowW229.run(options) ? 0 : 1)
