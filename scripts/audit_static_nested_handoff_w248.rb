#!/usr/bin/env ruby
# Read-only authentication for a bounded W248 static Nested handoff capture.
# The audit reopens only the named evidence files and the two captured PARTs;
# it never starts ClickHouse or the helper.

require 'digest'
require 'json'
require 'optparse'
require_relative 'probe_static_nested_handoff_w248'

module AuditStaticNestedHandoffW248
  extend self

  W248 = ProbeStaticNestedHandoffW248
  W241 = W248::W241
  # W248's accepted W241-identical runtime is supplied via --binary. Pin its
  # canonical observed path independently here instead of inheriting W241's
  # historical default path; bytes and semantic identity remain W241-pinned.
  RUNTIME_PATH = '/private/tmp/crystal-click-w216-runtime-recovery.DmL9Kw/clickhouse-stripped'.freeze
  FORMAT = W248::FORMAT
  HELPER_FORMAT = W248::HELPER_FORMAT
  SUMMARY_KEYS = %w[
    evidence_root expected_signatures fatal_error format frame_bytes helper helper_mode
    helper_reports interpretation invocations keys limits literal_rows mark_row_counts native
    parts runtime schema source_closures status string_profile
  ].sort.freeze
  REPORT_KEYS = %w[
    action files format frame_bytes keys nominal_binary_columns parent_mark_row_counts part
    physical_mark_files profile recursive_nested_site_marks row_count
    variant_discriminator_prefixes consumer_signatures
  ].sort.freeze
  INVOCATION_KEYS = W248::PROCESS_KEYS.sort.freeze
  TARGET_COLUMNS = W248::TARGET_COLUMNS
  ALL_COLUMNS = W248::TYPES.keys.freeze
  TYPE_TAGS = {
    'root_nested' => 0x2f,
    'array_parent' => 0x20,
    'recursive_nested' => 0x2f,
    'string0' => 0x15,
    'string1' => 0x15,
  }.freeze
  VARIANT_SITE_PATHS = {
    'root_nested' => 'root_nested.choice',
    'array_parent' => 'array_parent.batches[].choice',
    'recursive_nested' => 'recursive_nested.choice',
  }.freeze
  RECURSIVE_MARKS = {
    'root.elements.field.0.indexes' => {
      'site_path' => 'recursive_nested.label',
      'site_type' => 'LowCardinality(Nullable(String))',
      'first_decompressed' => 0,
    },
    'root.elements.field.1.discriminators' => {
      'site_path' => 'recursive_nested.choice',
      'site_type' => 'Variant(String, UInt64)',
      'first_decompressed' => 8,
    },
  }.freeze
  TAG_PIN = '__W241_PIN__'
  TAG_PATH = '__W248_PATH__'
  TAG_CHECK_BEGIN = '__W248_CHECK_BEGIN__'
  TAG_CHECK_END = '__W248_CHECK_END__'
  TAG_SCHEMA = '__W248_SCHEMA__'
  TAG_PART = '__W248_PART__'
  TAG_ROWS = '__W248_ROWS__'
  MAX_SUMMARY_BYTES = 16 * 1024 * 1024
  MAX_RECORD_BYTES = 1 * 1024 * 1024
  MAX_IO_BYTES = 16 * 1024 * 1024
  MAX_PART_FILES = 4096
  MAX_PART_FILE_BYTES = W241::Auditor::MAX_PART_FILE_BYTES
  MAX_PART_TOTAL_BYTES = 64 * 1024 * 1024
  MARK_SIZE = 24

  class AuditError < StandardError; end

  def require!(condition, message)
    raise AuditError, "W248 audit: #{message}" unless condition
  end

  def sha256(bytes)
    Digest::SHA256.hexdigest(bytes)
  end

  def file_sha256(path, label)
    require!(File.file?(path) && !File.symlink?(path), "#{label} is absent, non-regular, or symlinked")
    Digest::SHA256.file(path).hexdigest
  end

  def read_plain(path, limit, label)
    require!(File.file?(path) && !File.symlink?(path), "#{label} is absent, non-regular, or symlinked")
    stat = File.lstat(path)
    require!(stat.file? && stat.size <= limit, "#{label} is non-regular or exceeds #{limit} bytes")
    bytes = File.binread(path)
    require!(bytes.bytesize == stat.size, "#{label} changed while reading")
    bytes
  end

  def canonical_root(path)
    require!(path.is_a?(String) && !path.empty? && !File.symlink?(path), 'evidence root is absent or symlinked')
    expanded = File.expand_path(path)
    full = File.realpath(expanded)
    require!(File.directory?(full) && full == expanded, 'evidence root is not a canonical directory')
    require!(File.dirname(full) == File.realpath('/private/tmp'), 'evidence root is not a direct child of /private/tmp')
    full
  rescue SystemCallError => error
    raise AuditError, "W248 audit: evidence root cannot be resolved: #{error.message}"
  end

  def canonical_directory(path, label, beneath: nil)
    require!(path.is_a?(String) && !path.empty? && !File.symlink?(path), "#{label} is absent or symlinked")
    expanded = File.expand_path(path)
    if beneath
      base = File.realpath(beneath)
      require!(expanded.start_with?(base + File::SEPARATOR), "#{label} escaped its bound root")
      current = base
      expanded.delete_prefix(base + File::SEPARATOR).split(File::SEPARATOR).each do |component|
        current = File.join(current, component)
        next unless File.exist?(current) || File.symlink?(current)
        require!(!File.lstat(current).symlink?, "symlink in #{label}: #{current}")
        require!(File.directory?(current), "non-directory in #{label}: #{current}") if current != expanded
      end
    end
    full = File.realpath(expanded)
    require!(File.directory?(full) && full == expanded, "#{label} is not a canonical directory")
    full
  rescue SystemCallError => error
    raise AuditError, "W248 audit: #{label} cannot be resolved: #{error.message}"
  end

  def canonical_file(path, label)
    require!(path.is_a?(String) && !path.empty? && !File.symlink?(path), "#{label} path is absent or symlinked")
    expanded = File.expand_path(path)
    full = File.realpath(expanded)
    require!(File.file?(full) && full == expanded, "#{label} is not a canonical regular file")
    full
  rescue SystemCallError => error
    raise AuditError, "W248 audit: #{label} cannot be resolved: #{error.message}"
  end

  def expected_schema
    ([W248::KEY] + W248::TYPES.map { |name, type| {'name' => name, 'type' => type} })
      .map { |column| [column.fetch('name'), column.fetch('type')] }
  end

  def expected_signatures
    W248.expected_signatures.transform_values do |values|
      values.map { |value| value.dup.force_encoding(Encoding::UTF_8) }
    end
  end

  def probe_adapter(profile, root, input_table, write_table)
    probe = W248::Probe.allocate
    probe.instance_variable_set(:@profile, profile)
    probe.instance_variable_set(:@root, root)
    probe.instance_variable_set(:@input_table, input_table)
    probe.instance_variable_set(:@write_table, write_table)
    probe
  end

  def native_prefix
    probe = W241::Probe.allocate
    [probe.send(:pin_sql), 'SET print_pretty_type_names=0;',
     'SET output_format_json_quote_64bit_integers=0;'].join("\n")
  end

  def native_input(sql)
    "#{native_prefix}\n#{sql}\n".b
  end

  def expected_native_sql(profile, root, input_table, write_table)
    probe = probe_adapter(profile, root, input_table, write_table)
    native_store = File.join(root, 'stores', 'native')
    input_create = probe.send(:create_table_sql, input_table)
    write_create = probe.send(:create_table_sql, write_table)
    attach = [
      "ALTER TABLE default.#{input_table} ATTACH PART '#{W248::PART_NAME}';",
      "SELECT '#{TAG_CHECK_BEGIN}' FORMAT TSVRaw;",
      "CHECK TABLE default.#{input_table} FORMAT TSV;",
      "SELECT '#{TAG_CHECK_END}' FORMAT TSVRaw;",
      probe.send(:schema_query, input_table),
      probe.send(:parts_query, input_table),
      probe.send(:rows_query, input_table),
    ].join("\n")
    stock_write = [
      'SET materialize_statistics_on_insert=0;', probe.send(:stock_insert_sql),
      "SELECT '#{TAG_CHECK_BEGIN}' FORMAT TSVRaw;",
      "CHECK TABLE default.#{write_table} FORMAT TSV;",
      "SELECT '#{TAG_CHECK_END}' FORMAT TSVRaw;",
      probe.send(:schema_query, write_table),
      probe.send(:parts_query, write_table),
      probe.send(:rows_query, write_table),
    ].join("\n")
    {
      'native_create_input' => native_input(input_create),
      'native_attach_check_rows' => native_input(attach),
      'native_create_stock_write' => native_input(write_create),
      'native_stock_write_check_rows' => native_input(stock_write),
    }
  end

  def expected_invocation_labels
    %w[
      helper_write native_create_input native_attach_check_rows native_create_stock_write
      native_stock_write_check_rows helper_inspect_stock_part
    ]
  end

  def validate_schema!(actual, expected, label)
    require!(actual == expected, "#{label} schema/order differs")
  end

  def validate_nominal_columns!(columns, profile, signatures)
    require!(columns.is_a?(Hash) && columns.keys.sort == ALL_COLUMNS.sort, 'helper nominal column roster differs')
    columns.each do |name, entry|
      require!(entry.is_a?(Hash) && entry.keys.sort == %w[mark_row_counts profile row_signatures tag type variant_sites],
        "helper nominal descriptor fields differ for #{name}")
      require!(entry['type'] == W248::TYPES.fetch(name) && entry['tag'] == TYPE_TAGS.fetch(name),
        "helper nominal type/tag differs for #{name}")
      site = VARIANT_SITE_PATHS[name]
      variants = if site
        [{'path' => site, 'type' => 'Variant(String, UInt64)', 'tag' => 42,
          'arms' => %w[String UInt64]}]
      else
        []
      end
      require!(entry['variant_sites'] == variants, "helper Variant site roster differs for #{name}")
      require!(entry['profile'] == profile && entry['mark_row_counts'] == W248::MARK_ROWS,
        "helper profile/mark grid differs for #{name}")
      require!(entry['row_signatures'] == signatures.fetch(name), "helper direct signatures differ for #{name}")
    end
  end

  def validate_variant_prefixes!(entries, inventories, stream_rosters)
    require!(entries.is_a?(Array) && entries.size == TARGET_COLUMNS.size, 'helper Variant prefix witness count differs')
    by_column = entries.to_h do |entry|
      require!(entry.is_a?(Hash), 'helper Variant prefix witness is malformed')
      [entry.fetch('column'), entry]
    end
    require!(by_column.keys.sort == TARGET_COLUMNS.sort, 'helper Variant prefix columns differ')
    expected_keys = %w[
      arms column decoded_bytes file logical_stream mode mode_word nominal_tag nominal_type prefix_hex
      role site_path site_tag site_type
    ].sort
    by_column.each do |column, entry|
      require!(entry.keys.sort == expected_keys, "helper Variant prefix fields differ for #{column}")
      require!(entry['nominal_type'] == W248::TYPES.fetch(column) &&
               entry['nominal_tag'] == TYPE_TAGS.fetch(column), "helper outer nominal type/tag differs for #{column}")
      require!(entry['site_path'] == VARIANT_SITE_PATHS.fetch(column) &&
               entry['site_type'] == 'Variant(String, UInt64)' && entry['site_tag'] == 42 &&
               entry['arms'] == %w[String UInt64], "helper inner Variant site differs for #{column}")
      require!(entry['decoded_bytes'].is_a?(Integer) &&
               entry['decoded_bytes'] >= 8, "helper actual BASIC discriminator prefix differs for #{column}")
      role = entry['role']
      require!(role.is_a?(String) && role.end_with?('.field.1.discriminators'),
        "helper discriminator role does not identify the choice field for #{column}")
      verify_logical_file_binding!(entry, '.bin', inventories, stream_rosters, "Variant #{column}")
    end
    validate_prefix_literals!(entries)
  rescue KeyError => error
    raise AuditError, "W248 audit: malformed Variant prefix witness: #{error.message}"
  end

  def validate_recursive_marks!(entries, inventories, stream_rosters)
    require!(entries.is_a?(Array) && entries.size == RECURSIVE_MARKS.size,
      'helper recursive Nested mark witness count differs')
    by_role = entries.to_h do |entry|
      require!(entry.is_a?(Hash), 'helper recursive Nested mark witness is malformed')
      [entry.fetch('role'), entry]
    end
    require!(by_role.keys.sort == RECURSIVE_MARKS.keys.sort, 'helper recursive Nested role roster differs')
    expected_keys = %w[
      first_mark_zero first_populated_mark_advances file logical_stream marks nominal_tag nominal_type
      role site_path site_type
    ].sort
    by_role.each do |role, entry|
      require!(entry.keys.sort == expected_keys, "recursive Nested mark fields differ for #{role}")
      descriptor = RECURSIVE_MARKS.fetch(role)
      require!(entry['nominal_type'] == W248::TYPES.fetch('recursive_nested') && entry['nominal_tag'] == 0x2f &&
               entry['site_path'] == descriptor.fetch('site_path') && entry['site_type'] == descriptor.fetch('site_type'),
        "recursive Nested nominal/site identity differs for #{role}")
      require!(entry['first_mark_zero'] == true && entry['first_populated_mark_advances'] == true,
        "recursive Nested first-empty-mark witness differs for #{role}")
      verify_logical_file_binding!(entry, '.mrk2', inventories, stream_rosters, "recursive mark #{role}")
      file = entry.fetch('file')
      bytes = read_plain(File.join(@current_part_paths.fetch(@active_inventory_key), file),
                         MAX_PART_FILE_BYTES, "recursive mark file #{file}")
      physical_marks = parse_mark_file(bytes, file)
      require!(entry['marks'] == physical_marks, "reported recursive mark coordinates differ from physical #{file}")
      validate_first_mark_coordinates!(physical_marks, descriptor, role)
    end
  rescue KeyError => error
    raise AuditError, "W248 audit: malformed recursive Nested mark witness: #{error.message}"
  end

  def validate_first_mark_coordinates!(marks, descriptor, role)
    require!(marks.size == 4 && marks.map(&:last) == W248::MARK_ROWS_WITH_EOF,
      "recursive mark row grid differs for #{role}")
    first = marks[0]
    second = marks[1]
    third = marks[2]
    require!(first[0] == 0 && first[1] == descriptor.fetch('first_decompressed') &&
             first[0, 2] == second[0, 2], "recursive mark-zero Q0 coordinate differs for #{role}")
    require!(first[2] == 2 && (second[0] != third[0] || second[1] != third[1]),
      "recursive first populated mark does not advance for #{role}")
  end

  def validate_variant_values!(actual, expected, label)
    require!(actual == expected, "#{label} literal values or Variant type witnesses differ")
  end

  def validate_invocation_roster!(records, labels)
    require!(records.is_a?(Array) && records.map { |record| record['label'] } == labels &&
             records.map { |record| record['label'] }.uniq == labels,
      'invocation roster is incomplete, duplicated, or out of order')
  end

  def validate_process_status!(record, label)
    require!(record.is_a?(Hash) && record['process_classification'] == 'success' && record['exit'] == 0 &&
             record['signal'].nil? && record['timed_out'] == false && record['spawn_error'].nil? &&
             record['stdin_write_error'].nil? && record['stdout_read_error'].nil? &&
             record['stderr_read_error'].nil?, "#{label} raw process status is not successful")
  end

  def expect_rejection!(label, expected_message = nil)
    yield
    raise AuditError, "W248 auditor self-test failed to reject #{label}"
  rescue AuditError => error
    raise if error.message.include?('self-test failed to reject')
    if expected_message && !error.message.include?(expected_message)
      raise AuditError, "W248 auditor self-test rejected #{label} for the wrong reason: #{error.message}"
    end
    true
  end

  def validate_attached_file_identity!(generated_files, attached_files, metadata_bytes)
    require!(generated_files.is_a?(Array) && attached_files.is_a?(Array),
      'ATTACH file inventories are malformed')
    source = generated_files.each_with_object({}) do |entry, map|
      require!(entry.is_a?(Hash) && entry.keys.sort == %w[path sha256 size],
        'generated PART inventory entry is malformed')
      require!(entry['path'].is_a?(String) && !map.key?(entry['path']),
        'generated PART inventory has duplicate paths')
      map[entry['path']] = [entry['size'], entry['sha256']]
    end
    target = attached_files.each_with_object({}) do |entry, map|
      require!(entry.is_a?(Hash) && entry.keys.sort == %w[path sha256 size],
        'attached PART inventory entry is malformed')
      require!(entry['path'].is_a?(String) && !map.key?(entry['path']),
        'attached PART inventory has duplicate paths')
      map[entry['path']] = [entry['size'], entry['sha256']]
    end
    marker = W248::ATTACH_METADATA_FILE
    require!(target.keys.sort == (source.keys + [marker]).uniq.sort,
      'ATTACH changed the part inventory beyond expected invalidation metadata')
    source.each do |name, identity|
      require!(target[name] == identity, "ATTACH altered generated part file #{name}")
    end
    marker_identity = [W248::ATTACH_METADATA_BYTES.bytesize, sha256(W248::ATTACH_METADATA_BYTES)]
    require!(metadata_bytes == W248::ATTACH_METADATA_BYTES && target[marker] == marker_identity,
      'ATTACH invalidation metadata differs from the exact pinned marker bytes')
    true
  end

  def self_test!
    schema = expected_schema
    validate_schema!(schema, schema, 'self-test')
    expect_rejection!('wrong schema') { validate_schema!(schema + [['wrong', 'UInt8']], schema, 'self-test') }

    nominal = W248::TYPES.to_h do |name, type|
      variants = if (site = VARIANT_SITE_PATHS[name])
        [{'path' => site, 'type' => 'Variant(String, UInt64)', 'tag' => 42, 'arms' => %w[String UInt64]}]
      else
        []
      end
      [name, {'type' => type, 'tag' => TYPE_TAGS.fetch(name), 'variant_sites' => variants,
              'profile' => 'single', 'mark_row_counts' => W248::MARK_ROWS,
              'row_signatures' => expected_signatures.fetch(name)}]
    end
    validate_nominal_columns!(nominal, 'single', expected_signatures)
    wrong_nominal = Marshal.load(Marshal.dump(nominal))
    wrong_nominal.fetch('root_nested')['type'] = 'Array(Tuple(...))'
    expect_rejection!('wrong nominal type') { validate_nominal_columns!(wrong_nominal, 'single', expected_signatures) }

    prefix_entries = TARGET_COLUMNS.map do |column|
      {'column' => column, 'nominal_type' => W248::TYPES.fetch(column), 'nominal_tag' => TYPE_TAGS.fetch(column),
       'site_path' => VARIANT_SITE_PATHS.fetch(column), 'site_type' => 'Variant(String, UInt64)',
       'site_tag' => 42, 'arms' => %w[String UInt64], 'role' => 'root.elements.field.1.discriminators',
       'logical_stream' => "#{column}.discriminators", 'file' => 'dummy.bin', 'decoded_bytes' => 8,
       'prefix_hex' => '0000000000000000', 'mode_word' => 0, 'mode' => 'BASIC'}
    end
    # Prefix semantics are exercised by the focused predicate below; physical
    # binding remains covered by the full evidence audit.
    expect_rejection!('wrong Variant prefix') do
      changed = Marshal.load(Marshal.dump(prefix_entries))
      changed.first['prefix_hex'] = '0100000000000000'
      validate_prefix_literals!(changed)
    end
    validate_prefix_literals!(prefix_entries)

    values = expected_signatures
    validate_variant_values!(values, values, 'self-test')
    expect_rejection!('wrong literal value') do
      changed = Marshal.load(Marshal.dump(values))
      changed.fetch('root_nested')[0] = 'wrong'
      validate_variant_values!(changed, values, 'self-test')
    end
    labels = expected_invocation_labels
    sample_records = labels.map { |label| {'label' => label} }
    validate_invocation_roster!(sample_records, labels)
    expect_rejection!('omitted invocation') do
      validate_invocation_roster!(sample_records[0...-1], labels)
    end
    success_record = {'process_classification' => 'success', 'exit' => 0, 'signal' => nil,
                      'timed_out' => false, 'spawn_error' => nil, 'stdin_write_error' => nil,
                      'stdout_read_error' => nil, 'stderr_read_error' => nil}
    validate_process_status!(success_record, 'self-test')
    expect_rejection!('wrong raw status') do
      validate_process_status!(success_record.merge('exit' => 1, 'process_classification' => 'failed'), 'self-test')
    end

    generated_files = [{'path' => 'columns.txt', 'size' => 3, 'sha256' => sha256('abc')}]
    marker_file = {'path' => W248::ATTACH_METADATA_FILE,
                   'size' => W248::ATTACH_METADATA_BYTES.bytesize,
                   'sha256' => sha256(W248::ATTACH_METADATA_BYTES)}
    attached_files = generated_files + [marker_file]
    validate_attached_file_identity!(generated_files, attached_files, W248::ATTACH_METADATA_BYTES)
    expect_rejection!('missing invalidation marker', 'ATTACH changed the part inventory beyond expected invalidation metadata') do
      validate_attached_file_identity!(generated_files, generated_files, W248::ATTACH_METADATA_BYTES)
    end
    wrong_marker = "_block_offset\n_block_numberX\n".b
    wrong_marker_file = {'path' => W248::ATTACH_METADATA_FILE, 'size' => wrong_marker.bytesize,
                         'sha256' => sha256(wrong_marker)}
    expect_rejection!('wrong invalidation marker bytes', 'ATTACH invalidation metadata differs from the exact pinned marker bytes') do
      validate_attached_file_identity!(generated_files, generated_files + [wrong_marker_file], wrong_marker)
    end
    arbitrary_file = {'path' => 'extra.bin', 'size' => 1, 'sha256' => sha256('x')}
    expect_rejection!('arbitrary ATTACH extra file', 'ATTACH changed the part inventory beyond expected invalidation metadata') do
      validate_attached_file_identity!(generated_files, attached_files + [arbitrary_file], W248::ATTACH_METADATA_BYTES)
    end
    changed_generated = [{'path' => 'columns.txt', 'size' => 4, 'sha256' => sha256('abcd')}]
    expect_rejection!('ATTACH changed original file', 'ATTACH altered generated part file columns.txt') do
      validate_attached_file_identity!(generated_files, changed_generated + [marker_file], W248::ATTACH_METADATA_BYTES)
    end
    true
  end

  def validate_prefix_literals!(entries)
    require!(entries.is_a?(Array) && entries.size == TARGET_COLUMNS.size, 'Variant prefix witness count differs')
    entries.each do |entry|
      require!(entry['prefix_hex'] == '0000000000000000' && entry['mode_word'] == 0 && entry['mode'] == 'BASIC',
        'Variant BASIC prefix literal differs')
    end
  end

  def verify_logical_file_binding!(entry, suffix, inventories, stream_rosters, label)
    logical = entry.fetch('logical_stream')
    file = entry.fetch('file')
    part_key = @active_inventory_key
    roster = stream_rosters.fetch(part_key)
    inventory = inventories.fetch(part_key)
    require!(logical.is_a?(String) && !logical.empty? && roster.include?(logical), "#{label} logical stream is absent")
    expected_file = "#{W241::Auditor.stream_hash(logical)}#{suffix}"
    require!(file == expected_file && inventory.any? { |record| record.fetch('path') == file },
      "#{label} file does not bind to the logical stream")
  end

  def parse_mark_file(bytes, label)
    require!(bytes.bytesize == 4 * MARK_SIZE, "#{label} does not contain exactly four Wide marks")
    4.times.map do |index|
      offset = index * MARK_SIZE
      [0, 8, 16].map { |delta| bytes.byteslice(offset + delta, 8).unpack1('Q<') }
    end
  end

  def stream_roster(part_path)
    bytes = read_plain(File.join(part_path, 'columns_substreams.txt'), MAX_PART_FILE_BYTES, 'columns_substreams.txt')
    text = bytes.dup.force_encoding(Encoding::UTF_8)
    require!(text.valid_encoding?, 'columns_substreams.txt is not valid UTF-8')
    streams = text.lines.map do |line|
      line.chomp.delete_prefix("\t") if line.start_with?("\t")
    end.compact
    require!(!streams.empty? && streams.all? { |stream| !stream.empty? } && streams.uniq == streams,
      'logical stream roster is empty or duplicated')
    streams
  end

  def part_snapshot(path, label, attached: false)
    part = canonical_directory(path, label)
    names = Dir.children(part).sort
    require!(!names.empty? && names.size <= MAX_PART_FILES, "#{label} inventory is empty or oversized")
    total = 0
    files = names.map do |name|
      entry_path = File.join(part, name)
      stat = File.lstat(entry_path)
      require!(!stat.symlink? && stat.file? && stat.nlink == 1,
        "#{label} must be flat and link-free: #{name}")
      require!(stat.size <= MAX_PART_FILE_BYTES, "#{label} has an oversized file: #{name}")
      total += stat.size
      require!(total <= MAX_PART_TOTAL_BYTES, "#{label} exceeds the total-size bound")
      raw = read_plain(entry_path, MAX_PART_FILE_BYTES, "#{label}/#{name}")
      {'path' => name, 'size' => raw.bytesize, 'sha256' => sha256(raw)}
    end
    streams = stream_roster(part)
    expected_names = W248::BASE_PART_FILES + streams.flat_map do |logical|
      stem = W241::Auditor.stream_hash(logical)
      ["#{stem}.bin", "#{stem}.mrk2"]
    end
    expected_names << W248::ATTACH_METADATA_FILE if attached
    require!(expected_names.uniq.size == expected_names.size, "#{label} logical stream file hashes collide")
    require!(names == expected_names.uniq.sort,
      attached ? "#{label} file roster differs beyond exact invalidation metadata" : "#{label} has a missing or unexpected physical file")
    {path: part, files: files, streams: streams}
  end

  def audit_closures!(summary, root, opts)
    probe_path = canonical_file(File.expand_path('probe_static_nested_handoff_w248.rb', __dir__), 'W248 probe source')
    helper_source = canonical_file(W248::HELPER_SOURCE, 'W248 helper source')
    fixture_source = canonical_file(W248::FIXTURE_SOURCE, 'W248 fixture source')
    auditor_source = canonical_file(__FILE__, 'W248 auditor source')
    expected = {
      'probe' => opts.fetch(:expected_probe_sha256),
      'helper_source' => opts.fetch(:expected_helper_source_sha256),
      'fixture' => opts.fetch(:expected_fixture_sha256),
      'auditor' => opts.fetch(:expected_auditor_sha256),
    }
    paths = {'probe' => probe_path, 'helper_source' => helper_source,
             'fixture' => fixture_source, 'auditor' => auditor_source}
    paths.each do |label, path|
      require!(file_sha256(path, label) == expected.fetch(label), "#{label} source SHA-256 differs from the pin")
    end

    repo = File.realpath(File.expand_path('..', __dir__))
    ruby_paths = W248.ruby_closure(probe_path)
    crystal_paths = W248.crystal_closure([helper_source, fixture_source], repo)
    require!(ruby_paths.size <= 4096 && crystal_paths.size <= 8192, 'source closure exceeds bounded inventory')
    ruby_entries = source_entries(ruby_paths, repo, 'Ruby source closure')
    crystal_entries = source_entries(crystal_paths, repo, 'Crystal source closure')
    closures = summary.fetch('source_closures')
    require!(closures.is_a?(Hash) && closures.keys.sort == %w[crystal ruby] &&
             closures['ruby'] == ruby_entries && closures['crystal'] == crystal_entries,
      'current Ruby/Crystal source closure paths or hashes differ from capture')
    require!(ruby_paths.include?(probe_path) && crystal_paths.include?(helper_source) &&
             crystal_paths.include?(fixture_source), 'source closure omits a pinned W248 entry point')

    pins = W248.source_pin_inventory
    require!(summary.fetch('runtime').fetch('source_pins') == pins,
      'captured ClickHouse source file pins differ from current pinned trees')
    true
  rescue KeyError, SystemCallError => error
    raise AuditError, "W248 audit: malformed source closure evidence: #{error.message}"
  end

  def source_entries(paths, boundary, label)
    base = File.realpath(boundary)
    paths.map do |path|
      canonical = canonical_file(path, label)
      require!(canonical.start_with?(base + File::SEPARATOR), "#{label} escaped its source root")
      {'path' => canonical, 'sha256' => file_sha256(canonical, label)}
    end
  end

  def validate_summary!(summary, root, opts)
    require!(summary.is_a?(Hash) && summary.keys.sort == SUMMARY_KEYS, 'summary fields are missing or unexpected')
    require!(summary['format'] == FORMAT && summary['status'] == 'paired_static_nested_handoff_observed' &&
             summary['fatal_error'].nil?, 'capture is not a complete successful W248 observation')
    require!(summary['evidence_root'] == root && summary['frame_bytes'] == W248::FRAME &&
             summary['keys'] == W248::KEYS && summary['mark_row_counts'] == W248::MARK_ROWS,
      'capture root/frame/key/mark witness differs')
    require!(%w[single sized].include?(summary['string_profile']) &&
             %w[debug release].include?(summary['helper_mode']), 'capture profile or helper mode is invalid')
    require!(summary['schema'] == ([W248::KEY] + W248::TYPES.map { |name, type| {'name' => name, 'type' => type} }),
      'independent six-column declared schema/order differs')
    require!(summary['literal_rows'] == W248::ROWS, 'captured literal rows differ from the source-pinned fixture')
    validate_variant_values!(summary['expected_signatures'], expected_signatures, 'independent signatures')

    runtime = summary.fetch('runtime')
    runtime_path = canonical_file(runtime.fetch('path'), 'pinned ClickHouse runtime')
    require!(runtime_path == RUNTIME_PATH && File.executable?(runtime_path) &&
             runtime['sha256'] == W241::BINARY_SHA256 && file_sha256(runtime_path, 'pinned ClickHouse runtime') == W241::BINARY_SHA256 &&
             runtime['version'] == W241::VERSION && runtime['build'] == W241::BUILD,
      'runtime path/hash/version/build differs from the immutable W241 runtime identity pin')

    helper = summary.fetch('helper')
    helper_path = canonical_file(helper.fetch('path'), 'W248 helper executable')
    require!(File.executable?(helper_path) && helper['sha256'] == opts.fetch(:expected_helper_sha256) &&
             file_sha256(helper_path, 'W248 helper executable') == opts.fetch(:expected_helper_sha256),
      'helper executable hash differs from the external pin')
    require!(helper['mode'] == summary['helper_mode'], 'helper mode binding differs')

    limits = summary.fetch('limits')
    expected_limits = {
      'native_max_threads' => 1,
      'native_max_memory_usage_bytes' => W241::MEMORY,
      'outer_run_safe_memory_limit_bytes' => W241::OUTER_RUN_SAFE_LIMIT,
      'timeout_seconds' => W241::TIMEOUT,
      'termination_grace_seconds' => W241::GRACE,
    }
    require!(limits == expected_limits, 'capture process limits differ from W241 bounded invocation settings')
    validate_schema!(summary.fetch('native').fetch('input_schema'), expected_schema, 'attached native')
    validate_schema!(summary.fetch('native').fetch('stock_schema'), expected_schema, 'stock-written native')
    native = summary.fetch('native')
    require!(native['attached_check'] == ["#{W248::PART_NAME}\t1\t"] &&
             native['stock_check'] == ["#{W248::PART_NAME}\t1\t"], 'summary CHECK results differ')
    expected_rows = probe_adapter(summary['string_profile'], root, 'unused', 'unused').send(:expected_native_rows)
    validate_variant_values!(native.fetch('attached_rows'), expected_rows, 'summary attached rows')
    validate_variant_values!(native.fetch('stock_rows'), expected_rows, 'summary stock rows')
    true
  rescue KeyError => error
    raise AuditError, "W248 audit: malformed summary: #{error.message}"
  end

  def expected_sql_map(profile, root, input_table, write_table)
    expected_native_sql(profile, root, input_table, write_table)
  end

  def expected_invocation_map(summary, root, input_table, write_table, helper_path)
    crystal_part = File.join(root, 'generated', W248::PART_NAME)
    stock_part = summary.fetch('parts').fetch('stock_written').fetch('path')
    native_sql = expected_sql_map(summary.fetch('string_profile'), root, input_table, write_table)
    native_store = File.join(root, 'stores', 'native')
    binary = RUNTIME_PATH
    {
      'helper_write' => {
        'kind' => 'crystal-helper', 'argv' => [helper_path, 'write', crystal_part, summary.fetch('string_profile')],
        'stdin' => ''.b, 'binary' => helper_path, 'sha' => summary.fetch('helper').fetch('sha256'),
        'store' => nil,
      },
      'native_create_input' => native_expectation(binary, native_store, native_sql.fetch('native_create_input')),
      'native_attach_check_rows' => native_expectation(binary, native_store, native_sql.fetch('native_attach_check_rows')),
      'native_create_stock_write' => native_expectation(binary, native_store, native_sql.fetch('native_create_stock_write')),
      'native_stock_write_check_rows' => native_expectation(binary, native_store, native_sql.fetch('native_stock_write_check_rows')),
      'helper_inspect_stock_part' => {
        'kind' => 'crystal-helper', 'argv' => [helper_path, 'inspect', stock_part, summary.fetch('string_profile')],
        'stdin' => ''.b, 'binary' => helper_path, 'sha' => summary.fetch('helper').fetch('sha256'),
        'store' => nil,
      },
    }
  end

  def native_expectation(binary, store, sql)
    {'kind' => 'clickhouse-local',
     'argv' => [binary, 'local', '--path', store, '--session_timezone=UTC', '--max_threads=1',
                "--max_memory_usage=#{W241::MEMORY}", '--multiquery'],
     'stdin' => sql, 'binary' => binary, 'sha' => W241::BINARY_SHA256, 'store' => store}
  end

  def audit_invocations!(root, summary, opts, tables, paths)
    records = summary.fetch('invocations')
    validate_invocation_roster!(records, expected_invocation_labels)
    expected = expected_invocation_map(summary, root, tables.fetch(:input), tables.fetch(:write),
                                      canonical_file(summary.fetch('helper').fetch('path'), 'W248 helper executable'))
    invocation_dir = canonical_directory(File.join(root, 'invocations'), 'invocations directory', beneath: root)
    expected_artifacts = []
    by_label = {}
    records.each do |record|
      label = record.fetch('label')
      by_label[label] = audit_invocation!(root, invocation_dir, record, expected.fetch(label), summary, label)
      extension = expected.fetch(label).fetch('kind') == 'clickhouse-local' ? 'sql' : 'bin'
      expected_artifacts.concat(["#{label}.argv.json", "#{label}.stdin.#{extension}",
                                 "#{label}.stdout", "#{label}.stderr", "#{label}.json"])
    end
    require!(Dir.children(invocation_dir).sort == expected_artifacts.sort,
      'invocations directory has omitted or unexpected raw process artifacts')
    by_label
  rescue KeyError => error
    raise AuditError, "W248 audit: malformed invocation roster: #{error.message}"
  end

  def audit_invocation!(root, invocation_dir, record, expected, summary, label)
    require!(record.is_a?(Hash) && record.keys.sort == INVOCATION_KEYS, "#{label} invocation fields differ")
    validate_process_status!(record, label)
    kind = expected.fetch('kind')
    native = kind == 'clickhouse-local'
    require!(record['process_kind'] == kind && record['argv'] == expected.fetch('argv') &&
             record['binary_path'] == expected.fetch('binary') && record['expected_binary_sha256'] == expected.fetch('sha') &&
             record['store_path'] == expected.fetch('store'), "#{label} process/argv/source binding differs")
    require!(record['timeout_seconds'] == W241::TIMEOUT && record['termination_grace_seconds'] == W241::GRACE &&
             record['required_outer_run_safe_memory_limit_bytes'] == W241::OUTER_RUN_SAFE_LIMIT,
      "#{label} process bounds differ")
    require!(record['max_threads'] == (native ? 1 : nil) &&
             record['max_memory_usage_bytes'] == (native ? W241::MEMORY : nil) &&
             record['max_memory_usage_applicable'] == native,
      "#{label} native/helper resource bounds differ")
    require!(record['binary_sha_before'] == expected.fetch('sha') && record['binary_sha_after'] == expected.fetch('sha') &&
             file_sha256(expected.fetch('binary'), "#{label} executable") == expected.fetch('sha'),
      "#{label} executable source hash differs")
    stem = label
    require!(record['argv_file'] == "#{stem}.argv.json" && record['stdin_file'] == "#{stem}.stdin.#{native ? 'sql' : 'bin'}" &&
             record['stdout_file'] == "#{stem}.stdout" && record['stderr_file'] == "#{stem}.stderr",
      "#{label} raw artifact names are not bound to its process label")
    require!(expected.fetch('stdin') == read_invocation_artifact(invocation_dir, record, 'stdin', label),
      "#{label} raw stdin/SQL differs from the exact expected invocation")
    artifact_record = JSON.parse(read_plain(File.join(invocation_dir, "#{stem}.json"), MAX_RECORD_BYTES,
      "#{label} invocation record artifact"))
    require!(artifact_record == record, "#{label} raw invocation record differs from summary")
    argv_bytes = read_plain(File.join(invocation_dir, record.fetch('argv_file')), MAX_RECORD_BYTES, "#{label} argv")
    require!(sha256(argv_bytes) == record.fetch('argv_sha256') && JSON.parse(argv_bytes) == expected.fetch('argv'),
      "#{label} raw argv digest/contents differ")
    stdin = read_plain(File.join(invocation_dir, record.fetch('stdin_file')), MAX_IO_BYTES, "#{label} stdin")
    stdout = read_plain(File.join(invocation_dir, record.fetch('stdout_file')), MAX_IO_BYTES, "#{label} stdout")
    stderr = read_plain(File.join(invocation_dir, record.fetch('stderr_file')), MAX_IO_BYTES, "#{label} stderr")
    require!(sha256(stdin) == record.fetch('stdin_sha256') && stdin.bytesize == record.fetch('stdin_bytes') &&
             sha256(stdout) == record.fetch('stdout_sha256') && stdout.bytesize == record.fetch('stdout_bytes') &&
             sha256(stderr) == record.fetch('stderr_sha256') && stderr.bytesize == record.fetch('stderr_bytes'),
      "#{label} raw stdin/stdout/stderr digest or size differs")
    require!(stderr.empty?, "#{label} wrote stderr")
    if native
      require!(record['binary_sha_before'] == W241::BINARY_SHA256 && record['binary_sha_after'] == W241::BINARY_SHA256,
        "#{label} is not bound to the pinned W241 runtime")
      audit_native_pin!(stdout, label)
    else
      require!(record['expected_binary_sha256'] == opts_helper_sha(summary), "#{label} helper pin differs")
    end
    {record: record, stdin: stdin, stdout: stdout, stderr: stderr}
  rescue KeyError, JSON::ParserError => error
    raise AuditError, "W248 audit: malformed #{label} invocation evidence: #{error.message}"
  end

  def opts_helper_sha(summary)
    summary.fetch('helper').fetch('sha256')
  end

  def read_invocation_artifact(invocation_dir, record, kind, label)
    field = "#{kind}_file"
    name = record.fetch(field)
    require!(name.is_a?(String) && File.basename(name) == name && name.match?(/\A[a-zA-Z0-9_.-]+\z/),
      "#{label} #{kind} artifact basename is unsafe")
    read_plain(File.join(invocation_dir, name), MAX_IO_BYTES, "#{label} #{kind}")
  end

  def audit_native_pin!(stdout, label)
    text = stdout.dup.force_encoding(Encoding::UTF_8)
    require!(text.valid_encoding? && text.end_with?("\n"), "#{label} stdout is not UTF-8 with a final newline")
    expected = [TAG_PIN, W241::VERSION, W241::BUILD].join("\t")
    pins = text.lines.map(&:chomp).select { |line| line.start_with?(TAG_PIN + "\t") }
    require!(pins == [expected], "#{label} stdout is not bound to the pinned W241 runtime")
  end

  def tagged_rows(lines, tag, width, label)
    rows = lines.select { |line| line.start_with?(tag + "\t") }.map do |line|
      fields = line.split("\t", -1)
      require!(fields.size == width, "#{label} has a malformed #{tag} TSV row")
      fields
    end
    rows
  end

  def check_result!(lines, label)
    begin_tagged = lines.each_index.select { |index| lines[index] == TAG_CHECK_BEGIN }
    end_tagged = lines.each_index.select { |index| lines[index] == TAG_CHECK_END }
    require!(begin_tagged.size == 1 && end_tagged.size == 1 && begin_tagged.first < end_tagged.first,
      "#{label} CHECK delimiters differ")
    checks = lines[(begin_tagged.first + 1)...end_tagged.first]
    require!(checks == ["#{W248::PART_NAME}\t1\t"], "#{label} CHECK result differs")
    checks
  end

  def audit_create_output!(stdout, table, store_root, label)
    text = stdout.dup.force_encoding(Encoding::UTF_8)
    require!(text.valid_encoding? && text.end_with?("\n"), "#{label} stdout is not UTF-8 with a final newline")
    lines = text.lines.map(&:chomp)
    paths = tagged_rows(lines, TAG_PATH, 4, label)
    require!(paths.size == 1 && paths.first.values_at(1, 2) == ['default', table],
      "#{label} table-path binding differs")
    data_path = canonical_directory(paths.first[3], "#{label} data path", beneath: store_root)
    require!(data_path.start_with?(File.realpath(store_root) + File::SEPARATOR), "#{label} data path escaped native store")
    data_path
  end

  def audit_read_output!(stdout, table, store_root, label, probe)
    text = stdout.dup.force_encoding(Encoding::UTF_8)
    require!(text.valid_encoding? && text.end_with?("\n"), "#{label} stdout is not UTF-8 with a final newline")
    lines = text.lines.map(&:chomp)
    checks = check_result!(lines, label)
    schema_rows = tagged_rows(lines, TAG_SCHEMA, 3, label)
    schema = schema_rows.map { |row| row.drop(1) }
    validate_schema!(schema, expected_schema, "#{label} raw")
    part_rows = tagged_rows(lines, TAG_PART, 7, label)
    require!(part_rows.size == 1, "#{label} does not identify exactly one active part")
    part = part_rows.first
    require!(part.values_at(1, 2, 4, 5, 6) == [table, W248::PART_NAME, 'Wide', '5', '4'],
      "#{label} active part identity/count differs")
    part_path = File.expand_path(part.fetch(3))
    require!(part_path.start_with?(File.realpath(store_root) + File::SEPARATOR),
      "#{label} part path escaped native store")
    part_path = canonical_directory(part_path, "#{label} active PART", beneath: store_root)
    # The probe's TSV row has the tag plus nine payload fields.
    rows_tsv = tagged_rows(lines, TAG_ROWS, 10, label)
    parsed_rows = probe.send(:parse_rows, rows_tsv, label)
    expected_rows = probe.send(:expected_native_rows)
    validate_variant_values!(parsed_rows, expected_rows, "#{label} raw")
    {checks: checks, schema: schema, part_path: part_path, rows: parsed_rows}
  rescue KeyError, ArgumentError => error
    raise AuditError, "W248 audit: malformed #{label} native output: #{error.message}"
  end

  def audit_helper_stdout!(stdout, action, part_path, profile)
    text = stdout.dup.force_encoding(Encoding::UTF_8)
    require!(text.valid_encoding? && text.end_with?("\n"), "helper #{action} stdout is not UTF-8 with a final newline")
    lines = text.lines.map(&:chomp).reject(&:empty?)
    require!(lines.size == 1, "helper #{action} must emit exactly one JSON report")
    report = JSON.parse(lines.first)
    require!(report.is_a?(Hash) && report.keys.sort == REPORT_KEYS, "helper #{action} report fields differ")
    require!(report['format'] == HELPER_FORMAT && report['action'] == action &&
             report['part'] == File.basename(part_path) && report['profile'] == profile &&
             report['frame_bytes'] == W248::FRAME && report['row_count'] == W248::KEYS.size &&
             report['keys'] == W248::KEYS && report['parent_mark_row_counts'] == W248::MARK_ROWS,
      "helper #{action} identity/key/profile/frame witness differs")
    report
  rescue JSON::ParserError => error
    raise AuditError, "W248 audit: helper #{action} report is invalid JSON: #{error.message}"
  end

  def audit_capture!(opts)
    root = canonical_root(opts.fetch(:evidence_root))
    summary_bytes = read_plain(File.join(root, 'summary.json'), MAX_SUMMARY_BYTES, 'W248 summary')
    require!(sha256(summary_bytes) == opts.fetch(:expected_summary_sha256), 'summary SHA-256 differs from the external pin')
    summary = JSON.parse(summary_bytes)
    validate_summary!(summary, root, opts)
    audit_closures!(summary, root, opts)

    token = sha256(root)[0, 8]
    tables = {input: "w248_#{token}_#{summary.fetch('string_profile')}_input",
              write: "w248_#{token}_#{summary.fetch('string_profile')}_stockwrite"}
    expected_generated = File.join(root, 'generated', W248::PART_NAME)
    parts = summary.fetch('parts')
    require!(parts.is_a?(Hash) && parts.keys.sort == %w[crystal_generated native_attached stock_written] &&
             parts.fetch('crystal_generated').fetch('path') == expected_generated,
      'PART summary paths differ from the capture layout')
    generated = part_snapshot(expected_generated, 'Crystal-generated PART')
    native_store = canonical_directory(File.join(root, 'stores', 'native'), 'native store', beneath: root)
    attached_path = canonical_directory(parts.fetch('native_attached').fetch('path'),
      'native-attached Crystal PART', beneath: native_store)
    require!(parts.fetch('native_attached').fetch('path') == attached_path,
      'native-attached summary path is noncanonical')
    native_attached = part_snapshot(attached_path, 'native-attached Crystal PART', attached: true)
    stock_path = canonical_directory(parts.fetch('stock_written').fetch('path'), 'stock-written PART', beneath: native_store)
    require!(parts.fetch('stock_written').fetch('path') == stock_path, 'stock-written summary path is noncanonical')
    stock = part_snapshot(stock_path, 'stock-written PART')
    require!(parts.fetch('crystal_generated').fetch('files') == generated.fetch(:files) &&
             parts.fetch('native_attached').fetch('files') == native_attached.fetch(:files) &&
             parts.fetch('stock_written').fetch('files') == stock.fetch(:files),
      'captured complete PART file inventory differs from reopened bytes')
    @current_part_paths = {'crystal_generated' => generated.fetch(:path),
                           'native_attached' => native_attached.fetch(:path),
                           'stock_written' => stock.fetch(:path)}
    inventories = {'crystal_generated' => generated.fetch(:files), 'stock_written' => stock.fetch(:files)}
    stream_rosters = {'crystal_generated' => generated.fetch(:streams), 'stock_written' => stock.fetch(:streams)}

    by_label = audit_invocations!(root, summary, opts, tables, @current_part_paths)
    probe = probe_adapter(summary.fetch('string_profile'), root, tables.fetch(:input), tables.fetch(:write))
    input_store_path = audit_create_output!(by_label.fetch('native_create_input').fetch(:stdout),
      tables.fetch(:input), native_store, 'native_create_input')
    attach = audit_read_output!(by_label.fetch('native_attach_check_rows').fetch(:stdout),
      tables.fetch(:input), native_store, 'native_attach_check_rows', probe)
    require!(attach.fetch(:checks) == summary.fetch('native').fetch('attached_check') &&
             attach.fetch(:schema) == summary.fetch('native').fetch('input_schema'),
      'raw attached CHECK/schema differ from summary')
    generated_attached = part_snapshot(attach.fetch(:part_path), 'attached Crystal PART', attached: true)
    require!(attach.fetch(:part_path) == File.join(input_store_path, W248::PART_NAME) &&
             attach.fetch(:part_path) == native_attached.fetch(:path) &&
             generated_attached.fetch(:files) == native_attached.fetch(:files),
      'attached Crystal PART path or inventory differs from the captured native-attached PART')
    marker_bytes = read_plain(File.join(generated_attached.fetch(:path), W248::ATTACH_METADATA_FILE),
      1024, 'ATTACH invalidation metadata')
    validate_attached_file_identity!(generated.fetch(:files), generated_attached.fetch(:files), marker_bytes)

    write_store_path = audit_create_output!(by_label.fetch('native_create_stock_write').fetch(:stdout),
      tables.fetch(:write), native_store, 'native_create_stock_write')
    stock_read = audit_read_output!(by_label.fetch('native_stock_write_check_rows').fetch(:stdout),
      tables.fetch(:write), native_store, 'native_stock_write_check_rows', probe)
    require!(stock_read.fetch(:checks) == summary.fetch('native').fetch('stock_check') &&
             stock_read.fetch(:schema) == summary.fetch('native').fetch('stock_schema') &&
             stock_read.fetch(:part_path) == stock_path && stock_path == File.join(write_store_path, W248::PART_NAME),
      'raw stock-written CHECK/schema/PART path differs from summary')
    validate_variant_values!(attach.fetch(:rows), summary.fetch('native').fetch('attached_rows'), 'raw attached rows')
    validate_variant_values!(stock_read.fetch(:rows), summary.fetch('native').fetch('stock_rows'), 'raw stock rows')

    write_report = audit_helper_stdout!(by_label.fetch('helper_write').fetch(:stdout), 'write', generated.fetch(:path),
                                       summary.fetch('string_profile'))
    inspect_report = audit_helper_stdout!(by_label.fetch('helper_inspect_stock_part').fetch(:stdout), 'inspect', stock_path,
                                         summary.fetch('string_profile'))
    require!(summary.fetch('helper_reports') == {'write' => write_report, 'stock_inspect' => inspect_report},
      'summary helper reports differ from raw helper stdout')
    [[write_report, generated], [inspect_report, stock]].each do |report, part|
      require!(report.fetch('files') == part.fetch(:files), 'helper PART inventory differs from reopened flat files')
      @active_inventory_key = part.equal?(generated) ? 'crystal_generated' : 'stock_written'
      validate_nominal_columns!(report.fetch('nominal_binary_columns'), summary.fetch('string_profile'), expected_signatures)
      consumers = report.fetch('consumer_signatures')
      require!(consumers.is_a?(Hash) && consumers.keys.sort == %w[direct_binary_bulk offline_table public_typed_table],
        'helper typed consumer roster differs')
      signatures = expected_signatures
      validate_variant_values!(consumers.fetch('direct_binary_bulk'), signatures, 'helper direct BinaryBulk')
      validate_variant_values!(consumers.fetch('offline_table'), signatures, 'helper OfflineTable')
      table = consumers.fetch('public_typed_table')
      require!(table.is_a?(Hash) && table.keys.sort == %w[columns keys] && table.fetch('keys') == W248::KEYS,
        'helper public typed table key witness differs')
      validate_variant_values!(table.fetch('columns'), signatures, 'helper public typed table')
      validate_variant_prefixes!(report.fetch('variant_discriminator_prefixes'), inventories, stream_rosters)
      validate_recursive_marks!(report.fetch('recursive_nested_site_marks'), inventories, stream_rosters)
      expected_mark_files = part.fetch(:files).map do |file|
        next nil unless file.fetch('path').end_with?('.mrk2') || file.fetch('path').end_with?('.cmrk2')
        require!(file.fetch('size') % MARK_SIZE == 0, "partial mark file #{file.fetch('path')}")
        {'path' => file.fetch('path'), 'records' => file.fetch('size') / MARK_SIZE}
      end.compact
      require!(report.fetch('physical_mark_files') == expected_mark_files && !expected_mark_files.empty? &&
               expected_mark_files.all? { |mark| mark.fetch('records') == 4 },
        'helper physical mark file roster/counts differ from actual PART files')
    end
    puts "W248 audit=authenticated profile=#{summary.fetch('string_profile')} helper_mode=#{summary.fetch('helper_mode')} summary_sha256=#{opts.fetch(:expected_summary_sha256)}"
    true
  rescue KeyError, JSON::ParserError => error
    raise AuditError, "W248 audit: malformed capture evidence: #{error.message}"
  end

  def parse_options(argv)
    options = {}
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: audit_static_nested_handoff_w248.rb --evidence-root DIR --expected-summary-sha256 SHA --expected-helper-sha256 SHA --expected-probe-sha256 SHA --expected-auditor-sha256 SHA --expected-helper-source-sha256 SHA --expected-fixture-sha256 SHA'
      opts.on('--self-test', 'Run bounded in-memory auditor self-tests only') { options[:self_test] = true }
      opts.on('--evidence-root DIR') { |value| options[:evidence_root] = value }
      opts.on('--expected-summary-sha256 SHA') { |value| options[:expected_summary_sha256] = value }
      opts.on('--expected-helper-sha256 SHA') { |value| options[:expected_helper_sha256] = value }
      opts.on('--expected-probe-sha256 SHA') { |value| options[:expected_probe_sha256] = value }
      opts.on('--expected-auditor-sha256 SHA') { |value| options[:expected_auditor_sha256] = value }
      opts.on('--expected-helper-source-sha256 SHA') { |value| options[:expected_helper_source_sha256] = value }
      opts.on('--expected-fixture-sha256 SHA') { |value| options[:expected_fixture_sha256] = value }
    end
    parser.parse!(argv)
    require!(argv.empty?, 'unexpected command-line arguments')
    if options[:self_test]
      require!(options.keys == [:self_test], '--self-test cannot be combined with capture arguments')
      return options
    end
    required = %i[
      evidence_root expected_summary_sha256 expected_helper_sha256 expected_probe_sha256 expected_auditor_sha256
      expected_helper_source_sha256 expected_fixture_sha256
    ]
    missing = required.reject { |key| options.key?(key) }
    require!(missing.empty?, "missing required option --#{missing.first.to_s.tr('_', '-')}")
    required.drop(1).each do |key|
      require!(/\A[0-9a-f]{64}\z/.match?(options.fetch(key)), "#{key} must be a lowercase SHA-256")
    end
    options
  end

  def main(argv = ARGV)
    options = parse_options(argv)
    self_test!
    if options[:self_test]
      puts 'W248 auditor selftests=10 passed'
      return true
    end
    audit_capture!(options)
  rescue StandardError => error
    warn "W248 audit failed: #{error.class}: #{error.message}"
    false
  end
end

if $PROGRAM_NAME == __FILE__
  exit(AuditStaticNestedHandoffW248.main ? 0 : 1)
end
