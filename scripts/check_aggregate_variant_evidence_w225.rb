#!/usr/bin/env ruby
# Read-only, raw-sidecar and independent-literal audit for W225 paired parts.

require 'digest'
require 'find'
require 'json'
require_relative 'recheck_aggregate_variant_w225'

module CheckAggregateVariantEvidenceW225
  extend self

  W = RecheckAggregateVariantW225
  R = W::R
  EXPECTED_CHECK = "all_1_1_0\t1\t\n".freeze
  INVALIDATED_FILE = 'invalidated_system_columns.txt'.freeze
  INVALIDATED_NAMES = %w[_block_number _block_offset].freeze
  STRING_VERSIONS = { 'single_stream' => 0, 'with_size_stream' => 1 }.freeze

  def fail!(message)
    raise ArgumentError, message
  end

  def require_true(condition, message)
    fail!(message) unless condition
  end

  def validate_sha256_pin!(value, label)
    require_true(value.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(value),
      "#{label} must be exactly 64 lowercase hexadecimal characters")
    value
  end

  def canonical_root(path, prefix, label)
    full = File.expand_path(path)
    require_true(File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full,
      "#{label} is absent, symlinked, or noncanonical")
    require_true(File.dirname(full) == File.realpath('/private/tmp') && full.start_with?(prefix),
      "#{label} is outside its fixed direct-child /private/tmp prefix")
    full
  end

  def read_file(path, root = nil)
    full = File.expand_path(path)
    require_true(File.file?(full) && !File.symlink?(full) && File.realpath(full) == full,
      "missing, symlinked, or noncanonical evidence file: #{full}")
    if root
      prefix = File.realpath(root) + File::SEPARATOR
      require_true(full.start_with?(prefix), "evidence file escaped its root: #{full}")
    end
    File.binread(full)
  end

  def json_file(path, root = nil)
    JSON.parse(read_file(path, root).force_encoding(Encoding::UTF_8))
  rescue JSON::ParserError => error
    fail!("invalid JSON evidence #{path}: #{error.message}")
  end

  def inventory(part)
    full = File.expand_path(part)
    require_true(File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full,
      "part is absent, symlinked, or noncanonical: #{full}")
    rows = []
    Find.find(full) do |path|
      next if path == full
      require_true(!File.symlink?(path), "part contains a symlink: #{path}")
      next if File.directory?(path)
      require_true(File.file?(path), "part contains a non-file entry: #{path}")
      rows << { 'path' => path[(full.length + 1)..-1], 'size' => File.size(path),
        'sha256' => Digest::SHA256.file(path).hexdigest }
    end
    rows.sort_by { |row| row.fetch('path') }
  end

  def expected_labels(profiles)
    labels = %w[runtime-version-pin runtime-build-pin generic-stock-read-library-write-read]
    profiles.each do |profile|
      id = profile.fetch('id')
      labels.concat(%W[stock-create-#{id} stock-insert-#{id} stock-check-#{id}
        stock-rowbinary-#{id}-full stock-rowbinary-#{id}-middle stock-rowbinary-#{id}-empty
        stock-metadata-#{id} stock-type-name-#{id} stock-part-#{id}])
      labels.concat(%W[native-create-#{id} native-data-path-#{id} native-attach-#{id} native-check-#{id}
        native-metadata-#{id} native-part-#{id} native-type-name-#{id}
        native-rowbinary-#{id}-full native-rowbinary-#{id}-middle native-rowbinary-#{id}-empty])
    end
    labels
  end

  def invocation_index(root)
    directory = File.join(root, 'invocations')
    require_true(File.directory?(directory) && !File.symlink?(directory) && File.realpath(directory) == directory,
      'raw invocation directory is absent, symlinked, or noncanonical')
    index = {}
    expected_files = []
    Dir.glob(File.join(directory, '*.argv.json')).sort.each do |argv_path|
      argv_record = json_file(argv_path, root)
      require_true(argv_record.keys.sort == %w[argv environment label stdin_bytes stdin_sha256 timeout_seconds],
        'raw argv sidecar has an unexpected field set')
      label = argv_record.fetch('label')
      require_true(!index.key?(label), "duplicate raw invocation label: #{label}")
      base = argv_path.sub(/\.argv\.json\z/, '')
      status_path = base + '.status.json'
      stdout_path = base + '.stdout'
      stderr_path = base + '.stderr'
      sql_path = base + '.sql'
      stdin_path = base + '.stdin.bin'
      status = json_file(status_path, root)
      require_true(status.keys.sort == %w[classification duration_ms exitstatus label signaled spawn_error stderr_bytes stdout_bytes termsig timed_out] &&
        status.fetch('label') == label,
        "raw process status has an unexpected field set: #{label}")
      stdout = read_file(stdout_path, root)
      stderr = read_file(stderr_path, root)
      sql = read_file(sql_path, root)
      require_true(status.fetch('stdout_bytes') == stdout.bytesize && status.fetch('stderr_bytes') == stderr.bytesize,
        "raw process byte counts differ: #{label}")
      if argv_record['stdin_bytes'].nil?
        require_true(!File.exist?(stdin_path) && !File.symlink?(stdin_path) && argv_record['stdin_sha256'].nil?,
          "unexpected raw stdin sidecar: #{label}")
        stdin = nil
      else
        stdin = read_file(stdin_path, root)
        require_true(stdin.bytesize == argv_record.fetch('stdin_bytes') &&
          Digest::SHA256.hexdigest(stdin) == argv_record.fetch('stdin_sha256'),
          "raw stdin bytes/hash differ: #{label}")
      end
      suffixes = %w[.argv.json .sql .status.json .stderr .stdout]
      suffixes << '.stdin.bin' unless stdin.nil?
      suffixes.each { |suffix| expected_files << File.basename(base + suffix) }
      index[label] = { 'argv_record' => argv_record, 'status' => status, 'stdout' => stdout,
        'stderr' => stderr, 'sql' => sql, 'stdin' => stdin, 'base' => base }
    end
    actual_files = Dir.children(directory).sort
    require_true(actual_files == expected_files.sort, 'raw invocation directory has missing or extra sidecars')
    index
  end

  def assert_process_roster!(invocations, profiles)
    wanted = expected_labels(profiles).sort
    actual = invocations.keys.sort
    require_true(actual == wanted, "raw process roster differs (wanted #{wanted.length}, saw #{actual.length})")
    invocations.each do |label, item|
      status = item.fetch('status')
      require_true(status.fetch('classification') == 'process_success' && status.fetch('exitstatus') == 0 &&
        !status.fetch('signaled') && status.fetch('termsig').nil? && !status.fetch('timed_out') &&
        status.fetch('spawn_error').nil?, "unexpected raw process failure: #{label}")
    end
  end

  def assert_sql!(record, sql, label)
    command_sql = sql.sub(/\n\z/, '')
    require_true(record.fetch('sql') == (command_sql.empty? ? "\n" : command_sql + "\n") &&
      record.fetch('argv_record').fetch('argv').last == command_sql,
      "recorded SQL/argv differs: #{label}")
  end

  def expected_create_sql(profile, table)
    mode = profile.fetch('profile')
    require_true(STRING_VERSIONS.key?(mode), "unlisted W225 String profile: #{mode}")
    settings = R::STOCK_SETTINGS + ["string_serialization_version='#{mode}'", W::VARIANT_BASIC_SETTING]
    "CREATE TABLE default.#{table} (pk UInt64, v #{profile.fetch('declared_type')}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings.join(', ')}"
  end

  def assert_part_census!(stdout, expected_path, label)
    lines = stdout.split("\n", -1)
    require_true(lines.length == 2 && lines.last.empty?, "raw #{label} part census row shape differs")
    fields = lines.first.split("\t", -1)
    require_true(fields.length == 5 && fields.first(4) == ['all_1_1_0', '5', '4', 'Wide'],
      "raw #{label} part census identity/grid differs")
    raw_path = fields.fetch(4)
    accepted = [expected_path, expected_path + File::SEPARATOR]
    require_true(accepted.include?(raw_path) && File.realpath(expected_path) == expected_path,
      "raw #{label} part path is not canonical or has more than one terminal separator")
  end

  def record_from_status(item)
    item.fetch('status').merge('label' => item.fetch('argv_record').fetch('label'))
  end

  def assert_clickhouse_argv!(invocations, binary, root, source_root, profiles)
    invocations.each do |label, item|
      next if label == 'generic-stock-read-library-write-read'
      argv_record = item.fetch('argv_record')
      require_true(argv_record.fetch('environment') == { 'TZ' => 'UTC' } &&
        argv_record.fetch('timeout_seconds') == R::PROCESS_TIMEOUT_SECONDS,
        "ClickHouse environment/timeout differs: #{label}")
      require_true(item.fetch('sql').end_with?("\n") && item.fetch('sql').bytesize > 1,
        "ClickHouse SQL sidecar is empty: #{label}")
      query = item.fetch('sql').sub(/\n\z/, '')
      argv = argv_record.fetch('argv')
      store = argv.fetch(3)
      if label.start_with?('runtime-')
        expected_store = File.join(source_root, 'stores', 'pins')
      elsif label.start_with?('stock-')
        profile = profiles.find { |candidate| label.match?(/(?:\A|-)#{Regexp.escape(candidate.fetch('id'))}(?:-|\z)/) }
        require_true(!profile.nil?, "stock process label has no finite profile: #{label}")
        id = profile.fetch('id')
        expected_store = File.join(source_root, 'stores', 'profiles', id)
      elsif label.start_with?('native-')
        profile = profiles.find { |candidate| label.match?(/(?:\A|-)#{Regexp.escape(candidate.fetch('id'))}(?:-|\z)/) }
        require_true(!profile.nil?, "native process label has no finite profile: #{label}")
        id = profile.fetch('id')
        expected_store = File.join(root, 'stores', 'native', id)
      else
        fail!("unclassified ClickHouse process label: #{label}")
      end
      require_true(store == expected_store && File.directory?(store) && !File.symlink?(store) &&
        File.realpath(store) == store, "ClickHouse store path differs or is redirected: #{label}")
      expected_argv = [binary, 'local', '--path', store, '--session_timezone=UTC', '--max_threads=1',
        '--max_insert_threads=1', '--max_execution_time=30', "--max_memory_usage=#{R::MEMORY_LIMIT_BYTES}",
        '--print_pretty_type_names=0', '--multiquery', '--query', query]
      require_true(argv == expected_argv, "ClickHouse argv/options differ: #{label}")
    end
  end

  def assert_runtime!(source_root, summary, invocations)
    runtime = summary.fetch('runtime_pin')
    require_true(runtime == { 'version' => R::VERSION, 'build_hash' => R::BUILD_HASH,
      'sha256' => R::RUNTIME_SHA256, 'runtime_source_correlation' => 'not_asserted' },
      'runtime pin or source/runtime distinction differs')
    require_true(json_file(File.join(source_root, 'runtime_pin.json'), source_root) == runtime,
      'source-root runtime pin differs from runner summary')
    version = invocations.fetch('runtime-version-pin')
    build = invocations.fetch('runtime-build-pin')
    require_true(version.fetch('stdout').strip == R::VERSION &&
      build.fetch('stdout').strip == "VERSION_GITHASH=#{R::BUILD_HASH}", 'runtime query outputs differ')
    binary = version.fetch('argv_record').fetch('argv').first
    require_true(R.validate_binary!(binary) == binary && Digest::SHA256.file(binary).hexdigest == runtime.fetch('sha256'),
      'runtime binary path/hash differs from the independently pinned runtime')
    assert_sql!(version, 'SELECT version() FORMAT TSVRaw', 'runtime-version-pin')
    assert_sql!(build, "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw",
      'runtime-build-pin')
    binary
  end

  def assert_source_pin!(source_root, matrix, summary)
    source_pin = matrix.fetch('source_pin')
    require_true(source_pin == summary.fetch('source_pin') &&
      source_pin == json_file(File.join(source_root, 'source_pin.json'), source_root),
      'source pin differs across summary, matrix, and source-root carrier')
    current = W.pin_source!
    require_true(current == source_pin && source_pin.fetch('source_reference') == "#{W::SOURCE_ROOT}@#{W::SOURCE_REVISION}" &&
      source_pin.fetch('runtime_built_from_this_source_not_asserted') == true &&
      source_pin.fetch('file_hashes').all? { |item| item.fetch('matches') && item.fetch('expected_sha256') == item.fetch('actual_sha256') },
      'pinned source hashes or runtime/source distinction differ')
    source_pin
  end

  def assert_rowbinary_window!(window_record, raw_invocation, profile, window, output_path, table, side, evidence_root)
    require_true(window_record.keys.sort == %w[bytes literal_hex matches_independent_literal path process sha256],
      "#{side} #{window} RowBinary evidence fields differ: #{profile.fetch('id')}")
    predicate = case window
                when 'full' then ''
                when 'middle' then ' WHERE pk BETWEEN 33 AND 44'
                when 'empty' then ' WHERE pk=0'
                else fail!("unlisted W225 RowBinary window: #{window}")
                end
    expected_sql = "SELECT pk, v FROM default.#{table}#{predicate} ORDER BY pk INTO OUTFILE '#{output_path}' FORMAT RowBinary"
    assert_sql!(raw_invocation, expected_sql, "#{side}-rowbinary-#{profile.fetch('id')}-#{window}")
    bytes = read_file(window_record.fetch('path'), evidence_root)
    literal = [profile.fetch('rowbinary').fetch("#{window}_hex")].pack('H*').b
    require_true(window_record.fetch('path') == output_path && bytes == literal &&
      window_record.fetch('bytes') == bytes.bytesize && window_record.fetch('sha256') == Digest::SHA256.hexdigest(bytes) &&
      window_record.fetch('literal_hex') == bytes.unpack1('H*') && window_record.fetch('matches_independent_literal') == true,
      "#{side} #{window} RowBinary output differs from independent literal: #{profile.fetch('id')}")
    require_true(raw_invocation.fetch('status').fetch('classification') == 'process_success' &&
      window_record.fetch('process') == record_from_status(raw_invocation),
      "#{side} #{window} RowBinary raw status/process carrier differs: #{profile.fetch('id')}")
  end

  def source_profile_paths(source_root, profile)
    id = profile.fetch('id')
    { 'part' => File.join(source_root, 'parts', id, 'all_1_1_0'),
      'case' => File.join(source_root, 'cases', 'profiles', "#{id}.json"),
      'literal' => File.join(source_root, 'cases', 'profiles', "#{id}-literal-validation.json") }
  end

  def assert_source_profiles!(source_root, matrix, profiles, invocations)
    require_true(matrix.keys.sort == %w[format mark_rows profile_count profiles row_keys runtime_pin source_pin string_versions variant_discriminator_mode variant_setting] &&
      matrix.fetch('format') == W::FORMAT_MATRIX && matrix.fetch('profile_count') == profiles.length &&
      matrix.fetch('row_keys') == R::ROW_KEYS.map(&:to_i) && matrix.fetch('mark_rows') == R::MARK_ROWS.map(&:to_i) &&
      matrix.fetch('string_versions') == STRING_VERSIONS && matrix.fetch('variant_discriminator_mode') == 'BASIC' &&
      matrix.fetch('variant_setting') == W::VARIANT_BASIC_SETTING &&
      matrix.fetch('profiles').map { |item| item.fetch('id') } == W::PROFILE_IDS,
      'stock matrix format, profile axes, or BASIC discriminator setting differs')
    observed = matrix.fetch('profiles')
    profiles.each_with_index do |profile, index|
      item = observed.fetch(index)
      id = profile.fetch('id')
      require_true(item.keys.sort == %w[check_output declared_type expected_lanes id mark_rows metadata profile row_keys rowbinary
        serialization_json source_inventory source_part source_schema source_windows values],
        "stock matrix profile field set differs: #{id}")
      base_fields = %w[id declared_type profile metadata row_keys mark_rows values rowbinary expected_lanes]
      base_fields.each do |key|
        require_true(item.fetch(key) == profile.fetch(key), "stock matrix independent #{key} differs: #{id}")
      end
      paths = source_profile_paths(source_root, profile)
      require_true(item.fetch('source_part') == paths.fetch('part') && item.fetch('source_schema') == "pk\tUInt64\nv\t#{profile.fetch('declared_type')}\n" &&
        item.fetch('check_output') == EXPECTED_CHECK,
        "stock matrix part/schema/CHECK contract differs: #{id}")
      part = paths.fetch('part')
      require_true(inventory(part) == item.fetch('source_inventory'), "stock copied-part inventory differs: #{id}")
      serialization = { 'columns' => [], 'propagate_types_serialization_versions_to_nested_types' => true,
        'types_serialization_versions' => { 'string' => STRING_VERSIONS.fetch(profile.fetch('profile')) }, 'version' => 1 }
      require_true(item.fetch('serialization_json') == serialization &&
        json_file(File.join(part, 'serialization.json'), source_root) == serialization &&
        read_file(File.join(part, 'metadata_version.txt'), source_root).strip == '0' &&
        read_file(File.join(part, 'default_compression_codec.txt'), source_root).strip == 'CODEC(LZ4)',
        "stock serialization profile/codec/metadata differs: #{id}")

      table = "w225_#{id}"
      create = invocations.fetch("stock-create-#{id}")
      insert = invocations.fetch("stock-insert-#{id}")
      check = invocations.fetch("stock-check-#{id}")
      metadata = invocations.fetch("stock-metadata-#{id}")
      type_name = invocations.fetch("stock-type-name-#{id}")
      census = invocations.fetch("stock-part-#{id}")
      assert_sql!(create, expected_create_sql(profile, table), "stock-create-#{id}")
      assert_sql!(insert, "INSERT INTO default.#{table} FORMAT RowBinary", "stock-insert-#{id}")
      assert_sql!(check, "CHECK TABLE default.#{table} FORMAT TSVRaw", "stock-check-#{id}")
      assert_sql!(metadata, "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw", "stock-metadata-#{id}")
      assert_sql!(type_name, "SELECT toTypeName(v) FROM default.#{table} LIMIT 1 FORMAT TSVRaw", "stock-type-name-#{id}")
      assert_sql!(census, "SELECT name, toString(rows), toString(marks), part_type, path FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw", "stock-part-#{id}")
      expected_insert = [profile.fetch('rowbinary').fetch('full_hex')].pack('H*').b
      require_true(insert.fetch('stdin') == expected_insert && insert.fetch('argv_record').fetch('stdin_bytes') == expected_insert.bytesize &&
        insert.fetch('argv_record').fetch('stdin_sha256') == Digest::SHA256.hexdigest(expected_insert),
        "stock RowBinary INSERT literal differs: #{id}")
      require_true(check.fetch('stdout') == EXPECTED_CHECK && metadata.fetch('stdout') == "pk\tUInt64\nv\t#{profile.fetch('declared_type')}\n" &&
        type_name.fetch('stdout') == "#{profile.fetch('declared_type')}\n", "stock CHECK/schema/type-name raw output differs: #{id}")
      original_part = census.fetch('stdout').split("\n", -1).fetch(0).split("\t", -1).fetch(4)
      original_part = File.expand_path(original_part)
      store = create.fetch('argv_record').fetch('argv').fetch(3)
      require_true(original_part.start_with?(store + File::SEPARATOR) && inventory(original_part) == item.fetch('source_inventory'),
        "stock original part is outside its isolated store or inventory differs: #{id}")
      assert_part_census!(census.fetch('stdout'), original_part, "stock/#{id}")

      profile_case = json_file(paths.fetch('case'), source_root)
      literal_case = json_file(paths.fetch('literal'), source_root)
      expected_literal = { 'validation' => 'pure Ruby metadata encoder vs separately represented tagged-state literal encoder',
        'before_any_clickhouse_process_for_profile' => true, 'all_rows_match' => true,
        'rowbinary' => profile.fetch('rowbinary'), 'expected_lanes' => profile.fetch('expected_lanes') }
      require_true(literal_case == expected_literal, "stock independent literal-validation carrier differs: #{id}")
      require_true(profile_case.keys.sort == %w[canonicalization check_output classification expected_lanes id literal_rowbinary_hex
        processes requested_type rowbinary_windows schema serialization_json source_inventory source_type type_name],
        "stock per-profile case fields differ: #{id}")
      required_case = { 'id' => id, 'classification' => 'stock_physical_observed',
        'requested_type' => profile.fetch('declared_type'), 'source_type' => profile.fetch('declared_type'),
        'canonicalization' => 'exact_declared_type', 'literal_rowbinary_hex' => [profile.fetch('rowbinary').fetch('full_hex')],
        'expected_lanes' => profile.fetch('expected_lanes'), 'schema' => metadata.fetch('stdout'),
        'type_name' => type_name.fetch('stdout'), 'check_output' => check.fetch('stdout'),
        'source_inventory' => item.fetch('source_inventory'), 'serialization_json' => serialization }
      required_case.each { |key, value| require_true(profile_case.fetch(key) == value, "stock case #{key} differs: #{id}") }
      expected_process_labels = ["stock-create-#{id}", "stock-insert-#{id}", "stock-check-#{id}",
        "stock-metadata-#{id}", "stock-type-name-#{id}", "stock-part-#{id}",
        "stock-rowbinary-#{id}-full", "stock-rowbinary-#{id}-middle", "stock-rowbinary-#{id}-empty"]
      expected_process_records = expected_process_labels.map { |label| record_from_status(invocations.fetch(label)) }
      require_true(profile_case.fetch('processes') == expected_process_records,
        "stock case process carrier differs from raw sidecars: #{id}")
      source_windows = item.fetch('source_windows')
      require_true(source_windows.keys.sort == %w[empty full middle], "stock matrix RowBinary window roster differs: #{id}")
      %w[full middle empty].each do |window|
        output_path = File.join(source_root, 'cases', 'profiles', "#{id}-#{window}.rowbinary")
        assert_rowbinary_window!(source_windows.fetch(window), invocations.fetch("stock-rowbinary-#{id}-#{window}"),
          profile, window, output_path, table, 'stock', source_root)
        require_true(profile_case.fetch('rowbinary_windows').fetch(window) == source_windows.fetch(window),
          "stock case RowBinary window differs from matrix: #{id}/#{window}")
      end
    end
  end

  def expected_helper_input_profile(profile, index, source_part, root)
    destination = File.join(root, 'generated', 'parts', format('%02d-%s', index, profile.fetch('id')), 'all_1_1_0')
    { 'id' => profile.fetch('id'), 'declared_type' => profile.fetch('declared_type'),
      'expected_lanes' => profile.fetch('expected_lanes'), 'librarydest' => destination,
      'mark_rows' => profile.fetch('mark_rows'), 'metadata' => profile.fetch('metadata'),
      'profile' => profile.fetch('profile'), 'row_keys' => profile.fetch('row_keys'),
      'rowbinary' => profile.fetch('rowbinary'), 'stockpart' => source_part, 'values' => profile.fetch('values') }
  end

  def assert_consumer!(consumer, profile, side)
    require_true(consumer.fetch('exact_nominal_states') == true &&
      consumer.fetch('wide_part_scan').fetch('api') == 'WidePartTable.open_selected_typed + generic BinaryBulk callback values' &&
      consumer.fetch('wide_part_scan').fetch('batch_schedule') == [[0, 0, 2], [1, 2, 2], [2, 4, 1]] &&
      consumer.fetch('wide_part_scan').fetch('window_rows') == 3 &&
      consumer.fetch('offline_values').fetch('rows') == 5 && consumer.fetch('offline_values').fetch('detached_values') == true &&
      consumer.fetch('offline_scan').fetch('rows') == 5 && consumer.fetch('offline_scan').fetch('window_rows') == 3,
      "#{side} generic/offline consumer shape differs: #{profile.fetch('id')}")
  end

  def audit_type_name(node)
    case node.fetch('kind')
    when 'count', 'sum', 'string'
      node.fetch('name')
    when 'array'
      "Array(#{audit_type_name(node.fetch('children').fetch(0))})"
    when 'tuple'
      "Tuple(#{node.fetch('children').map { |child| audit_type_name(child) }.join(', ')})"
    when 'variant'
      "Variant(#{node.fetch('children').map { |child| audit_type_name(child) }.join(', ')})"
    else
      fail!("unlisted W225 audit type node: #{node.fetch('kind')}")
    end
  end

  def audit_escape_physical_component(raw)
    raw.bytes.map do |byte|
      ascii_word = (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) ||
        (byte >= 97 && byte <= 122) || byte == 95
      ascii_word ? byte.chr : format('%%%02X', byte)
    end.join
  end

  def audit_physical_names_for(node, prefix, profile, array_level, names)
    case node.fetch('kind')
    when 'count', 'sum'
      names << prefix
    when 'string'
      names << "#{prefix}.size" if profile == 'with_size_stream'
      names << prefix
    when 'array'
      names << "#{prefix}.size#{array_level}"
      audit_physical_names_for(node.fetch('children').fetch(0), prefix, profile, array_level + 1, names)
    when 'tuple'
      node.fetch('children').each_with_index do |child, index|
        escaped_field = audit_escape_physical_component((index + 1).to_s)
        audit_physical_names_for(child, "#{prefix}%2E#{escaped_field}", profile, array_level, names)
      end
    when 'variant'
      names << "#{prefix}.variant_discr"
      node.fetch('children').each do |child|
        escaped_arm = audit_escape_physical_component(audit_type_name(child))
        audit_physical_names_for(child, "#{prefix}.#{escaped_arm}", profile, array_level, names)
      end
    else
      fail!("unlisted W225 audit physical-name node: #{node.fetch('kind')}")
    end
  end

  # Separate from the runner's physical-name traversal and from logical lane
  # roles: this auditor recomputes physical basenames from the nominal AST.
  def expected_physical_stream_names(profile)
    names = []
    audit_physical_names_for(profile.fetch('node'), 'v', profile.fetch('profile'), 0, names)
    names.sort
  end

  def assert_helper_part!(part, path, profile, side)
    require_true(part.fetch('part_path') == path && part.fetch('schema_declaration') == profile.fetch('declared_type') &&
      part.fetch('source_declaration') == profile.fetch('declared_type') && part.fetch('profile') == profile.fetch('profile') &&
      part.fetch('row_count') == 5 && part.fetch('mark_rows') == profile.fetch('mark_rows') &&
      part.fetch('exact_nominal_states') == true, "helper #{side} part contract differs: #{profile.fetch('id')}")
    expected_lanes = profile.fetch('expected_lanes')
    roles = expected_lanes.map { |lane| lane.fetch('role_path') }
    require_true(part.fetch('physical_stream_names') == expected_physical_stream_names(profile),
      "helper #{side} physical basename roster differs: #{profile.fetch('id')}")
    require_true(part.fetch('mark_reads') == [
      { 'first_mark' => 0, 'mark_count' => 3, 'rows' => 5 },
      { 'first_mark' => 3, 'mark_count' => 0, 'rows' => 0 },
    ], "helper #{side} mark reads differ: #{profile.fetch('id')}")
    lanes = part.fetch('physical_lanes')
    require_true(lanes.map { |lane| lane.fetch('role_path') } == roles, "helper #{side} physical lane order differs")
    lanes.each_with_index do |lane, index|
      expected = expected_lanes.fetch(index)
      require_true(lane.fetch('hex') == expected.fetch('hex') && lane.fetch('mark_offsets') == expected.fetch('mark_offsets') &&
        lane.fetch('rows_per_mark') == profile.fetch('mark_rows') && lane.fetch('physical_prefix_bytes').is_a?(Integer) &&
        lane.fetch('physical_prefix_bytes') >= 0, "helper #{side} physical lane literal/grid differs: #{expected.fetch('role_path')}")
      %w[data_path mrk2_path].each do |field|
        full = lane.fetch(field)
        require_true(full == File.expand_path(full) && full.start_with?(path + File::SEPARATOR) &&
          File.file?(full) && !File.symlink?(full) && File.realpath(full) == full,
          "helper #{side} physical lane path escaped/redirected: #{profile.fetch('id')}/#{field}")
      end
    end
    inventory_paths = inventory(path).map { |entry| entry.fetch('path') }
    lanes.each do |lane|
      %w[data_path mrk2_path].each do |field|
        relative = lane.fetch(field)[path.length + 1..-1]
        require_true(inventory_paths.include?(relative), "helper #{side} lane file is absent from part inventory: #{relative}")
      end
    end
  end

  def assert_helper_and_generated_parts!(root, source_root, profiles, matrix, invocations, summary, expected_sha)
    process = invocations.fetch('generic-stock-read-library-write-read')
    argv_record = process.fetch('argv_record')
    helper = argv_record.fetch('argv').fetch(0)
    require_true(File.file?(helper) && File.executable?(helper) && !File.symlink?(helper) && File.realpath(helper) == helper,
      'prebuilt W225 helper is missing, symlinked, non-executable, or noncanonical')
    actual_sha = Digest::SHA256.file(helper).hexdigest
    require_true(actual_sha == expected_sha && summary.fetch('helper_sha256_expected') == expected_sha &&
      summary.fetch('helper_sha256_observed_at_start') == actual_sha &&
      summary.fetch('helper_sha256_observed_before_execute') == actual_sha &&
      summary.fetch('helper_sha256_observed_after_execute') == actual_sha,
      'prebuilt helper hash differs from external SHA-256 pin or captured observations')
    input_path = File.join(root, 'generated', 'helper-input.json')
    input_bytes = read_file(input_path, root)
    input_sha = Digest::SHA256.hexdigest(input_bytes)
    require_true(input_sha == summary.fetch('helper_input_sha256'), 'helper input SHA-256 differs from summary')
    input = JSON.parse(input_bytes.force_encoding(Encoding::UTF_8))
    require_true(input.keys.sort == %w[capture_root format profiles] && input.fetch('format') == W::FORMAT_INPUT &&
      input.fetch('capture_root') == source_root && input.fetch('profiles').length == profiles.length,
      'helper input top-level contract differs')
    require_true(argv_record.fetch('environment') == { 'TZ' => 'UTC' } &&
      argv_record.fetch('timeout_seconds') == R::HELPER_TIMEOUT_SECONDS && argv_record['stdin_bytes'].nil? &&
      argv_record['stdin_sha256'].nil? && process.fetch('stdin').nil? && process.fetch('sql') == "\n" &&
      argv_record.fetch('argv') == [helper, input_path, File.join(root, 'generated'), source_root],
      'helper raw invocation argv/environment/paths differ')
    helper_process = json_file(File.join(root, 'generated', 'helper-process.json'), root)
    require_true(helper_process == record_from_status(process), 'runner helper-process carrier differs from raw status')
    raw_output = json_file(File.join(root, 'generated', 'helper-output.json'), root)
    stdout_output = JSON.parse(process.fetch('stdout').force_encoding(Encoding::UTF_8))
    require_true(stdout_output == raw_output && raw_output.fetch('format') == W::FORMAT_HELPER &&
      raw_output.fetch('profile_count') == profiles.length && raw_output.fetch('observed_count') == profiles.length &&
      raw_output.fetch('mismatch_count') == 0 && raw_output.fetch('profiles').map { |item| item.fetch('id') } == W::PROFILE_IDS,
      'raw helper stdout/output file format, counts, or roster differs')

    profiles.each_with_index do |profile, index|
      id = profile.fetch('id')
      source_item = matrix.fetch('profiles').fetch(index)
      expected_input = expected_helper_input_profile(profile, index, source_item.fetch('source_part'), root)
      input_profile = input.fetch('profiles').fetch(index)
      require_true(input_profile.keys.sort == expected_input.keys.sort && input_profile == expected_input,
        "helper input profile differs from independent fixture: #{id}")
      destination = expected_input.fetch('librarydest')
      expected_output = raw_output.fetch('profiles').fetch(index)
      require_true(expected_output.keys.sort == %w[classification declared_type encoded_literal_lanes exact_nominal_states
        id independent_lanes library library_consumers librarydest mark_rows metadata_values profile row_keys rowbinary
        stock stock_consumers stockpart tagged_state_values],
        "helper output profile field set differs: #{id}")
      require_true(expected_output.fetch('classification') == 'generic_stock_read_library_write_read_observed' &&
        expected_output.fetch('declared_type') == profile.fetch('declared_type') && expected_output.fetch('profile') == profile.fetch('profile') &&
        expected_output.fetch('row_keys') == profile.fetch('row_keys') && expected_output.fetch('mark_rows') == profile.fetch('mark_rows') &&
        expected_output.fetch('stockpart') == source_item.fetch('source_part') && expected_output.fetch('librarydest') == destination &&
        expected_output.fetch('metadata_values') == profile.fetch('metadata') && expected_output.fetch('tagged_state_values') == profile.fetch('values') &&
        expected_output.fetch('independent_lanes') == profile.fetch('expected_lanes') && expected_output.fetch('exact_nominal_states') == true,
        "helper output logical values/declaration/path binding differs: #{id}")
      require_true(expected_output.fetch('rowbinary') == profile.fetch('rowbinary').merge('matches_independent_literals' => true),
        "helper RowBinary fixture differs from independent literals: #{id}")
      encoded_lanes = expected_output.fetch('encoded_literal_lanes')
      require_true(encoded_lanes == profile.fetch('expected_lanes'), "helper codec-vs-literal lanes differ: #{id}")
      assert_helper_part!(expected_output.fetch('stock'), source_item.fetch('source_part'), profile, 'stock')
      assert_helper_part!(expected_output.fetch('library'), destination, profile, 'library')
      assert_consumer!(expected_output.fetch('stock_consumers'), profile, 'stock')
      assert_consumer!(expected_output.fetch('library_consumers'), profile, 'library')

      generated = inventory(destination)
      stock_copy = inventory(source_item.fetch('source_part'))
      case_path = File.join(root, 'cases', "#{id}-helper.json")
      helper_case = json_file(case_path, root)
      require_true(helper_case.keys.sort == %w[classification declared_type generated_part_inventory helper_output_profile id librarydest profile stock_inventory stockpart] &&
        helper_case.fetch('id') == id && helper_case.fetch('classification') == 'generic_stock_read_library_write_read_observed' &&
        helper_case.fetch('declared_type') == profile.fetch('declared_type') && helper_case.fetch('profile') == profile.fetch('profile') &&
        helper_case.fetch('stockpart') == source_item.fetch('source_part') && helper_case.fetch('librarydest') == destination &&
        helper_case.fetch('stock_inventory') == stock_copy && helper_case.fetch('generated_part_inventory') == generated,
        "helper per-case inventory carrier differs: #{id}")
      require_true(generated == helper_case.fetch('generated_part_inventory') &&
        stock_copy == source_item.fetch('source_inventory') && helper_case.fetch('stock_inventory') == stock_copy,
        "helper runner-computed inventories differ from actual parts: #{id}")
      case_output = helper_case.fetch('helper_output_profile')
      case_output_raw = case_output.reject { |key, _| %w[generated_part_inventory stock_part_inventory].include?(key) }
      require_true(case_output.fetch('generated_part_inventory') == generated && case_output.fetch('stock_part_inventory') == stock_copy &&
        case_output_raw == expected_output,
        "helper raw-output and case-carrier relationship differs: #{id}")
    end
  end

  def assert_native_profiles!(root, profiles, invocations, helper_output)
    profiles.each_with_index do |profile, index|
      id = profile.fetch('id')
      table = "w225_#{id}"
      store = File.join(root, 'stores', 'native', id)
      create = invocations.fetch("native-create-#{id}")
      data_path_record = invocations.fetch("native-data-path-#{id}")
      attach = invocations.fetch("native-attach-#{id}")
      check = invocations.fetch("native-check-#{id}")
      metadata = invocations.fetch("native-metadata-#{id}")
      census = invocations.fetch("native-part-#{id}")
      type_name = invocations.fetch("native-type-name-#{id}")
      assert_sql!(create, expected_create_sql(profile, table), "native-create-#{id}")
      assert_sql!(data_path_record, "SELECT arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw", "native-data-path-#{id}")
      assert_sql!(attach, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'", "native-attach-#{id}")
      assert_sql!(check, "CHECK TABLE default.#{table} FORMAT TSVRaw", "native-check-#{id}")
      assert_sql!(metadata, "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw", "native-metadata-#{id}")
      assert_sql!(census, "SELECT name, toString(rows), toString(marks), part_type, path FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw", "native-part-#{id}")
      assert_sql!(type_name, "SELECT toTypeName(v) FROM default.#{table} LIMIT 1 FORMAT TSVRaw", "native-type-name-#{id}")
      raw_data_path = data_path_record.fetch('stdout').sub(/\n\z/, '')
      data_path = File.expand_path(raw_data_path)
      require_true([data_path, data_path + File::SEPARATOR].include?(raw_data_path) &&
        data_path.start_with?(store + File::SEPARATOR) && File.directory?(data_path) && !File.symlink?(data_path) &&
        File.realpath(data_path) == data_path, "native system.tables path escaped or is noncanonical: #{id}")
      detached = File.join(data_path, 'detached')
      attached = File.join(data_path, 'all_1_1_0')
      require_true(File.directory?(detached) && !File.symlink?(detached) && File.realpath(detached) == detached,
        "native detached directory is invalid: #{id}")
      helper_case = json_file(File.join(root, 'cases', "#{id}-helper.json"), root)
      generated_inventory = helper_case.fetch('generated_part_inventory')
      require_true(check.fetch('stdout') == EXPECTED_CHECK &&
        metadata.fetch('stdout') == "pk\tUInt64\nv\t#{profile.fetch('declared_type')}\n" &&
        type_name.fetch('stdout') == "#{profile.fetch('declared_type')}\n",
        "native CHECK/schema/type-name raw output differs: #{id}")
      assert_part_census!(census.fetch('stdout'), attached, "native/#{id}")
      attached_inventory = inventory(attached)
      before = generated_inventory.each_with_object({}) { |entry, map| map[entry.fetch('path')] = entry }
      after = attached_inventory.each_with_object({}) { |entry, map| map[entry.fetch('path')] = entry }
      removed = before.keys - after.keys
      changed = before.keys.select { |path| after.key?(path) && before.fetch(path) != after.fetch(path) }
      added = after.keys - before.keys
      require_true(removed.empty? && changed.empty? && added == [INVALIDATED_FILE], "native ATTACH file delta differs: #{id}")
      aux_lines = read_file(File.join(attached, INVALIDATED_FILE), root).split("\n", -1)
      require_true(aux_lines.pop == '' && aux_lines.sort == INVALIDATED_NAMES.sort, "native invalidated-system-columns file differs: #{id}")
      columns = read_file(File.join(attached, 'columns.txt'), root).force_encoding(Encoding::UTF_8)
      expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`v` #{profile.fetch('declared_type')}\n"
      serialization = json_file(File.join(attached, 'serialization.json'), root)
      expected_serialization = { 'columns' => [{ 'exact_num_defaults' => true, 'kind' => 'Default', 'name' => 'pk',
          'num_defaults' => 0, 'num_rows' => 5 }],
        'propagate_types_serialization_versions_to_nested_types' => true,
        'types_serialization_versions' => { 'string' => STRING_VERSIONS.fetch(profile.fetch('profile')) }, 'version' => 1 }
      require_true(columns == expected_columns && serialization == expected_serialization &&
        read_file(File.join(attached, 'metadata_version.txt'), root).strip == '0' &&
        read_file(File.join(attached, 'default_compression_codec.txt'), root).strip == 'CODEC(LZ4)' &&
        read_file(File.join(attached, 'count.txt'), root).strip == '5',
        "native attached nominal files/serialization metadata differ: #{id}")

      case_path = File.join(root, 'cases', "#{id}-attached.json")
      attached_case = json_file(case_path, root)
      required = { 'id' => id, 'classification' => 'native_attached_and_check_observed',
        'declared_type' => profile.fetch('declared_type'), 'native_type' => profile.fetch('declared_type'),
        'canonicalization' => 'exact_declared_type', 'native_schema' => ["pk\tUInt64", "v\t#{profile.fetch('declared_type')}"],
        'stock_part_inventory' => helper_case.fetch('stock_inventory'), 'generated_part_inventory' => generated_inventory,
        'detached_part_inventory' => generated_inventory,
        'attached_part_inventory' => attached_inventory, 'removed_paths' => removed, 'changed_paths' => changed,
        'added_paths' => added, 'columns_txt' => columns, 'serialization_json' => serialization,
        'string_serialization_profile' => profile.fetch('profile'),
        'string_serialization_version_expected' => STRING_VERSIONS.fetch(profile.fetch('profile')),
        'string_serialization_version_observed' => serialization.fetch('types_serialization_versions').fetch('string'),
        'variant_discriminator_mode' => 'BASIC', 'metadata_version' => '0', 'codec' => 'CODEC(LZ4)',
        'check_output' => check.fetch('stdout') }
      require_true(attached_case.keys.sort == %w[added_paths attached_part_inventory canonicalization changed_paths check_output classification
        codec columns_txt declared_type detached_part_inventory generated_part_inventory id metadata_version native_schema native_type
        processes removed_paths rowbinary_windows serialization_json stock_part_inventory string_serialization_profile
        string_serialization_version_expected string_serialization_version_observed variant_discriminator_mode],
        "native per-profile case fields differ: #{id}")
      required.each { |key, value| require_true(attached_case.fetch(key) == value, "native case #{key} differs: #{id}") }
      expected_labels_for_case = ["native-data-path-#{id}", "native-attach-#{id}", "native-check-#{id}",
        "native-metadata-#{id}", "native-part-#{id}", "native-type-name-#{id}"]
      require_true(attached_case.fetch('processes') == expected_labels_for_case.map { |label| record_from_status(invocations.fetch(label)) },
        "native case process carrier differs from raw status sidecars: #{id}")
      windows = attached_case.fetch('rowbinary_windows')
      require_true(windows.keys.sort == %w[empty full middle], "native RowBinary windows roster differs: #{id}")
      %w[full middle empty].each do |window|
        output_path = File.join(root, 'cases', "#{id}-#{window}.rowbinary")
        assert_rowbinary_window!(windows.fetch(window), invocations.fetch("native-rowbinary-#{id}-#{window}"),
          profile, window, output_path, table, 'native', root)
      end
      require_true(helper_output.fetch('profiles').fetch(index).fetch('declared_type') == attached_case.fetch('declared_type'),
        "native type no longer binds to helper output: #{id}")
    end
  end

  def audit(root_path, expected_helper_sha256)
    expected_helper_sha256 = validate_sha256_pin!(expected_helper_sha256, 'expected helper SHA-256')
    root = canonical_root(root_path, W::EVIDENCE_PREFIX, 'W225 evidence root')
    summary = json_file(File.join(root, 'summary.json'), root)
    require_true(summary.keys.sort == %w[classification counts error evidence_root format helper_input_sha256 helper_sha256_expected
      helper_sha256_observed_after_execute helper_sha256_observed_at_start helper_sha256_observed_before_execute mode
      process_status_counts runtime_pin source_matrix_sha256 source_pin source_root success] &&
      summary.fetch('format') == W::FORMAT_SUMMARY && summary.fetch('mode') == 'paired' &&
      summary.fetch('classification') == 'paired_variant_profiles_observed' && summary.fetch('success') == true &&
      summary['error'].nil? && summary.fetch('evidence_root') == root,
      'W225 runner summary is not a successful paired observation')
    source_root = canonical_root(summary.fetch('source_root'), W::SOURCE_PREFIX, 'W225 stock source root')
    matrix_path = File.join(source_root, 'matrix.json')
    matrix_bytes = read_file(matrix_path, source_root)
    require_true(Digest::SHA256.hexdigest(matrix_bytes) == summary.fetch('source_matrix_sha256'),
      'stock matrix digest differs from summary')
    matrix = JSON.parse(matrix_bytes.force_encoding(Encoding::UTF_8))
    source_pin = assert_source_pin!(source_root, matrix, summary)
    require_true(matrix.fetch('runtime_pin') == summary.fetch('runtime_pin'), 'runtime pin differs between matrix and summary')

    profiles = W.profile_definitions
    require_true(profiles.map { |profile| profile.fetch('id') } == W::PROFILE_IDS && profiles.length == 7,
      'independent W225 finite profile roster differs')
    invocations = invocation_index(root)
    assert_process_roster!(invocations, profiles)
    binary = assert_runtime!(source_root, summary, invocations)
    assert_clickhouse_argv!(invocations, binary, root, source_root, profiles)
    assert_source_profiles!(source_root, matrix, profiles, invocations)
    assert_helper_and_generated_parts!(root, source_root, profiles, matrix, invocations, summary, expected_helper_sha256)
    helper_output = json_file(File.join(root, 'generated', 'helper-output.json'), root)
    assert_native_profiles!(root, profiles, invocations, helper_output)

    statuses = invocations.values.map { |item| item.fetch('status').fetch('classification') }
    counts = summary.fetch('counts')
    require_true(counts == { 'expected_profiles' => 7, 'stock_observed' => 7, 'helper_observed' => 7,
      'native_attached_exact_nominal' => 7, 'processes' => invocations.length } &&
      invocations.length == 136 && summary.fetch('process_status_counts') == {
        'success_exit0' => statuses.count { |status| status == 'process_success' },
        'nonzero_or_signaled' => statuses.count { |status| status == 'process_nonzero_or_signaled_exit' },
        'timeout' => statuses.count { |status| status == 'process_timeout' },
        'spawn_failure' => statuses.count { |status| status == 'spawn_failure' },
      } && statuses.all? { |status| status == 'process_success' },
      'summary profile/process counts disagree with raw invocation statuses')
    puts "W225 evidence audit ROBUST: profiles=7; processes=136; helper_sha256=#{expected_helper_sha256}; evidence=#{root}"
    true
  rescue StandardError => error
    warn "W225 evidence audit failed: #{error.class}: #{error.message}"
    false
  end

  def main(argv)
    unless argv.length == 2
      warn 'Usage: ruby scripts/check_aggregate_variant_evidence_w225.rb EVIDENCE_ROOT EXPECTED_HELPER_SHA256'
      return false
    end
    audit(argv.fetch(0), argv.fetch(1))
  end
end

exit(CheckAggregateVariantEvidenceW225.main(ARGV) ? 0 : 1) if $PROGRAM_NAME == __FILE__
