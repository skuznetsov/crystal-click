#!/usr/bin/env ruby
# Independent, read-only audit of W229 raw ClickHouse and library evidence.
# This script does not invoke Crystal, ClickHouse, or the runner.

require 'digest'
require 'json'

module CheckProjectionWindowEvidenceW229
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
    'whole_json' => { 'table' => 'whole_json', 'kind' => 'object', 'child_rows' => 6,
      'source_schema' => [['pk', 'UInt64'], ['payload', 'JSON(max_dynamic_types=0, max_dynamic_paths=0, t UInt64)']],
      'child_schema' => [['pk', 'UInt64'], ['payload', 'JSON(max_dynamic_types=0, max_dynamic_paths=0, t UInt64)']],
      'rows' => {
        'all_1_1_0' => [['101', '7'], ['102', '0'], ['103', '8'], ['104', '9'], ['105', '10'], ['106', '11']],
        'all_2_2_0' => [['201', '21'], ['202', '22'], ['203', '23'], ['204', '24'], ['205', '25'], ['206', '26']],
      } },
    'array_json' => { 'table' => 'array_json', 'kind' => 'array_object', 'child_rows' => 6,
      'source_schema' => [['pk', 'UInt64'], ['a', 'Array(JSON(max_dynamic_types=0, max_dynamic_paths=0, t UInt8))']],
      'child_schema' => [['pk', 'UInt64'], ['a', 'Array(JSON(max_dynamic_types=0, max_dynamic_paths=0, t UInt8))']],
      'rows' => {
        'all_1_1_0' => [['101', '1', '7'], ['102', '0', '-'], ['103', '2', '8,9'], ['104', '2', '0,1'], ['105', '3', '10,11,12'], ['106', '1', '13']],
        'all_2_2_0' => [['201', '0', '-'], ['202', '1', '21'], ['203', '2', '22,23'], ['204', '1', '24'], ['205', '0', '-'], ['206', '2', '26,27']],
      } },
    'recursive_json' => { 'table' => 'recursive_json', 'kind' => 'recursive', 'child_rows' => 6,
      'source_schema' => [['pk', 'UInt64'], ['payload', 'Tuple(doc JSON(max_dynamic_types=0, max_dynamic_paths=0, t UInt8), n UInt64)']],
      'child_schema' => [['pk', 'UInt64'], ['payload', 'Tuple(doc JSON(max_dynamic_types=0, max_dynamic_paths=0, t UInt8), n UInt64)']],
      'rows' => {
        'all_1_1_0' => [['101', '1', '10'], ['102', '2', '20'], ['103', '3', '30'], ['104', '4', '40'], ['105', '5', '50'], ['106', '6', '60']],
        'all_2_2_0' => [['201', '21', '210'], ['202', '22', '220'], ['203', '23', '230'], ['204', '24', '240'], ['205', '25', '250'], ['206', '26', '260']],
      } },
    'dynamic_root' => { 'table' => 'dynamic_root', 'kind' => 'dynamic', 'child_rows' => 6,
      'source_schema' => [['pk', 'UInt64'], ['payload', 'Dynamic(max_types=1)']],
      'child_schema' => [['pk', 'UInt64'], ['payload', 'Dynamic(max_types=1)']],
      'rows' => {
        'all_1_1_0' => [['101', 'UInt64', '7'], ['102', 'UInt64', '0'], ['103', 'UInt64', '8'], ['104', 'UInt64', '9'], ['105', 'UInt64', '10'], ['106', 'UInt64', '11']],
        'all_2_2_0' => [['201', 'UInt64', '21'], ['202', 'UInt64', '22'], ['203', 'UInt64', '23'], ['204', 'UInt64', '24'], ['205', 'UInt64', '25'], ['206', 'UInt64', '26']],
      } },
    'dynamic_array' => { 'table' => 'dynamic_array', 'kind' => 'dynamic_array', 'child_rows' => 6,
      'source_schema' => [['pk', 'UInt64'], ['wrapped', 'Array(Dynamic(max_types=1))']],
      'child_schema' => [['pk', 'UInt64'], ['wrapped', 'Array(Dynamic(max_types=1))']],
      'rows' => {
        'all_1_1_0' => [['101', '1', 'UInt64', '7'], ['102', '0', '-', '-'], ['103', '2', 'UInt64,UInt64', '8,9'], ['104', '2', 'UInt64,UInt64', '0,1'], ['105', '3', 'UInt64,UInt64,UInt64', '10,11,12'], ['106', '1', 'UInt64', '13']],
        'all_2_2_0' => [['201', '0', '-', '-'], ['202', '1', 'UInt64', '21'], ['203', '2', 'UInt64,UInt64', '22,23'], ['204', '1', 'UInt64', '24'], ['205', '0', '-', '-'], ['206', '2', 'UInt64,UInt64', '26,27']],
      } },
    'count' => { 'table' => 'count_parent', 'kind' => 'count', 'child_rows' => 3,
      'source_schema' => [['pk', 'UInt64']],
      'child_schema' => [['intDiv(pk, 2)', 'UInt64'], ['count()', 'AggregateFunction(count)']],
      'rows' => { 'all_1_1_0' => [['50', '2'], ['51', '2'], ['52', '2']], 'all_2_2_0' => [['100', '2'], ['101', '2'], ['102', '2']] } },
  }.freeze
  TREE_ENTRY_CAP = 4_096
  TREE_BYTE_CAP = 64 * 1024 * 1024
  TREE_DEPTH_CAP = 32
  MEMORY_LIMIT_BYTES = 536_870_912
  TIMEOUT_SECONDS = 30

  def assert!(condition, message)
    raise "W229 AUDIT FAIL: #{message}" unless condition
  end

  def sha256_file(path)
    Digest::SHA256.file(path).hexdigest
  end

  def plain_file!(path, label, executable: false)
    assert!(!File.symlink?(path) && File.file?(path), "#{label} is not a plain file: #{path}")
    assert!(File.realpath(path) == File.expand_path(path), "#{label} is not canonical: #{path}")
    assert!(!executable || File.executable?(path), "#{label} is not executable: #{path}")
    path
  end

  def plain_dir!(path, label)
    assert!(!File.symlink?(path) && File.directory?(path), "#{label} is not a plain directory: #{path}")
    assert!(File.realpath(path) == File.expand_path(path), "#{label} is not canonical: #{path}")
    path
  end

  def read_json(path, label)
    JSON.parse(File.binread(plain_file!(path, label)))
  rescue JSON::ParserError => error
    raise "W229 AUDIT FAIL: malformed #{label}: #{error.message}"
  end

  def root_path!(path)
    full = File.expand_path(path)
    plain_dir!(full, 'W229 evidence root')
    assert!(File.dirname(full) == File.realpath('/private/tmp') && File.basename(full).start_with?('crystal-click-w229-native-'),
      'W229 evidence root must be a direct bounded /private/tmp child')
    full
  end

  def window_matrix(profile)
    child_rows = profile.fetch('child_rows')
    total = child_rows * PARENT_PARTS.size
    middle_start, middle_length = profile.fetch('kind') == 'count' ? [1, 3] : [2, 4]
    [['full', 0, total], ['middle', middle_start, middle_length], ['cross_child', child_rows - 1, 3],
     ['eof', total, 2], ['past_eof', total + 1, 1]]
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
    else raise "unknown profile kind #{profile.fetch('kind')}"
    end
  end

  def query_for_window(profile, start_row, max_rows)
    fields = ['_part', 'toString(_part_offset)'] + value_expressions(profile)
    "SELECT #{fields.join(', ')} FROM mergeTreeProjection('#{DATABASE}', '#{profile.fetch('table')}', 'p') " \
      "ORDER BY _part, _part_offset LIMIT #{start_row}, #{max_rows} FORMAT TSVRaw;"
  end

  def expected_labels
    labels = ['runtime-version-pin', 'runtime-build-pin']
    PROFILES.each do |id, profile|
      labels.concat(["check-#{id}", "parent-schema-#{id}", "parent-parts-#{id}", "projection-parts-#{id}", "projection-columns-#{id}"])
      window_matrix(profile).each { |name, _, _| labels << "window-#{id}-#{name}" }
    end
    labels
  end

  def expected_sql(label)
    case label
    when 'runtime-version-pin' then 'SELECT version() FORMAT TSVRaw;'
    when 'runtime-build-pin' then "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw;"
    else
      prefix, id = label.split('-', 2)
      if prefix == 'check'
        profile = PROFILES.fetch(id)
        "CHECK TABLE #{DATABASE}.#{profile.fetch('table')} FORMAT TSVRaw;"
      elsif prefix == 'parent'
        subkind, profile_id = id.split('-', 2)
        profile = PROFILES.fetch(profile_id)
        case subkind
        when 'schema'
          "SELECT name, type FROM system.columns WHERE database='#{DATABASE}' AND table='#{profile.fetch('table')}' ORDER BY position FORMAT TSVRaw;"
        when 'parts'
          "SELECT name, toString(rows), toString(marks), part_type FROM system.parts WHERE database='#{DATABASE}' AND table='#{profile.fetch('table')}' AND active ORDER BY min_block_number FORMAT TSVRaw;"
        else raise "unexpected parent invocation label: #{label}"
        end
      elsif prefix == 'projection'
        subkind, profile_id = id.split('-', 2)
        profile = PROFILES.fetch(profile_id)
        case subkind
        when 'parts'
          "SELECT parent_name, name, toString(rows), toString(marks), toString(parent_rows), toString(parent_marks), part_type, parent_part_type FROM system.projection_parts WHERE database='#{DATABASE}' AND table='#{profile.fetch('table')}' AND name='p' AND active ORDER BY parent_name FORMAT TSVRaw;"
        when 'columns'
          "SELECT parent_name, name, column, type, toString(column_position) FROM system.projection_parts_columns WHERE database='#{DATABASE}' AND table='#{profile.fetch('table')}' AND name='p' AND active ORDER BY parent_name, column_position FORMAT TSVRaw;"
        else raise "unexpected projection invocation label: #{label}"
        end
      elsif prefix == 'window'
        profile_id, window_name = id.split('-', 2)
        profile = PROFILES.fetch(profile_id)
        window = window_matrix(profile).find { |name, _, _| name == window_name }
        raise "unexpected window label: #{label}" unless window
        query_for_window(profile, window[1], window[2])
      else
        raise "unexpected invocation label: #{label}"
      end
    end
  end

  def table_for_label(label)
    return PROFILES.fetch(PROFILES.keys.first).fetch('table') if label.start_with?('runtime-')
    id = PROFILES.keys.find do |candidate|
      label == "check-#{candidate}" || label.end_with?("-#{candidate}") || label.start_with?("window-#{candidate}-")
    end
    raise "W229 AUDIT FAIL: cannot resolve profile for invocation #{label}" unless id
    PROFILES.fetch(id).fetch('table')
  end

  def guarded_sql(label)
    "SYSTEM STOP MERGES #{DATABASE}.#{table_for_label(label)}; #{expected_sql(label)}"
  end

  def parse_tsv(bytes, label)
    text = bytes.force_encoding(Encoding::UTF_8)
    assert!(text.valid_encoding?, "#{label} is not valid UTF-8 TSV")
    return [] if text.empty?
    text.lines.map { |line| line.chomp.sub(/\r\z/, '').split("\t", -1) }
  end

  def expected_rows(profile)
    profile.fetch('rows').flat_map do |parent, rows|
      rows.map { |values| [parent, values] }
    end
  end

  def helper_rows_for(profile, start_row, max_rows)
    expected_rows(profile).each_with_index.map do |(parent, values), global_index|
      child_rows = profile.fetch('child_rows')
      parent_index = global_index / child_rows
      child_local = global_index % child_rows
      mark_index = child_local / 2
      mark_offset = child_local % 2
      { 'parent_part' => parent, 'child_mark_index' => mark_index,
        'child_mark_row_offset' => mark_offset, 'child_part_row_offset' => child_local,
        'source_row_offset' => global_index, 'values' => values }
    end.drop(start_row).take(max_rows)
  end

  def expected_native_rows(profile, start_row, max_rows)
    expected_rows(profile).each_with_index.map do |(parent, values), offset|
      [parent, offset % profile.fetch('child_rows'), *values]
    end.drop(start_row).take(max_rows).map { |row| row.map(&:to_s) }
  end

  def expected_child_grid(profile)
    profile.fetch('kind') == 'count' ? [2, 1] : [2, 2, 2]
  end

  def source_schema_sql(profile)
    "SELECT name, type FROM system.columns WHERE database='#{DATABASE}' AND table='#{profile.fetch('table')}' ORDER BY position FORMAT TSVRaw;"
  end

  def child_schema_rows(profile)
    profile.fetch('child_schema').each_with_index.map { |(name, type), i| [name, type, (i + 1).to_s] }
  end

  def verify_status!(root, result, invocation, index)
    label = expected_labels.fetch(index)
    stem = format('%04d-%s', index + 1, label)
    base = File.join(root, 'invocations', stem)
    argv_record = read_json(base + '.argv.json', "#{label} argv")
    status = read_json(base + '.status.json', "#{label} status")
    sql = File.binread(plain_file!(base + '.sql', "#{label} SQL"))
    stdout = File.binread(plain_file!(base + '.stdout', "#{label} stdout"))
    stderr = File.binread(plain_file!(base + '.stderr', "#{label} stderr"))
    profile_id = PROFILES.keys.find do |candidate|
      label == "check-#{candidate}" || label.end_with?("-#{candidate}") || label.start_with?("window-#{candidate}-")
    end
    store = File.join(result.fetch('fixture_root'), 'stores', profile_id) if profile_id
    store ||= File.join(result.fetch('fixture_root'), 'stores', 'whole_json')
    expected_argv = [CLICKHOUSE_BIN, 'local', '--multiquery', '--path', store, '--session_timezone=UTC', '--max_threads=1',
      '--max_insert_threads=1', '--max_execution_time=30', "--max_memory_usage=#{MEMORY_LIMIT_BYTES}",
      '--print_pretty_type_names=0', '--query', guarded_sql(label)]
    assert!(argv_record == { 'label' => label, 'argv' => expected_argv, 'environment' => { 'TZ' => 'UTC' },
      'timeout_seconds' => TIMEOUT_SECONDS, 'stdin_bytes' => nil, 'stdin_sha256' => nil }, "#{label} argv record differs")
    assert!(sql == (guarded_sql(label) + "\n").b, "#{label} raw SQL differs")
    assert!(status['label'] == label && status['classification'] == 'process_success' && status['exitstatus'] == 0 &&
      status['signaled'] == false && status['timed_out'] == false && status['spawn_error'].nil?, "#{label} did not succeed as a process")
    if label == 'runtime-version-pin'
      assert!(stdout == "#{CLICKHOUSE_VERSION}\n".b, 'runtime-version-pin raw stdout differs from the pinned literal')
    elsif label == 'runtime-build-pin'
      assert!(stdout == "VERSION_GITHASH=#{CLICKHOUSE_BUILD}\n".b, 'runtime-build-pin raw stdout differs from the pinned literal')
    end
    assert!(status['stdout_bytes'] == stdout.bytesize && status['stderr_bytes'] == stderr.bytesize, "#{label} raw byte counts differ")
    record = result.fetch('invocations').fetch(index)
    assert!(record['label'] == label && record['classification'] == status['classification'] &&
      record['path'] == base && record['sql_sha256'] == Digest::SHA256.hexdigest(guarded_sql(label).b) &&
      record['stdout_sha256'] == Digest::SHA256.hexdigest(stdout) && record['stderr_sha256'] == Digest::SHA256.hexdigest(stderr),
      "#{label} result metadata does not match raw artifacts")
    [stdout, stderr]
  end

  def verify_native_profile!(root, result, indices)
    PROFILES.each do |id, profile|
      labels = ["check-#{id}", "parent-schema-#{id}", "parent-parts-#{id}", "projection-parts-#{id}", "projection-columns-#{id}"] +
        window_matrix(profile).map { |name, _, _| "window-#{id}-#{name}" }
      labels.each do |label|
        index = indices.fetch(label)
        stdout, = verify_status!(root, result, result.fetch('invocations').fetch(index), index)
        case label
        when "check-#{id}"
          check_rows = parse_tsv(stdout, label)
          expected_check_rows = PARENT_PARTS.sort.map { |part| [part, '1', ''] }
          assert!(check_rows.sort_by(&:first) == expected_check_rows,
            "#{id} CHECK TABLE result differs: #{check_rows.inspect}")
        when "parent-schema-#{id}"
          schema = parse_tsv(stdout, label)
          assert!(schema == profile.fetch('source_schema'), "#{id} stock parent schema differs")
        when "parent-parts-#{id}"
          parts = parse_tsv(stdout, label)
          expected = PARENT_PARTS.map { |name| [name, '6', '4', 'Wide'] }
          assert!(parts == expected, "#{id} parent row/mark axes differ: #{parts.inspect}")
        when "projection-parts-#{id}"
          child_rows = parse_tsv(stdout, label)
          rows = profile.fetch('child_rows')
          marks = expected_child_grid(profile).length + 1
          expected = PARENT_PARTS.map { |parent| [parent, 'p', rows.to_s, marks.to_s, '6', '4', 'Wide', 'Wide'] }
          assert!(child_rows == expected, "#{id} projection child axes differ: #{child_rows.inspect}")
        when "projection-columns-#{id}"
          columns = parse_tsv(stdout, label)
          expected = PARENT_PARTS.flat_map do |parent|
            profile.fetch('child_schema').each_with_index.map { |(name, type), i| [parent, 'p', name, type, (i + 1).to_s] }
          end
          assert!(columns == expected, "#{id} selected child schema rows differ")
        else
          window_name = label.delete_prefix("window-#{id}-")
          _, start_row, max_rows = window_matrix(profile).find { |name, _, _| name == window_name }
          actual = parse_tsv(stdout, label)
          expected = expected_native_rows(profile, start_row, max_rows)
          assert!(actual == expected, "#{id}/#{window_name} native literal rows differ: #{actual.inspect} != #{expected.inspect}")
        end
      end
    end
  end

  def audit_helper!(root, result)
    helper_argv = read_json(File.join(root, 'helper.argv.json'), 'helper argv')
    helper_status = read_json(File.join(root, 'helper.status.json'), 'helper status')
    helper_stdout = File.binread(plain_file!(File.join(root, 'helper.stdout'), 'helper stdout'))
    helper_stderr = File.binread(plain_file!(File.join(root, 'helper.stderr'), 'helper stderr'))
    helper = result.fetch('helper_path')
    plain_file!(helper, 'prebuilt helper', executable: true)
    helper_sha = sha256_file(helper)
    assert!(helper_sha == result.fetch('helper_sha256') && helper_sha == helper_argv.fetch('helper_sha256'), 'prebuilt helper hash differs')
    assert!(helper_argv.fetch('argv') == [helper, '--fixture-root', result.fetch('fixture_root')], 'helper argv differs')
    assert!(helper_status['classification'] == 'process_success' && helper_status['exitstatus'] == 0 &&
      helper_status['timed_out'] == false && helper_status['spawn_error'].nil?, 'library helper process was not successful')
    assert!(helper_status['stdout_bytes'] == helper_stdout.bytesize && helper_status['stderr_bytes'] == helper_stderr.bytesize,
      'library helper byte counts differ')
    assert!(Digest::SHA256.hexdigest(helper_stdout) == result.fetch('helper_json_sha256'), 'helper JSON hash differs')
    data = JSON.parse(helper_stdout)
    assert!(data['format'] == 'projection_window_w229_helper_v1' && data['fixture_root'] == result.fetch('fixture_root'), 'helper output identity differs')
    actual_windows = data.fetch('windows')
    expected_records = []
    PROFILES.each do |id, profile|
      window_matrix(profile).each do |name, start_row, max_rows|
        %w[low_level offline].each do |consumer|
          is_past = name == 'past_eof'
          expected_records << {
            'profile' => id, 'consumer' => consumer, 'window' => name, 'start_row' => start_row,
            'max_rows' => max_rows, 'exception' => is_past ? 'CrystalClick::BoundsError' : nil,
            'rows' => is_past ? [] : helper_rows_for(profile, start_row, max_rows),
          }
        end
      end
    end
    assert!(actual_windows.length == expected_records.length, 'helper window roster length differs')
    actual_windows.zip(expected_records).each do |actual, expected|
      expected.each do |key, value|
        assert!(actual[key] == value, "helper #{expected['profile']}/#{expected['consumer']}/#{expected['window']} #{key} differs")
      end
      if expected['rows'].empty?
        assert!(actual['callback_count'] == 0, "empty window unexpectedly called back: #{expected['profile']}/#{expected['window']}")
      else
        assert!(actual['callback_count'].is_a?(Integer) && actual['callback_count'].positive?,
          "nonempty window has no callback: #{expected['profile']}/#{expected['window']}")
      end
    end
    actual_windows.each_slice(2) do |pair|
      assert!(pair[0]['consumer'] == 'low_level' && pair[1]['consumer'] == 'offline', 'helper consumer order differs')
      assert!(pair[0]['rows'] == pair[1]['rows'] && pair[0]['exception'] == pair[1]['exception'], 'two library consumers disagree')
    end
  rescue JSON::ParserError => error
    raise "W229 AUDIT FAIL: malformed helper JSON: #{error.message}"
  end

  def raw_tree_for(root, id)
    fixture = File.join(root, 'stores', id)
    source_path = File.join(root, 'results', id, 'physical_inputs.pre.json')
    source = read_json(source_path, "W217 #{id} physical manifest")
    parent_records = source.fetch('parent_parts')
    parent_names = parent_records.map { |part| part.fetch('name') }
    assert!(parent_names.sort == PARENT_PARTS.sort, "#{id} W217 physical parent manifest names differ: #{parent_names.inspect}")
    parents = parent_records.sort_by { |part| part.fetch('name') }
    files = []
    entries = 0
    bytes = 0
    parents.each do |parent|
      name = parent.fetch('name')
      parent_path = parent.fetch('canonical_path')
      plain_dir!(parent_path, "#{id}/#{name} source part")
      assert!(File.dirname(parent_path).start_with?(fixture + '/') && File.basename(parent_path) == name, "#{id}/#{name} escaped fixture store")
      walk = lambda do |path, depth|
        assert!(depth <= TREE_DEPTH_CAP, "#{id} tree depth cap exceeded")
        Dir.children(path).sort.each do |entry|
          entries += 1
          assert!(entries <= TREE_ENTRY_CAP, "#{id} tree entry cap exceeded")
          full = File.join(path, entry)
          assert!(!File.symlink?(full), "#{id} tree includes symlink #{full}")
          canonical = File.realpath(full)
          assert!(canonical == File.expand_path(full) && canonical.start_with?(parent_path + '/'), "#{id} path escapes parent")
          if File.directory?(full)
            walk.call(full, depth + 1)
          elsif File.file?(full)
            size = File.size(full)
            bytes += size
            assert!(bytes <= TREE_BYTE_CAP, "#{id} byte cap exceeded")
            files << { 'parent' => name, 'relative_path' => canonical.delete_prefix(parent_path + '/'),
              'size_bytes' => size, 'sha256' => sha256_file(full) }
          else
            raise "W229 AUDIT FAIL: unsupported fixture entry #{full}"
          end
        end
      end
      walk.call(parent_path, 0)
    end
    assert!(files.any? { |file| file['relative_path'].start_with?('p.proj/') }, "#{id} current physical tree has no p.proj")
    { 'profile' => id, 'store' => fixture, 'parents' => PARENT_PARTS,
      'entry_count' => entries, 'file_count' => files.length, 'total_bytes' => bytes,
      'files' => files.sort_by { |file| [file['parent'], file['relative_path']] } }
  end

  def verify_manifests!(root, result)
    source_pre = read_json(File.join(root, 'source_pin.pre.json'), 'source pin pre')
    source_post = read_json(File.join(root, 'source_pin.post.json'), 'source pin post')
    assert!(source_pre == source_post && source_pre['revision'] == SOURCE_REVISION && source_pre['source_root'] == SOURCE_ROOT,
      'pinned ClickHouse source manifest changed or identifies wrong checkout')
    actual_source = SOURCE_FILES.map do |relative, expected|
      path = File.join(SOURCE_ROOT, relative)
      plain_file!(path, "pinned source #{relative}")
      hash = sha256_file(path)
      assert!(hash == expected, "pinned source hash differs: #{relative}")
      { 'path' => relative, 'sha256' => hash }
    end
    assert!(source_pre['files'] == actual_source, 'source pin file roster differs')
    assert!(result['source_unchanged'] == true, 'runner did not observe stable stock source')

    pre = read_json(File.join(root, 'fixture_physical.pre.json'), 'fixture physical pre')
    post = read_json(File.join(root, 'fixture_physical.post.json'), 'fixture physical post')
    assert!(pre == post && pre['profiles'].map { |p| p['profile'] } == PROFILES.keys, 'fixture physical pre/post differs or roster wrong')
    raw = PROFILES.keys.map { |id| raw_tree_for(result.fetch('fixture_root'), id) }
    assert!(pre['profiles'] == raw, 'independently rehashed physical fixture differs from runner manifest')
    assert!(result['fixture_physical_unchanged'] == true, 'runner did not observe stable physical fixture')
    assert!(Digest::SHA256.hexdigest(JSON.generate(pre['profiles'])) == result['physical_pre_sha256'] &&
      result['physical_pre_sha256'] == result['physical_post_sha256'], 'physical manifest digests differ')
  end

  def audit_root!(path)
    root = root_path!(path)
    children = Dir.children(root).sort
    assert!(children == %w[fixture_physical.post.json fixture_physical.pre.json helper.argv.json helper.status.json helper.stderr helper.stdout invocations result.json source_pin.post.json source_pin.pre.json].sort,
      "W229 evidence root roster differs: #{children.inspect}")
    result = read_json(File.join(root, 'result.json'), 'W229 result')
    assert!(result['format'] == 'projection_window_w229_result_v1' && result['fixture_root'].start_with?('/private/tmp/crystal-click-w229-fixtures-'),
      'W229 result identity differs')
    fixture_root = result.fetch('fixture_root')
    plain_dir!(fixture_root, 'W217 fixture root')
    assert!(File.dirname(fixture_root) == File.realpath('/private/tmp') &&
      File.basename(fixture_root).start_with?('crystal-click-w229-fixtures-'),
      'W217 fixture root is outside its bounded direct-child prefix')
    stores_root = plain_dir!(File.join(fixture_root, 'stores'), 'W217 stores root')
    assert!(Dir.children(stores_root).sort == PROFILES.keys.sort, 'W217 fixture store roster differs')
    assert!(result['clickhouse_binary'] == CLICKHOUSE_BIN && result['clickhouse_sha256'] == CLICKHOUSE_SHA256 &&
      result['clickhouse_version'] == CLICKHOUSE_VERSION && result['clickhouse_build'] == CLICKHOUSE_BUILD,
      'pinned ClickHouse identity differs')
    plain_file!(CLICKHOUSE_BIN, 'pinned ClickHouse binary', executable: true)
    assert!(sha256_file(CLICKHOUSE_BIN) == CLICKHOUSE_SHA256, 'pinned ClickHouse binary SHA differs')
    assert!(result['stock_source_revision'] == SOURCE_REVISION, 'pinned stock source revision differs')
    code_pins = result.fetch('code_pins')
    expected_code_paths = (%w[scripts/check_projection_window_evidence_w229.rb scripts/check_projection_window_w229.cr scripts/recheck_projection_window_w229.rb] +
      PINNED_CODE_FILES.keys).sort
    assert!(code_pins.keys.sort == expected_code_paths, 'W229 source code pin roster differs')
    code_pins.each do |relative, hash|
      file = File.join(REPO_ROOT, relative)
      plain_file!(file, "W229 source #{relative}")
      assert!(sha256_file(file) == hash, "W229 source code changed after capture: #{relative}")
    end
    PINNED_CODE_FILES.each do |relative, expected|
      assert!(code_pins.fetch(relative) == expected, "pinned production source provenance differs: #{relative}")
    end
    verify_manifests!(root, result)
    invocations = plain_dir!(File.join(root, 'invocations'), 'invocations directory')
    labels = expected_labels
    expected_files = labels.each_with_index.flat_map do |label, index|
      stem = format('%04d-%s', index + 1, label)
      %w[argv.json sql stdout stderr status.json].map { |suffix| "#{stem}.#{suffix}" }
    end.sort
    actual_files = Dir.children(invocations).sort
    assert!(actual_files == expected_files, 'raw invocation artifact roster differs')
    records = result.fetch('invocations')
    assert!(result['invocation_labels'] == labels && records.length == labels.length, 'invocation label list differs')
    indices = labels.each_with_index.to_h
    labels.each_with_index { |label, i| verify_status!(root, result, records.fetch(i), i) }
    verify_native_profile!(root, result, indices)
    audit_helper!(root, result)
    { 'root' => root, 'runtime' => CLICKHOUSE_VERSION, 'invocations' => labels.length,
      'profiles' => PROFILES.length, 'windows' => PROFILES.length * 5, 'physical_manifest_sha256' => result['physical_pre_sha256'] }
  end

  def run(paths)
    assert!((1..2).cover?(paths.length), 'provide one or two W229 roots')
    summaries = paths.map { |path| audit_root!(path) }
    if summaries.length == 2
      a = read_json(File.join(summaries[0]['root'], 'source_pin.pre.json'), 'first source pin')
      b = read_json(File.join(summaries[1]['root'], 'source_pin.pre.json'), 'second source pin')
      assert!(a == b, 'DEBUG/RELEASE stock source pins differ')
    end
    summaries.each do |summary|
      puts "#{summary['root']}: W229 raw audit PASS; #{summary['profiles']} profiles, #{summary['windows']} window queries, " \
        "#{summary['invocations']} ClickHouse invocations; physical_sha256=#{summary['physical_manifest_sha256']}"
    end
    true
  rescue StandardError => error
    warn error.message
    false
  end
end

exit(CheckProjectionWindowEvidenceW229.run(ARGV) ? 0 : 1)
