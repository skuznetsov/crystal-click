#!/usr/bin/env ruby
# Independent raw-evidence auditor for W239 Geometry stock and paired parts.
# It checks consistency between actual process sidecars, literal files, parts,
# and summaries; it is not cryptographic execution provenance.

require 'digest'
require 'fileutils'
require 'json'
require 'optparse'
require_relative 'recheck_aggregate_recursive_w224'
require_relative 'probe_geometry_composition_w239'
require_relative 'recheck_geometry_composition_w239'
require_relative 'check_custom_geo_recursive_evidence_w238'

module CheckGeometryCompositionEvidenceW239
  extend self

  R = RecheckAggregateRecursiveW224
  P = ProbeGeometryCompositionW239
  W = RecheckGeometryCompositionW239
  A = CheckCustomGeoRecursiveEvidenceW238
  MAX_JSON_BYTES = 64 * 1024 * 1024
  RAW_ROW_BINARY_WINDOWS = %w[full middle zero].freeze

  def fail!(message)
    raise ArgumentError, "W239 evidence audit failed: #{message}"
  end

  def require_true(condition, message)
    fail!(message) unless condition
  end

  def json_file(path)
    JSON.parse(A.read_regular(path, max_bytes: MAX_JSON_BYTES).force_encoding(Encoding::UTF_8))
  rescue JSON::ParserError => error
    fail!("malformed JSON #{path}: #{error.message}")
  end

  def expected_stock_labels
    labels = A.runtime_sqls.map(&:first)
    P::PROFILES.each do |profile|
      id = profile.fetch('id')
      labels.concat(["create-insert-#{id}", "schema-#{id}", "stock-part-path-#{id}",
        "rowbinary-with-names-and-types-#{id}"])
    end
    labels.concat(P::REFUSALS.map { |row| "constructor-refusal-#{row.fetch('id')}" })
    labels << 'unknown-custom-descriptor-decode'
    labels
  end

  def expected_stock_create_sql(profile)
    id = profile.fetch('id')
    table = "w239_stock_#{id}"
    [
      'SET flatten_nested=0',
      "CREATE TABLE default.#{table} (pk UInt64, payload #{profile.fetch('declared_type')}) ENGINE=MergeTree ORDER BY pk SETTINGS #{P::STOCK_SETTINGS.join(', ')}",
      "INSERT INTO default.#{table} FORMAT RowBinary",
    ].join(";\n")
  end

  def expected_stock_schema_sql(id)
    [
      'SET flatten_nested=0',
      "SELECT name, type FROM system.columns WHERE database='default' AND table='w239_stock_#{id}' ORDER BY position FORMAT TSVRaw",
    ].join(";\n")
  end

  def expected_stock_part_sql(id)
    "SELECT name, toString(rows), toString(marks), part_type, path FROM system.parts " \
      "WHERE database='default' AND table='w239_stock_#{id}' AND active ORDER BY name FORMAT TSVRaw"
  end

  def expected_stock_rbnwt_sql(id)
    "SELECT payload FROM default.w239_stock_#{id} ORDER BY pk " \
      'SETTINGS output_format_binary_encode_types_in_binary_format=1, print_pretty_type_names=0, flatten_nested=0 FORMAT RowBinaryWithNamesAndTypes'
  end

  def validate_source_pin!(root, summary, matrix)
    pin = summary.fetch('source_pin')
    require_true(pin == matrix.fetch('source_pin'), 'stock matrix and summary source pins differ')
    source = File.expand_path(pin.fetch('checkout'))
    require_true(File.directory?(source) && !File.symlink?(source) && File.realpath(source) == source &&
      source.start_with?(P::SOURCE_PREFIX) && File.basename(source) == 'clickhouse' &&
      pin.fetch('revision') == P::SOURCE_REVISION && pin.fetch('runtime_built_from_this_source_not_asserted') == true,
      'separately pinned W239 source identity or source/runtime boundary differs')
    pin_file = json_file(File.join(root, 'pins', 'source-pin.json'))
    require_true(pin_file == pin, 'raw source-pin file differs from matrix and summary')
    revision = A.read_regular(File.join(root, 'pins', 'source-revision.stdout'))
    revision_error = A.read_regular(File.join(root, 'pins', 'source-revision.stderr'))
    require_true(revision.strip == P::SOURCE_REVISION && revision_error.empty?,
      'captured source revision command output differs')
    hashes = pin.fetch('file_hashes')
    require_true(hashes.length == P::SOURCE_SHA256.length, 'source hash roster length differs')
    hashes.each do |row|
      relative = row.fetch('path')
      expected = P::SOURCE_SHA256.fetch(relative)
      path = File.join(source, relative)
      require_true(row.fetch('expected_sha256') == expected && File.file?(path) && !File.symlink?(path),
        "pinned source file is absent or changed in roster: #{relative}")
      actual = Digest::SHA256.file(path).hexdigest
      require_true(actual == expected && row.fetch('actual_sha256') == actual && row.fetch('matches') == true,
        "separately pinned source hash differs for #{relative}")
    end
  rescue KeyError => error
    fail!("source pin is missing a required field: #{error.message}")
  end

  def audit_stock!(stock_root)
    root = A.canonical_root(stock_root, P::OUTPUT_PREFIX, 'W239 stock root')
    matrix_path = File.join(root, P::MATRIX_FILE)
    matrix_bytes = A.read_regular(matrix_path, max_bytes: MAX_JSON_BYTES)
    matrix = JSON.parse(matrix_bytes.force_encoding(Encoding::UTF_8))
    summary = json_file(File.join(root, 'summary.json'))
    require_true(matrix.fetch('format') == P::MATRIX_FORMAT &&
      summary.fetch('format') == P::SUMMARY_FORMAT &&
      summary.fetch('classification') == 'stock_geometry_composition_observed' &&
      summary.fetch('success') == true && summary['error'].nil?,
      'stock matrix/summary does not claim the complete observed result')
    require_true(summary.fetch('output_root') == root && summary.fetch('matrix_path') == matrix_path,
      'stock summary root or matrix path differs from actual files')
    validate_source_pin!(root, summary, matrix)
    require_true(matrix.fetch('stock_merge_tree_settings') == P::STOCK_SETTINGS &&
      matrix.fetch('rowbinary_output_settings') == [
        'output_format_binary_encode_types_in_binary_format=1', 'print_pretty_type_names=0', 'flatten_nested=0'],
      'stock storage or RowBinaryWithNamesAndTypes settings differ')
    require_true(matrix.fetch('geometry_scalar_contract') == {
      'descriptor_hex' => P.custom_descriptor('Geometry').unpack1('H*'),
      'null_discriminator' => 255, 'arm_order' => P::GEO_TAGS,
      'geometry_descriptor_does_not_encode_hidden_fixed_arm_roster' => true,
    }, 'literal Geometry descriptor/discriminator contract differs')
    require_true(matrix.fetch('profiles') == summary.fetch('profile_observations') &&
      matrix.fetch('refusal_observations') == summary.fetch('refusal_observations'),
      'stock summary observations differ from the actual matrix')
    profiles = matrix.fetch('profiles')
    require_true(profiles.length == P::PROFILES.length, 'stock candidate roster is incomplete')
    profiles.zip(P::PROFILES).each do |observed, profile|
      expected_values = profile.fetch('values').map { |value| P.value_body(profile, value).unpack1('H*') }
      id = profile.fetch('id')
      type = profile.fetch('declared_type')
      require_true(observed.fetch('id') == id && observed.fetch('requested_type') == type &&
        observed.fetch('classification') == 'constructor_and_scalar_observed' &&
        observed.fetch('keys') == profile.fetch('keys') && observed.fetch('row_count') == profile.fetch('values').length &&
        observed.fetch('rowbinary_values_hex') == expected_values &&
        observed.fetch('descriptor_hex') == P.type_descriptor(profile).unpack1('H*') &&
        observed.fetch('expected_rbnwt_hex') == P.expected_rbnwt(profile).unpack1('H*'),
        "stock profile identity or independent literal differs for #{id}")
      require_true(observed.fetch('nominal_schema_matches') == true &&
        observed.fetch('observed_schema_rows') == ["pk\tUInt64", "payload\t#{type}"],
        "stock observed nominal schema differs for #{id}")
      # Stock MergeTree's part census counts its terminal EOF mark. The
      # BinaryBulk readers below separately report five/three data marks.
      marks = id == 'geometry' ? 6 : 4
      census = observed.fetch('part_census')
      require_true(census.fetch('name') == 'all_1_1_0' && census.fetch('rows') == profile.fetch('values').length &&
        census.fetch('marks') == marks && census.fetch('part_type') == 'Wide',
        "stock part rows/marks/type differ for #{id}")
    end

    refusal_rows = matrix.fetch('refusal_observations')
    require_true(refusal_rows.length == P::REFUSALS.length + 1 &&
      refusal_rows.all? { |row| row.fetch('classification').start_with?('expected_normal_') },
      'source-listed constructor and unknown descriptor refusals are incomplete')

    labels = expected_stock_labels
    stems, summary_by_label = A.verify_process_roster!(root, labels, summary.fetch('processes'))
    stdin_labels = P::PROFILES.map { |profile| "create-insert-#{profile.fetch('id')}" }
    stdin_labels << 'unknown-custom-descriptor-decode'
    A.verify_raw_sidecar_roster!(root, stems, stdin_labels: stdin_labels)
    binary = A.validate_binary_from_argv!(root, R::RUNTIME_SHA256)
    runtime = json_file(File.join(root, 'pins', 'runtime-pin.json'))
    require_true(runtime == summary.fetch('runtime_pin') && runtime == matrix.fetch('runtime_pin') &&
      File.expand_path(runtime.fetch('binary')) == binary && runtime.fetch('version') == R::VERSION &&
      runtime.fetch('build_hash') == R::BUILD_HASH && runtime.fetch('sha256') == R::RUNTIME_SHA256 &&
      runtime.fetch('source_correlation') == 'not_asserted' && Digest::SHA256.file(binary).hexdigest == R::RUNTIME_SHA256,
      'actual runtime binary, raw pin sidecar, matrix, and summary differ')
    store = File.join(root, 'store')
    require_true(File.directory?(store) && !File.symlink?(store) && File.realpath(store) == store,
      'stock local store is absent or noncanonical')

    A.runtime_sqls.each do |label, sql|
      stem = stems.find { |candidate| candidate.end_with?(label) }
      _status, stdout, stderr = A.audit_call(root, stem, label: label, sql: sql,
        binary: binary, store: store, summary_record: summary_by_label.fetch(label))
      expected = label == 'runtime-version-pin' ? "#{R::VERSION}\n" : "VERSION_GITHASH=#{R::BUILD_HASH}\n"
      require_true(stdout == expected && stderr.empty?, "raw runtime pin output differs for #{label}")
    end

    P::PROFILES.each do |profile|
      id = profile.fetch('id')
      type = profile.fetch('declared_type')
      literal_input = P.expected_insert_rows(profile)
      expected_rbnwt = P.expected_rbnwt(profile)
      fixture = File.join(root, 'fixtures', "#{id}.insert-rowbinary")
      expected_fixture = File.join(root, 'fixtures', "#{id}.expected-rbnwt")
      require_true(A.read_regular(fixture) == literal_input && A.read_regular(expected_fixture) == expected_rbnwt,
        "on-disk independent insert/RBNWT fixture differs for #{id}")

      create_label = "create-insert-#{id}"
      A.audit_call(root, stems.find { |stem| stem.end_with?(create_label) }, label: create_label,
        sql: expected_stock_create_sql(profile), binary: binary, store: store, stdin: literal_input,
        summary_record: summary_by_label.fetch(create_label))

      schema_label = "schema-#{id}"
      schema_status, schema_stdout, = A.audit_call(root, stems.find { |stem| stem.end_with?(schema_label) },
        label: schema_label, sql: expected_stock_schema_sql(id), binary: binary, store: store,
        summary_record: summary_by_label.fetch(schema_label))
      require_true(schema_status.fetch('exitstatus') == 0 && schema_stdout.lines.map(&:chomp) ==
        ["pk\tUInt64", "payload\t#{type}"], "raw stock schema query differs for #{id}")

      part_label = "stock-part-path-#{id}"
      part_status, part_stdout, = A.audit_call(root, stems.find { |stem| stem.end_with?(part_label) },
        label: part_label, sql: expected_stock_part_sql(id), binary: binary, store: store,
        summary_record: summary_by_label.fetch(part_label))
      observed = matrix.fetch('profiles').find { |row| row.fetch('id') == id }
      census = observed.fetch('part_census')
      part_path = File.expand_path(observed.fetch('stock_part_path'))
      expected_part_row = [census.fetch('name'), census.fetch('rows').to_s, census.fetch('marks').to_s,
        census.fetch('part_type'), census.fetch('path')].join("\t") + "\n"
      require_true(part_status.fetch('exitstatus') == 0 && part_stdout == expected_part_row &&
        File.expand_path(census.fetch('path')) == part_path && part_path.start_with?(store + File::SEPARATOR),
        "raw stock system.parts path/axes differ for #{id}")
      require_true(!A.inventory(part_path).empty?, "actual stock Wide part inventory is empty for #{id}")

      rbnwt_label = "rowbinary-with-names-and-types-#{id}"
      rbnwt_status, rbnwt_stdout, = A.audit_call(root, stems.find { |stem| stem.end_with?(rbnwt_label) },
        label: rbnwt_label, sql: expected_stock_rbnwt_sql(id), binary: binary, store: store,
        summary_record: summary_by_label.fetch(rbnwt_label))
      capture_path = File.join(root, 'captures', "#{id}.rowbinary-with-names-and-types")
      capture = A.read_regular(capture_path)
      rbnwt = observed.fetch('rbnwt')
      require_true(rbnwt_status.fetch('exitstatus') == 0 && rbnwt_stdout == expected_rbnwt && capture == expected_rbnwt &&
        rbnwt.fetch('path') == capture_path && rbnwt.fetch('bytes') == capture.bytesize &&
        rbnwt.fetch('sha256') == Digest::SHA256.hexdigest(capture) && rbnwt.fetch('observed_hex') == capture.unpack1('H*') &&
        rbnwt.fetch('matches_independent_descriptor_and_values') == true,
        "actual stock RBNWT bytes differ from independent descriptor/value literals for #{id}")
    end

    P::REFUSALS.each do |item|
      label = "constructor-refusal-#{item.fetch('id')}"
      sql = "CREATE TABLE default.w239_refused_#{item.fetch('id')} (payload #{item.fetch('type')}) ENGINE=Memory"
      row = matrix.fetch('refusal_observations').find { |candidate| candidate['id'] == item.fetch('id') }
      status, stdout, stderr = A.audit_call(root, stems.find { |stem| stem.end_with?(label) }, label: label,
        sql: sql, binary: binary, store: store, expected: :refusal, diagnostic: item.fetch('diagnostic'),
        summary_record: summary_by_label.fetch(label))
      raw = (stdout + stderr).force_encoding(Encoding::UTF_8).scrub
      require_true(row && row.fetch('requested_type') == item.fetch('type') &&
        row.fetch('classification') == 'expected_normal_constructor_refusal' &&
        row.fetch('diagnostic') == raw && row.fetch('process') == status,
        "constructor refusal is not an exact normal diagnostic-bearing exit for #{item.fetch('id')}")
    end

    unknown_name = 'CustomGeoW239Unknown'
    unknown_descriptor = P.custom_descriptor(unknown_name)
    unknown_input = P.varuint(1) + P.rb_string('payload') + unknown_descriptor
    unknown_sql = 'INSERT INTO default.w239_stock_geometry (payload) FORMAT RowBinaryWithNamesAndTypes'
    unknown_label = 'unknown-custom-descriptor-decode'
    unknown_status, unknown_stdout, unknown_stderr = A.audit_call(root,
      stems.find { |stem| stem.end_with?(unknown_label) }, label: unknown_label, sql: unknown_sql,
      binary: binary, store: store, expected: :refusal, stdin: unknown_input,
      special: :binary_type_input, diagnostic: /Unknown data type family: CustomGeoW239Unknown/,
      summary_record: summary_by_label.fetch(unknown_label))
    unknown_row = matrix.fetch('refusal_observations').find { |row| row['id'] == 'unknown_custom_descriptor' }
    unknown_fixture = File.join(root, 'fixtures', 'unknown-custom-descriptor.rowbinary-with-names-and-types')
    require_true(unknown_row && unknown_row.fetch('requested_type') == unknown_name &&
      unknown_row.fetch('descriptor_hex') == unknown_descriptor.unpack1('H*') &&
      unknown_row.fetch('classification') == 'expected_normal_descriptor_refusal' &&
      unknown_row.fetch('diagnostic') == (unknown_stdout + unknown_stderr).force_encoding(Encoding::UTF_8).scrub &&
      unknown_row.fetch('process') == unknown_status && A.read_regular(unknown_fixture) == unknown_input,
      'unknown Custom binary descriptor refusal or literal input differs')

    expected_captures = P::PROFILES.map { |profile| "#{profile.fetch('id')}.rowbinary-with-names-and-types" }.sort
    actual_captures = Dir.glob(File.join(root, 'captures', '**', '*')).select { |path| File.file?(path) }
      .map { |path| path.delete_prefix(File.join(root, 'captures') + File::SEPARATOR) }.sort
    expected_fixtures = P::PROFILES.flat_map do |profile|
      id = profile.fetch('id')
      ["#{id}.insert-rowbinary", "#{id}.expected-rbnwt"]
    end + ['unknown-custom-descriptor.rowbinary-with-names-and-types']
    require_true(actual_captures == expected_captures && Dir.children(File.join(root, 'fixtures')).sort == expected_fixtures.sort,
      'stock capture/fixture file roster differs from the closed literal roster')
    status_counts = summary.fetch('process_status_counts')
    require_true(status_counts == {
      'success_exit0' => 30, 'normal_nonzero_or_signaled' => 5, 'timeout' => 0, 'spawn_failure' => 0,
    }, 'stock process status count summary differs from the exact 35-call roster')
    puts "W239 stock raw audit passed: #{P::PROFILES.length} literal/schema profiles, #{labels.length} captured processes"
    { root: root, matrix_path: matrix_path, matrix: matrix, profiles: P::PROFILES }
  rescue KeyError, IndexError => error
    fail!("stock evidence shape mismatch: #{error.message}")
  end

  def expected_type_shape(id)
    shape = ->(tag, name, fields, children) do
      { 'tag' => tag, 'name' => name, 'field_names' => fields, 'children' => children }
    end
    primitive = ->(tag, name) { shape.call(tag, name, [], []) }
    custom = nil
    custom = lambda do |name|
      storage = case name
                when 'Geometry'
                  arms = P::GEO_TAGS.keys.map { |arm| custom.call(arm) }
                  shape.call(0x2a, "Variant(#{P::GEO_TAGS.keys.join(', ')})", [], arms)
                when 'Point'
                  float = primitive.call(0x0e, 'Float64')
                  shape.call(0x1f, 'Tuple(Float64, Float64)', [], [float, float])
                when 'LineString', 'Ring', 'MultiPoint'
                  point = custom.call('Point')
                  shape.call(0x1e, 'Array(Point)', [], [point])
                when 'MultiLineString'
                  shape.call(0x1e, 'Array(LineString)', [], [custom.call('LineString')])
                when 'Polygon'
                  shape.call(0x1e, 'Array(Ring)', [], [custom.call('Ring')])
                when 'MultiPolygon'
                  shape.call(0x1e, 'Array(Polygon)', [], [custom.call('Polygon')])
                else
                  fail!("unlisted W239 hidden Geometry arm #{name}")
                end
      shape.call(0x2c, name, [], [storage])
    end
    geometry = custom.call('Geometry')
    string = primitive.call(0x15, 'String')
    case id
    when 'geometry' then geometry
    when 'array_geometry'
      shape.call(0x1e, 'Array(Geometry)', [], [geometry])
    when 'tuple_string_geometry'
      shape.call(0x20, 'Tuple(label String, geom Geometry)', ['label', 'geom'], [string, geometry])
    when 'map_string_geometry'
      shape.call(0x27, 'Map(String, Geometry)', [], [string, geometry])
    when 'nested_geometry_point'
      tuple = shape.call(0x20, 'Tuple(geom Geometry, point Point)', ['geom', 'point'],
        [geometry, custom.call('Point')])
      shape.call(0x2f, 'Nested(geom Geometry, point Point)', [], [tuple])
    when 'nullable_tuple_geometry'
      tuple = shape.call(0x20, 'Tuple(geom Geometry)', ['geom'], [geometry])
      shape.call(0x23, 'Nullable(Tuple(geom Geometry))', [], [tuple])
    when 'variant_string_tuple_geometry'
      tuple = shape.call(0x20, 'Tuple(geom Geometry)', ['geom'], [geometry])
      shape.call(0x2a, 'Variant(String, Tuple(geom Geometry))', [], [string, tuple])
    else
      fail!("unlisted W239 helper profile shape #{id}")
    end
  end

  def expected_reader(id, values)
    marks = id == 'geometry' ? [2, 2, 2, 2, 2] : [2, 2, 1]
    count = id == 'geometry' ? 2 : 1
    middle_start = marks.take(1).sum
    middle_rows = marks.drop(1).take(count).sum
    {
      'row_count' => values.length, 'mark_rows' => marks, 'mark_count' => marks.length,
      'full_values_hex' => values, 'middle_values_hex' => values[middle_start, middle_rows],
      'final_values_hex' => values[-marks.last, marks.last], 'eof_empty' => true,
    }
  end

  def expected_consumer(id, profile, values)
    {
      'keys' => profile.fetch('keys'), 'values_hex' => values, 'full_values_hex' => values,
      'middle_window_values_hex' => values[1, 3], 'eof_callbacks' => 0,
    }
  end

  def audit_helper!(root, summary, profiles, matrix_path, generated_root, binary)
    base = File.join(root, 'invocations', 'helper')
    meta = json_file(base + '.argv.json')
    status = json_file(base + '.status.json')
    stdout = A.read_regular(base + '.stdout', max_bytes: MAX_JSON_BYTES)
    stderr = A.read_regular(base + '.stderr')
    helper_path = File.expand_path(summary.fetch('helper_path'))
    helper_sha = summary.fetch('helper_sha256')
    require_true(File.file?(helper_path) && File.executable?(helper_path) && !File.symlink?(helper_path) &&
      File.realpath(helper_path) == helper_path && Digest::SHA256.file(helper_path).hexdigest == helper_sha &&
      summary.fetch('helper_sha256_at_start') == helper_sha,
      'helper executable path/hash is not stable and pinned')
    expected_argv = [helper_path, '--stock-matrix', matrix_path, '--output-root', generated_root]
    require_true(meta.fetch('label') == W::HELPER_LABEL && meta.fetch('argv') == expected_argv &&
      meta.fetch('environment') == { 'TZ' => 'UTC' } && meta.fetch('timeout_seconds') == W::HELPER_TIMEOUT_SECONDS &&
      !File.exist?(base + '.stdin.bin'), 'actual helper argv/environment/timeout/stdin differs')
    require_true(status.fetch('classification') == 'process_success' && status.fetch('exitstatus') == 0 &&
      status.fetch('timed_out') == false && status.fetch('signaled') == false && status['termsig'].nil? &&
      status['spawn_error'].nil? && status.fetch('stdout_bytes') == stdout.bytesize &&
      status.fetch('stderr_bytes') == stderr.bytesize &&
      summary.fetch('helper_process').reject { |key, _| key == 'argv' } == status &&
      summary.fetch('helper_process').fetch('argv') == expected_argv &&
      summary.fetch('helper_output_path') == base + '.stdout' &&
      summary.fetch('helper_stdout_sha256') == Digest::SHA256.hexdigest(stdout),
      'raw helper process status/stdout differs from summary or is not a clean exit 0')
    output = JSON.parse(stdout.force_encoding(Encoding::UTF_8))
    require_true(output.fetch('format') == W::HELPER_FORMAT && output.fetch('matrix_path') == matrix_path &&
      output.fetch('matrix_sha256') == summary.fetch('stock_matrix_sha256') &&
      output.fetch('output_root') == generated_root,
      'actual helper stdout format or matrix/output lineage differs')
    observed = output.fetch('profiles')
    require_true(observed.length == profiles.length, 'actual helper stdout profile roster is incomplete')
    generated_profiles_root = File.join(generated_root, 'generated')
    require_true(File.directory?(generated_root) && !File.symlink?(generated_root) &&
      File.realpath(generated_root) == generated_root && Dir.children(generated_root).sort == ['generated'] &&
      File.directory?(generated_profiles_root) && !File.symlink?(generated_profiles_root) &&
      Dir.children(generated_profiles_root).sort == profiles.map { |profile| profile.fetch('id') }.sort,
      'generated root/profile directory roster differs')
    observed.zip(profiles).each do |helper, profile|
      id = profile.fetch('id')
      declared = profile.fetch('declared_type')
      values = profile.fetch('values').map { |value| P.value_body(profile, value).unpack1('H*') }
      keys = profile.fetch('keys')
      marks = id == 'geometry' ? [2, 2, 2, 2, 2] : [2, 2, 1]
      require_true(helper.fetch('id') == id && helper.fetch('declared_type') == declared &&
        helper.fetch('type_shape') == expected_type_shape(id) &&
        helper.fetch('descriptor_hex') == P.type_descriptor(profile).unpack1('H*') &&
        helper.fetch('values_hex') == values && helper.fetch('row_keys') == keys &&
        helper.fetch('mark_rows') == marks &&
        File.expand_path(helper.fetch('stock_part_path')) == File.expand_path(profile.fetch('stock_part_path')),
        "actual helper nominal type/literal identity differs for #{id}")
      require_true(helper.fetch('writer') == {
        'api' => 'WidePartWriter.write_uint64_custom_geo_bulk_part', 'rows_per_mark' => 2,
        'profile' => 'with_size_stream', 'frame_bytes' => 4096, 'granule_row_counts' => marks,
      }, "helper public writer profile differs for #{id}")
      expected = expected_reader(id, values)
      %w[stock_direct_reader direct_reader].each do |field|
        reader = helper.fetch(field)
        require_true(reader.fetch('schema_declaration') == declared && reader.fetch('source_declaration') == declared &&
          reader.fetch('row_count') == expected.fetch('row_count') && reader.fetch('mark_rows') == marks &&
          reader.fetch('mark_count') == marks.length && reader.fetch('full_values_hex') == values &&
          reader.fetch('middle_values_hex') == expected.fetch('middle_values_hex') &&
          reader.fetch('final_values_hex') == expected.fetch('final_values_hex') &&
          reader.fetch('eof_empty') == true && reader.fetch('physical_stream_names').is_a?(Array) &&
          !reader.fetch('physical_stream_names').empty? && reader.fetch('selected_checksum_names').is_a?(Array) &&
          !reader.fetch('selected_checksum_names').empty?, "helper #{field} direct read differs for #{id}")
      end

      consumer = helper.fetch('typed_consumer')
      stock_consumer = helper.fetch('stock_typed_consumer')
      if id == 'geometry'
        tags = values.map { |value| [value].pack('H*').getbyte(0) }
        expected_legacy = { 'keys' => keys, 'tags' => tags, 'null_count' => tags.count(255) }
        %w[typed_consumer stock_typed_consumer].each do |field|
          candidate = helper.fetch(field)
          require_true(candidate.fetch('api') == 'WidePartTable.open_selected_typed + geometry_rows_for' &&
            candidate.fetch('keys') == expected_legacy.fetch('keys') && candidate.fetch('tags') == expected_legacy.fetch('tags') &&
            candidate.fetch('null_count') == expected_legacy.fetch('null_count'),
            "legacy bare Geometry consumer witness differs for #{field}")
        end
      else
        expected_typed = expected_consumer(id, profile, values)
        %w[typed_consumer stock_typed_consumer].each do |field|
          candidate = helper.fetch(field)
          require_true(candidate.fetch('api') == 'WidePartTable.open_selected_typed + scan_typed + scan_typed_window + binary_bulk_values_for' &&
            candidate.fetch('keys') == expected_typed.fetch('keys') &&
            candidate.fetch('values_hex') == expected_typed.fetch('values_hex') &&
            candidate.fetch('full_values_hex') == expected_typed.fetch('full_values_hex') &&
            candidate.fetch('middle_window_values_hex') == expected_typed.fetch('middle_window_values_hex') &&
            candidate.fetch('eof_callbacks') == expected_typed.fetch('eof_callbacks'),
            "recursive typed consumer witness differs for #{field}/#{id}")
        end
      end
      part = File.join(generated_root, 'generated', id, 'all_1_1_0')
      require_true(File.expand_path(helper.fetch('library_part_path')) == part &&
        Dir.children(File.join(generated_root, 'generated', id)).sort == ['all_1_1_0'] &&
        !A.inventory(part).empty?, "actual generated part path/inventory differs for #{id}")
    end
    output
  rescue JSON::ParserError, KeyError => error
    fail!("helper raw stdout/status contract is malformed: #{error.message}")
  end

  def native_create_sql(profiles)
    statements = []
    profiles.each do |profile|
      id = profile.fetch('id')
      statements << W.create_sql(profile)
      statements << "SELECT 'W239_NATIVE_DATA_PATH_BEGIN_#{id}' FORMAT TSVRaw"
      statements << "SELECT arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{W.table_name(profile)}' FORMAT TSVRaw"
      statements << "SELECT 'W239_NATIVE_DATA_PATH_END_#{id}' FORMAT TSVRaw"
    end
    statements.join(";\n")
  end

  def native_capture_sql(root, profiles)
    statements = []
    profiles.each do |profile|
      id = profile.fetch('id')
      table = W.table_name(profile)
      statements.concat([
        "SELECT 'W239_NATIVE_CHECK_BEGIN_#{id}' FORMAT TSVRaw",
        "CHECK TABLE default.#{table} FORMAT TSVRaw",
        "SELECT 'W239_NATIVE_CHECK_END_#{id}' FORMAT TSVRaw",
        "SELECT 'W239_NATIVE_SCHEMA_BEGIN_#{id}' FORMAT TSVRaw",
        "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw",
        "SELECT 'W239_NATIVE_SCHEMA_END_#{id}' FORMAT TSVRaw",
        "SELECT 'W239_NATIVE_PART_BEGIN_#{id}' FORMAT TSVRaw",
        "SELECT name, toString(rows), toString(marks), part_type, path FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw",
        "SELECT 'W239_NATIVE_PART_END_#{id}' FORMAT TSVRaw",
      ])
      predicates = { 'full' => '', 'middle' => ' WHERE pk BETWEEN 22 AND 44', 'zero' => ' WHERE pk > 111' }
      predicates.each do |window, predicate|
        path = File.join(root, 'captures', 'native-rowbinary', "#{id}-#{window}.rowbinary")
        statements << "SELECT pk, payload FROM default.#{table}#{predicate} ORDER BY pk INTO OUTFILE '#{path}' FORMAT RowBinary"
      end
    end
    statements.join(";\n")
  end

  def assert_successful_rowbinary!(bytes, raw_status, expected, label)
    require_true(raw_status.fetch('classification') == 'process_success' && raw_status.fetch('exitstatus') == 0 &&
      raw_status.fetch('signaled') == false && raw_status.fetch('timed_out') == false && raw_status['spawn_error'].nil?,
      "raw process status is not a normal exit 0 for #{label}")
    require_true(bytes == expected, "captured RowBinary differs from independent literal for #{label}")
    true
  rescue KeyError => error
    fail!("raw status is malformed for #{label}: #{error.message}")
  end

  def successful_status_wrong_bytes_rejected!(actual, raw_status, expected, label)
    return if expected.empty?
    forged = expected.dup
    forged.setbyte(0, forged.getbyte(0) ^ 1)
    begin
      assert_successful_rowbinary!(forged, raw_status, expected, "adversarial wrong bytes/#{label}")
    rescue ArgumentError
      return true
    end
    fail!("zero-exit/raw-status control accepted changed bytes for #{label}")
  end

  def audit_paired!(evidence_root, stock_result)
    root = A.canonical_root(evidence_root, W::EVIDENCE_PREFIX, 'W239 paired evidence root')
    summary = json_file(File.join(root, 'summary.json'))
    require_true(summary.fetch('format') == W::SUMMARY_FORMAT &&
      summary.fetch('classification') == 'paired_geometry_composition_observed' &&
      summary.fetch('success') == true && summary['error'].nil? &&
      summary.fetch('profile_count_expected') == P::PROFILES.length &&
      summary.fetch('profile_count_observed') == P::PROFILES.length,
      'paired summary does not claim the exact complete profile roster')
    require_true(summary.fetch('stock_root') == stock_result.fetch(:root) &&
      summary.fetch('stock_matrix_path') == stock_result.fetch(:matrix_path) &&
      summary.fetch('stock_matrix_sha256') == Digest::SHA256.file(stock_result.fetch(:matrix_path)).hexdigest,
      'paired stock-root/matrix lineage differs from the audited stock evidence')
    generated_root = A.canonical_root(summary.fetch('generated_root'), W::GENERATED_PREFIX, 'W239 generated root')
    matrix_reference = json_file(File.join(root, 'stock-matrix-reference.json'))
    require_true(matrix_reference == {
      'path' => stock_result.fetch(:matrix_path),
      'sha256' => summary.fetch('stock_matrix_sha256'),
      'format' => P::MATRIX_FORMAT,
      'stock_root' => stock_result.fetch(:root),
    }, 'paired matrix reference sidecar differs')
    profiles = P::PROFILES.map(&:dup)
    stock_profiles = stock_result.fetch(:matrix).fetch('profiles')
    profiles.each_with_index do |profile, index|
      row = stock_profiles.fetch(index)
      id = profile.fetch('id')
      require_true(row.fetch('id') == id && row.fetch('requested_type') == profile.fetch('declared_type'),
        "paired profile order or nominal stock type differs for #{id}")
      profile['stock_part_path'] = File.expand_path(row.fetch('stock_part_path'))
    end

    expected_labels = W.expected_native_labels
    stems, summary_by_label = A.verify_process_roster!(root, expected_labels, summary.fetch('processes'),
      ancillary_stems: ['helper'])
    A.verify_raw_sidecar_roster!(root, stems, ancillary_stems: ['helper'])
    binary = A.validate_binary_from_argv!(root, R::RUNTIME_SHA256)
    store = File.join(root, 'stores', 'native')
    require_true(File.directory?(store) && !File.symlink?(store) && File.realpath(store) == store,
      'paired native ClickHouse store path is absent or noncanonical')
    runtime = summary.fetch('runtime_pin')
    require_true(File.expand_path(runtime.fetch('binary')) == binary && runtime.fetch('version') == R::VERSION &&
      runtime.fetch('build_hash') == R::BUILD_HASH && runtime.fetch('sha256') == R::RUNTIME_SHA256 &&
      runtime.fetch('source_correlation') == 'not_asserted' && Digest::SHA256.file(binary).hexdigest == R::RUNTIME_SHA256,
      'paired runtime pin differs from the actual native binary or improperly asserts source correlation')
    A.runtime_sqls.each do |label, sql|
      _status, stdout, stderr = A.audit_call(root, stems.find { |stem| stem.end_with?(label) },
        label: label, sql: sql, binary: binary, store: store, summary_record: summary_by_label.fetch(label))
      expected = label == 'runtime-version-pin' ? "#{R::VERSION}\n" : "VERSION_GITHASH=#{R::BUILD_HASH}\n"
      require_true(stdout == expected && stderr.empty?, "paired raw runtime pin output differs for #{label}")
    end

    helper_output = audit_helper!(root, summary, profiles, stock_result.fetch(:matrix_path), generated_root, binary)
    helper_profiles = helper_output.fetch('profiles')
    create_label = 'native-create-all'
    create_status, create_stdout, = A.audit_call(root, stems.find { |stem| stem.end_with?(create_label) },
      label: create_label, sql: native_create_sql(profiles), binary: binary, store: store,
      summary_record: summary_by_label.fetch(create_label))
    require_true(create_status.fetch('exitstatus') == 0, 'native target-table creation did not exit 0')
    native_paths = {}
    profiles.each do |profile|
      id = profile.fetch('id')
      lines = A.marker_section(create_stdout, "W239_NATIVE_DATA_PATH_BEGIN_#{id}",
        "W239_NATIVE_DATA_PATH_END_#{id}", "native data path #{id}").lines.map(&:chomp)
      require_true(lines.length == 1 && !lines.first.empty?, "native data path raw result malformed for #{id}")
      path = File.expand_path(lines.first)
      require_true(path.start_with?(store + File::SEPARATOR) && File.directory?(path) &&
        !File.symlink?(path) && File.realpath(path) == path,
        "native system.tables.data_paths escaped isolated store for #{id}")
      native_paths[id] = path
    end

    attach_sql = profiles.map { |profile| "ALTER TABLE default.#{W.table_name(profile)} ATTACH PART 'all_1_1_0'" }.join(";\n")
    A.audit_call(root, stems.find { |stem| stem.end_with?('native-attach-all') },
      label: 'native-attach-all', sql: attach_sql, binary: binary, store: store,
      summary_record: summary_by_label.fetch('native-attach-all'))
    capture_status, capture_stdout, = A.audit_call(root, stems.find { |stem| stem.end_with?('native-capture-all') },
      label: 'native-capture-all', sql: native_capture_sql(root, profiles), binary: binary,
      store: store, summary_record: summary_by_label.fetch('native-capture-all'))

    observed_profiles = summary.fetch('profiles')
    require_true(observed_profiles.length == profiles.length, 'paired summary profile witnesses are incomplete')
    snapshots = File.join(root, 'parts', 'native')
    require_true(File.directory?(snapshots) && !File.symlink?(snapshots) &&
      Dir.children(snapshots).sort == profiles.map { |profile| profile.fetch('id') }.sort,
      'preserved detached snapshot profile roster differs')
    expected_capture_paths = profiles.flat_map do |profile|
      RAW_ROW_BINARY_WINDOWS.map { |window| File.join(root, 'captures', 'native-rowbinary', "#{profile.fetch('id')}-#{window}.rowbinary") }
    end.sort
    actual_capture_paths = Dir.glob(File.join(root, 'captures', 'native-rowbinary', '*')).sort
    require_true(actual_capture_paths == expected_capture_paths, 'paired actual RowBinary capture file roster differs')
    adversary_checks = 0

    profiles.each_with_index do |profile, index|
      id = profile.fetch('id')
      declared = profile.fetch('declared_type')
      row = observed_profiles.fetch(index)
      helper = helper_profiles.fetch(index)
      native_path = native_paths.fetch(id)
      attached = File.join(native_path, 'all_1_1_0')
      require_true(row.fetch('id') == id && row.fetch('declared_type') == declared &&
        row.fetch('descriptor_hex') == P.type_descriptor(profile).unpack1('H*') &&
        row.fetch('values_hex') == profile.fetch('values').map { |value| P.value_body(profile, value).unpack1('H*') } &&
        File.expand_path(row.fetch('native_data_path')) == native_path &&
        File.expand_path(row.fetch('attached_part_path')) == attached && row.fetch('helper_profile') == helper,
        "paired summary identity/helper/path differs for #{id}")
      generated_part = File.join(generated_root, 'generated', id, 'all_1_1_0')
      generated_inventory = A.inventory(generated_part)
      detached = File.expand_path(row.fetch('detached_part_path'))
      expected_detached = File.join(native_path, 'detached', 'all_1_1_0')
      snapshot = File.join(snapshots, id, 'all_1_1_0')
      require_true(Dir.children(File.join(snapshots, id)).sort == ['all_1_1_0'] &&
        detached == expected_detached && row.fetch('detached_inventory_before_attach') == generated_inventory &&
        File.expand_path(row.fetch('detached_snapshot_path')) == snapshot &&
        A.inventory(snapshot) == generated_inventory && !File.exist?(detached) && !File.symlink?(detached),
        "detached-copy lineage/snapshot/consumption differs for #{id}")

      check = A.marker_section(capture_stdout, "W239_NATIVE_CHECK_BEGIN_#{id}",
        "W239_NATIVE_CHECK_END_#{id}", "native CHECK #{id}")
      require_true(check == W::CHECK_OUTPUT && row.fetch('native_check_output') == W::CHECK_OUTPUT,
        "native CHECK does not report exactly one valid part for #{id}")
      schema = A.marker_section(capture_stdout, "W239_NATIVE_SCHEMA_BEGIN_#{id}",
        "W239_NATIVE_SCHEMA_END_#{id}", "native nominal schema #{id}").lines.map(&:chomp)
      require_true(schema == ["pk\tUInt64", "payload\t#{declared}"] && row.fetch('native_schema_rows') == schema,
        "actual attached native schema differs for #{id}")
      part_text = A.marker_section(capture_stdout, "W239_NATIVE_PART_BEGIN_#{id}",
        "W239_NATIVE_PART_END_#{id}", "native part census #{id}")
      part_rows = part_text.lines.map(&:chomp)
      require_true(part_rows.length == 1, "native active part census is not singular for #{id}")
      fields = part_rows.first.split("\t", -1)
      expected_rows = profile.fetch('values').length
      # system.parts includes ClickHouse's terminal EOF mark; direct library
      # reader evidence above is intentionally still five/three data marks.
      expected_marks = id == 'geometry' ? 6 : 4
      require_true(fields.length == 5 && fields[0, 4] == ['all_1_1_0', expected_rows.to_s, expected_marks.to_s, 'Wide'] &&
        File.expand_path(fields[4]) == attached && row.fetch('native_part_census') == fields &&
        File.directory?(attached) && !File.symlink?(attached) && File.realpath(attached) == attached,
        "native attached part rows/marks/type/path differ for #{id}")

      attached_inventory = A.inventory(attached)
      comparison = row.fetch('inventory_comparison')
      generated_by_path = generated_inventory.to_h { |entry| [entry.fetch('path'), entry] }
      attached_by_path = attached_inventory.to_h { |entry| [entry.fetch('path'), entry] }
      removed = (generated_by_path.keys - attached_by_path.keys).sort
      changed = generated_by_path.keys.select do |name|
        attached_by_path.key?(name) && generated_by_path.fetch(name) != attached_by_path.fetch(name)
      end.sort
      added = (attached_by_path.keys - generated_by_path.keys).sort
      require_true(removed.empty? && changed.empty? && [[], [W::INVALIDATED_FILE]].include?(added) &&
        comparison.fetch('generated_inventory') == generated_inventory &&
        comparison.fetch('attached_inventory') == attached_inventory && comparison.fetch('removed') == removed &&
        comparison.fetch('changed') == changed && comparison.fetch('added') == added &&
        A.inventory(generated_part) == generated_inventory,
        "actual generated/attached inventory delta differs for #{id}")
      if added == [W::INVALIDATED_FILE]
        invalidated = A.read_regular(File.join(attached, W::INVALIDATED_FILE))
        allowed = ["#{W::INVALIDATED_NAMES[0]}\n#{W::INVALIDATED_NAMES[1]}\n",
          "#{W::INVALIDATED_NAMES[1]}\n#{W::INVALIDATED_NAMES[0]}\n"]
        require_true(allowed.include?(invalidated) && comparison.fetch('invalidated_system_columns_hex') == invalidated.unpack1('H*'),
          "native ATTACH invalidated-system-columns file differs for #{id}")
      else
        require_true(comparison['invalidated_system_columns_hex'].nil?, "unexpected invalidation witness for #{id}")
      end

      expected_windows = {
        'full' => P.expected_insert_rows(profile),
        'middle' => profile.fetch('keys').zip(profile.fetch('values')).select { |key, _value| key >= 22 && key <= 44 }
          .map { |key, value| P.u64(key) + P.value_body(profile, value) }.join.b,
        'zero' => ''.b,
      }
      window_witnesses = row.fetch('rowbinary_windows')
      RAW_ROW_BINARY_WINDOWS.each do |window|
        path = File.join(root, 'captures', 'native-rowbinary', "#{id}-#{window}.rowbinary")
        actual = A.read_regular(path)
        expected = expected_windows.fetch(window)
        assert_successful_rowbinary!(actual, capture_status, expected, "#{id}/#{window}")
        if window == 'full'
          successful_status_wrong_bytes_rejected!(actual, capture_status, expected, id)
          adversary_checks += 1
        end
        witness = window_witnesses.fetch(window)
        require_true(witness.fetch('path') == path && witness.fetch('bytes') == actual.bytesize &&
          witness.fetch('sha256') == Digest::SHA256.hexdigest(actual) && witness.fetch('literal_hex') == expected.unpack1('H*') &&
          witness.fetch('observed_hex') == actual.unpack1('H*') && witness.fetch('matches') == true,
          "paired RowBinary summary differs from actual #{window} file for #{id}")
      end
    end
    puts "W239 paired raw audit passed: #{profiles.length} parts; #{adversary_checks} zero-exit/wrong-byte controls rejected"
    puts 'Audit boundary: actual sidecar/file consistency was checked; coordinated rewriting of every matching copy is not execution provenance.'
    true
  rescue KeyError, IndexError => error
    fail!("paired evidence shape mismatch: #{error.message}")
  end

  def main(argv)
    options = {}
    parser = OptionParser.new do |opts|
      opts.banner = <<~USAGE
        Usage:
          ruby scripts/check_geometry_composition_evidence_w239.rb --stock-root STOCK_ROOT [--evidence-root PAIRED_EVIDENCE_ROOT]
        Audits actual W239 process argv/status/sql/streams, independent literal fixtures,
        helper output, native schema/CHECK/RowBinary captures, and part inventories.
        Summary hashes are consistency witnesses, not immutable execution provenance.
      USAGE
      opts.on('--stock-root PATH') { |value| options[:stock_root] = value }
      opts.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
    end
    parser.parse!(argv)
    require_true(argv.empty? && options.key?(:stock_root), parser.to_s)
    stock = audit_stock!(options.fetch(:stock_root))
    audit_paired!(options.fetch(:evidence_root), stock) if options.key?(:evidence_root)
    true
  rescue StandardError => error
    warn "W239 independent raw evidence audit failed: #{error.class}: #{error.message}"
    false
  end
end

exit(CheckGeometryCompositionEvidenceW239.main(ARGV) ? 0 : 1) if $PROGRAM_NAME == __FILE__
