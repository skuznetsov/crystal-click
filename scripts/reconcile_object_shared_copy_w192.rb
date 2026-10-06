#!/usr/bin/env ruby
# Independently derive W192 exact Copy slices from authenticated W191 output,
# then compare both Crystal helper builds against raw bytes and authored rows.

require 'digest'
require 'json'
require 'optparse'
require_relative 'reconcile_object_shared_advanced_w191'
require_relative 'probe_object_shared_advanced_w191'

module ReconcileObjectSharedCopyW192
  extend self

  W191 = ReconcileObjectSharedAdvancedW191
  Probe = ProbeObjectSharedAdvancedW191
  PROFILE_ORDER = W191::PROFILE_ORDER
  MAX_MANIFEST_BYTES = 16 * 1024 * 1024
  MAX_HELPER_BYTES = 16 * 1024 * 1024
  MAX_CAPTURE_BYTES = 1_048_576
  MAX_CHUNKS = 128

  class ReconcileError < StandardError; end

  def require!(condition, message)
    raise ReconcileError, message unless condition
  end

  def hex(bytes)
    bytes.unpack1('H*')
  end

  def read_hex(value, label, maximum = MAX_CAPTURE_BYTES)
    require!(value.is_a?(String) && value.bytesize.even?, "#{label}: malformed hex string")
    require!(value.bytesize / 2 <= maximum, "#{label}: hex data exceeds bound")
    require!(value.match?(/\A[0-9a-fA-F]*\z/), "#{label}: non-hex byte")
    [value].pack('H*').b
  end

  def read_var_uint(bytes, offset, label)
    start = offset
    value = 0
    shift = 0
    loop do
      require!(offset < bytes.bytesize, "#{label}: truncated VarUInt")
      require!(offset - start < 10, "#{label}: VarUInt exceeds UInt64")
      byte = bytes.getbyte(offset)
      offset += 1
      payload = byte & 0x7f
      require!(!(shift == 63 && payload > 1), "#{label}: VarUInt overflows UInt64")
      value |= payload << shift
      break if (byte & 0x80).zero?
      shift += 7
    end
    require!(bytes.byteslice(start, offset - start) == W191.encode_var_uint(value), "#{label}: noncanonical VarUInt")
    [value, offset]
  end

  # This W192-local parser intentionally walks the physical outer String,
  # Dynamic String tag, and inner String without calling Crystal or the W191
  # convenience parser.
  def parse_copy_values(bytes, label)
    values = []
    offset = 0
    while offset < bytes.bytesize
      start = offset
      dynamic_size, offset = read_var_uint(bytes, offset, "#{label} outer String")
      require!(dynamic_size <= bytes.bytesize - offset, "#{label}: outer String exceeds remaining bytes")
      dynamic = bytes.byteslice(offset, dynamic_size).b
      offset += dynamic_size
      require!(!dynamic.empty? && dynamic.getbyte(0) == 0x15, "#{label}: Dynamic child is not String tag 0x15")
      value_size, inner_offset = read_var_uint(dynamic, 1, "#{label} inner String")
      require!(value_size == dynamic.bytesize - inner_offset, "#{label}: inner String extent or trailing bytes differ")
      value_bytes = dynamic.byteslice(inner_offset, value_size).b
      values << {
        outer_frame_hex: hex(bytes.byteslice(start, offset - start)),
        dynamic_hex: hex(dynamic),
        value_hex: hex(value_bytes),
        value_bytes: value_bytes,
        byte_start: start,
        byte_end: offset,
      }
      require!(values.size <= 1_048_576, "#{label}: unbounded String entry count")
    end
    values
  end

  def decode_sizes(bytes, label)
    require!((bytes.bytesize % 8).zero?, "#{label}: size extent is not aligned to UInt64")
    bytes.unpack('Q<*')
  end

  def width_for_dictionary(count)
    return 1 if count <= 256
    return 2 if count <= 65_536
    4
  end

  def decode_indexes(bytes, width, label)
    require!((bytes.bytesize % width).zero?, "#{label}: index lane has a partial index")
    case width
    when 1 then bytes.unpack('C*')
    when 2 then bytes.unpack('v*')
    when 4 then bytes.unpack('V*')
    else raise ReconcileError, "#{label}: unsupported implicit index width #{width}"
    end
  end

  def authored_docs(profile)
    fixture = Probe::Profiles.find { |item| item.fetch(:id) == profile.fetch('id') }
    require!(fixture, "#{profile['id']}: no authored W191 literal profile")
    docs = fixture.fetch(:kind) == :array ? fixture.fetch(:rows).flatten(1) : fixture.fetch(:rows)
    docs.map do |document|
      document.reject { |path, _value| path == 't' }.sort_by { |path, _value| path.b }
    end
  end

  def verify_fixture_binding!(profile, fixture, expected_literal_rows, expected_sql, captured_sql)
    require!(profile.fetch('kind') == fixture.fetch(:kind).to_s,
      "#{profile.fetch('id')}: summary kind differs from the fixed W191 fixture")
    require!(profile.fetch('authored_literal_rows') == expected_literal_rows,
      "#{profile.fetch('id')}: summary authored literals differ from the fixed W191 fixture")
    require!(captured_sql == expected_sql,
      "#{profile.fetch('id')}: authenticated native stdin differs from generated W191 profile SQL")
    true
  rescue KeyError => error
    raise ReconcileError, "W191 fixture binding lacks #{error.key.inspect}"
  end

  def validate_fixture_bindings!(root, profiles, invocation_by_label)
    probe = Probe::Probe.new(Probe::Binary, root)
    profiles.each do |profile|
      fixture = Probe::Profiles.find { |item| item.fetch(:id) == profile.fetch('id') }
      require!(fixture, "#{profile.fetch('id')}: fixed W191 profile fixture is absent")
      expected_literal_rows = probe.send(:expected_rows, fixture)
      expected_sql = probe.send(:profile_sql, fixture).b
      invocation = invocation_by_label.fetch("stock_#{profile.fetch('id')}")
      captured_sql = W191.read_plain_file(
        File.join(root, 'invocations', invocation.fetch('stdin_file')),
        W191::MAX_STREAM_BYTES + 65_536,
        "#{profile.fetch('id')} authenticated native SQL stdin",
      )
      verify_fixture_binding!(profile, fixture, expected_literal_rows, expected_sql, captured_sql)
    end
    true
  end

  def native_hashes(root, profile, invocation_by_label)
    record = profile.fetch('native_invocation')
    invocation = invocation_by_label.fetch(record.fetch('label'))
    require!(record == invocation, "#{profile['id']}: native invocation differs from authenticated roster")
    stdout = W191.read_plain_file(
      File.join(root, 'invocations', invocation.fetch('stdout_file')),
      MAX_CAPTURE_BYTES + 65_536,
      "#{profile['id']} native stdout",
    )
    found = {}
    stdout.force_encoding(Encoding::UTF_8).lines.each do |line|
      next unless line.start_with?("__W191_HASH__\t")
      fields = line.chomp.split("\t", -1)
      require!(fields.size == 3 && fields[2].match?(/\A[0-9]+\z/), "#{profile['id']}: malformed captured SipHash vector")
      require!(!found.key?(fields[1]), "#{profile['id']}: duplicate SipHash vector")
      found[fields[1]] = Integer(fields[2], 10)
    end
    expected_hash_names = Probe::Hashes.keys.sort
    require!(found.keys.sort == expected_hash_names, "#{profile['id']}: captured SipHash names differ from fixed native hash roster")
    found
  end

  def validate_grid!(actual, expected, label)
    require!(actual == expected, "#{label}: raw chunk row grid #{actual.inspect} differs from #{expected.inspect}")
    true
  end

  def derive_profile_chunks(root, profile, details, hashes)
    profile_id = profile.fetch('id')
    column = profile.fetch('kind') == 'array' ? 'a' : 'j'
    bucket_count = W191::PROFILE_EXPECTATIONS.fetch(profile_id).fetch(:buckets)
    prefix = "#{column}.object_shared_data."
    per_bucket = {}
    bucket_count.times do |bucket_id|
      stream = "#{prefix}#{bucket_id}.structure"
      bytes = details.fetch(:decoded_by_stream).fetch(stream) do
        raise ReconcileError, "#{profile_id}: raw structure stream #{stream} is absent"
      end
      per_bucket[bucket_id] = W191.read_structure_records(bytes, "#{profile_id} #{stream}")
    end
    grids = per_bucket.values.map { |records| records.map { |record| record.fetch(:rows) } }
    require!(grids.uniq.size == 1, "#{profile_id}: independently parsed bucket row grids differ")
    grid = grids.first
    validate_grid!(grid, W191::PROFILE_EXPECTATIONS.fetch(profile_id).fetch(:rows), profile_id)

    documents = authored_docs(profile)
    require!(grid.sum == documents.size, "#{profile_id}: raw chunk rows do not cover authored logical rows")
    copy_prefix = "#{column}.object_shared_data.copy."
    sizes_bytes = details.fetch(:decoded_by_stream).fetch("#{copy_prefix}sizes")
    indexes_bytes = details.fetch(:decoded_by_stream).fetch("#{copy_prefix}paths_indexes")
    values_bytes = details.fetch(:decoded_by_stream).fetch("#{copy_prefix}values")
    raw_counts = decode_sizes(sizes_bytes, "#{profile_id} sizes")
    require!(raw_counts.size == documents.size, "#{profile_id}: raw sizes rows differ from authored flattened rows")
    expected_counts = documents.map(&:size)
    require!(raw_counts == expected_counts, "#{profile_id}: raw per-row counts differ from authored row counts")
    value_frames = parse_copy_values(values_bytes, "#{profile_id} values")
    expected_entry_count = raw_counts.sum
    require!(value_frames.size == expected_entry_count, "#{profile_id}: value frame count differs from per-row counts")

    # Confirm all raw chunk dictionary names are globally unique and placed in
    # the bucket selected by the authenticated stock SipHash result.
    per_bucket.each do |bucket_id, records|
      records.each do |record|
        record.fetch(:paths_bytes).each do |path_bytes|
          path = path_bytes.dup.force_encoding(Encoding::UTF_8)
          require!(path.valid_encoding?, "#{profile_id}: captured path is not valid UTF-8")
          require!(hashes.key?(path), "#{profile_id}: no authenticated SipHash for #{path.inspect}")
          require!(hashes.fetch(path) % bucket_count == bucket_id, "#{profile_id}: raw dictionary path is in the wrong SipHash bucket")
        end
      end
    end

    chunks = []
    row_offset = 0
    index_offset = 0
    value_offset = 0
    grid.each_with_index do |row_count, chunk_index|
      chunk_docs = documents.slice(row_offset, row_count) || []
      chunk_counts = raw_counts.slice(row_offset, row_count) || []
      require!(chunk_docs.size == row_count && chunk_counts.size == row_count, "#{profile_id} chunk #{chunk_index}: row slice is truncated")
      bucket_paths = bucket_count.times.map do |bucket_id|
        path_bytes = per_bucket.fetch(bucket_id).fetch(chunk_index).fetch(:paths_bytes)
        path_bytes.map { |bytes| bytes.dup.force_encoding(Encoding::UTF_8) }
      end
      dictionary = bucket_paths.flatten.map(&:b)
      require!(dictionary.uniq.size == dictionary.size, "#{profile_id} chunk #{chunk_index}: duplicate combined dictionary path")
      expected_paths_by_bucket = bucket_count.times.map do |bucket_id|
        chunk_docs.flat_map { |document| document.map(&:first) }.uniq
          .select { |path| hashes.fetch(path) % bucket_count == bucket_id }.sort_by(&:b)
      end
      require!(bucket_paths.map { |paths| paths.map(&:b) } == expected_paths_by_bucket.map { |paths| paths.map(&:b) },
        "#{profile_id} chunk #{chunk_index}: raw per-bucket dictionary differs from authored rows")
      expected_union = chunk_docs.flat_map { |document| document.map(&:first) }.uniq.map(&:b)
      require!(dictionary.sort == expected_union.sort, "#{profile_id} chunk #{chunk_index}: dictionary is not the exact row-path union")

      entry_count = chunk_counts.sum
      width = width_for_dictionary(dictionary.size)
      index_length = entry_count * width
      require!(index_length <= indexes_bytes.bytesize - index_offset, "#{profile_id} chunk #{chunk_index}: indexes exceed raw lane")
      chunk_indexes_bytes = indexes_bytes.byteslice(index_offset, index_length).to_s.b
      indexes = decode_indexes(chunk_indexes_bytes, width, "#{profile_id} chunk #{chunk_index} indexes")
      require!(indexes.size == entry_count && indexes.all? { |index| index < dictionary.size },
        "#{profile_id} chunk #{chunk_index}: index is outside its exact dictionary")
      require!(entry_count <= value_frames.size - value_offset, "#{profile_id} chunk #{chunk_index}: values exceed raw lane")
      frames = value_frames.slice(value_offset, entry_count) || []
      require!(frames.size == entry_count, "#{profile_id} chunk #{chunk_index}: value frame slice is truncated")

      expected_output_rows = []
      index_cursor = 0
      value_cursor = 0
      chunk_docs.each_with_index do |document, row_index|
        count = chunk_counts.fetch(row_index)
        expected_pairs = document
        require!(count == expected_pairs.size, "#{profile_id} chunk #{chunk_index} row #{row_index}: count differs from authored fields")
        actual_paths = []
        output_pairs = []
        count.times do
          path = dictionary.fetch(indexes.fetch(index_cursor))
          value = frames.fetch(value_cursor).fetch(:value_bytes)
          actual_paths << path
          output_pairs << { 'path_hex' => hex(path), 'value_hex' => hex(value) }
          index_cursor += 1
          value_cursor += 1
        end
        require!(actual_paths == expected_pairs.map { |path, _| path.b },
          "#{profile_id} chunk #{chunk_index} row #{row_index}: reconstructed paths or row ordering differ")
        expected_pairs.each_with_index do |(path, value), index|
          require!(frames[value_cursor - count + index].fetch(:value_bytes) == value.b,
            "#{profile_id} chunk #{chunk_index} row #{row_index}: value differs from authored literal for #{path.inspect}")
        end
        expected_output_rows << output_pairs
      end
      require!(index_cursor == entry_count && value_cursor == frames.size, "#{profile_id} chunk #{chunk_index}: unassigned Copy entry")

      chunk_sizes = sizes_bytes.byteslice(row_offset * 8, row_count * 8).to_s.b
      chunk_values_start = frames.empty? ? (value_offset == 0 ? 0 : value_frames.fetch(value_offset - 1).fetch(:byte_end)) : frames.first.fetch(:byte_start)
      chunk_values_end = frames.empty? ? chunk_values_start : frames.last.fetch(:byte_end)
      chunk_values = values_bytes.byteslice(chunk_values_start, chunk_values_end - chunk_values_start).to_s.b
      bucket_record_hexes = per_bucket.keys.sort.map do |bucket_id|
        hex(per_bucket.fetch(bucket_id).fetch(chunk_index).fetch(:record_bytes))
      end
      chunks << {
        'chunk_index' => chunk_index,
        'row_count' => row_count,
        'dictionary_path_count' => dictionary.size,
        'dictionary_width' => width,
        'bucket_records_hex' => bucket_record_hexes,
        'sizes_hex' => hex(chunk_sizes),
        'indexes_hex' => hex(chunk_indexes_bytes),
        'values_hex' => hex(chunk_values),
        'expected_indexes' => indexes,
        'expected_rows' => expected_output_rows,
      }
      row_offset += row_count
      index_offset += index_length
      value_offset += entry_count
    end
    require!(row_offset == documents.size && index_offset == indexes_bytes.bytesize && value_offset == value_frames.size,
      "#{profile_id}: exact chunk slices do not consume all Copy rows and lanes")
    chunks
  end

  def derive_manifest(capture_root)
    root = File.realpath(capture_root)
    require!(File.directory?(root) && !File.symlink?(capture_root), 'capture root is not a real directory')
    summary = W191.parse_json_file(File.join(root, 'summary.json'), W191::MAX_SUMMARY_BYTES, 'W191 summary')
    require!(summary['status'] == 'all_stock_profiles_observed', 'capture is not a complete all-profile W191 observation')
    require!(summary['evidence_root'] == root, 'summary evidence root differs from supplied capture root')
    runtime = W191.validate_runtime!(summary)
    profiles = summary.fetch('profiles')
    require!(profiles.is_a?(Array) && profiles.map { |profile| profile['id'] } == PROFILE_ORDER,
      'W191 profile roster/order differs')
    profiles.each { |profile| require!(profile['status'] == 'stock_profile_observed', "#{profile['id']}: stock capture failed") }
    invocation_by_label, invocation_counts = W191.validate_invocations!(root, summary, runtime)
    validate_fixture_bindings!(root, profiles, invocation_by_label)
    linked = []
    details_by_id = {}
    profiles.each do |profile|
      native = invocation_by_label["stock_#{profile.fetch('id')}"] || raise(ReconcileError, "#{profile['id']}: native invocation absent")
      require!(profile.fetch('native_invocation') == native, "#{profile['id']}: nested native invocation differs")
      linked << native.fetch('label')
      details = W191.validate_part_and_streams!(root, profile, invocation_by_label)
      profile.fetch('stream_captures').each_value do |capture|
        linked << capture['decompressor_invocation'] if capture['decompressor_invocation']
      end
      details_by_id[profile.fetch('id')] = details
    end
    require!(linked.sort == invocation_by_label.keys.sort, 'W191 invocation roster contains orphaned/unlinked subprocesses')
    _structure_records, structure_counts = W191.validate_structure_profiles!(summary, details_by_id)

    hash_by_profile = {}
    profiles.each { |profile| hash_by_profile[profile.fetch('id')] = native_hashes(root, profile, invocation_by_label) }
    profile_manifests = profiles.map do |profile|
      id = profile.fetch('id')
      chunks = derive_profile_chunks(root, profile, details_by_id.fetch(id), hash_by_profile.fetch(id))
      {
        'profile_id' => id,
        'kind' => profile.fetch('kind'),
        'bucket_count' => W191::PROFILE_EXPECTATIONS.fetch(id).fetch(:buckets),
        'chunks' => chunks,
      }
    end
    count = profile_manifests.sum { |profile| profile.fetch('chunks').size }
    require!(count == 42, "derived #{count} chunks; expected 42")
    manifest = {
      'format' => 'object_shared_copy_w192_manifest_v1',
      'capture_root' => root,
      'profile_ids' => PROFILE_ORDER,
      'profiles' => profile_manifests,
      'source_checks' => {
        'runtime_pin' => runtime.slice('expected_version', 'expected_build', 'expected_sha256'),
        'invocation_count' => invocation_counts.fetch(:count),
        'structure_totals' => structure_counts.fetch('totals'),
        'raw_slices_derived_from_authenticated_decoded_streams' => true,
        'copy_sizes_are_per_row_counts' => true,
        'value_envelopes_independently_parsed_by_ruby' => true,
      },
    }
    encoded = JSON.generate(manifest) + "\n"
    require!(encoded.bytesize <= MAX_MANIFEST_BYTES, 'derived manifest exceeds bounded size')
    [manifest, encoded]
  rescue KeyError => error
    raise ReconcileError, "W191 capture lacks #{error.key.inspect}"
  end

  def expected_wire_counts(manifest, label)
    read_bytes = 0
    write_bytes = 0
    profiles = manifest.fetch('profiles')
    require!(profiles.is_a?(Array), "#{label}: manifest profiles are malformed")
    profiles.each do |profile|
      bucket_count = profile.fetch('bucket_count')
      require!(bucket_count.is_a?(Integer) && (1..256).cover?(bucket_count),
        "#{label}: bucket count is outside 1..256")
      chunks = profile.fetch('chunks')
      require!(chunks.is_a?(Array), "#{label}: profile chunks are malformed")
      chunks.each do |chunk|
        records = chunk.fetch('bucket_records_hex')
        require!(records.is_a?(Array) && records.size == bucket_count,
          "#{label}: raw structure record count differs from bucket count")
        metadata_bytes = records.sum do |record_hex|
          read_hex(record_hex, "#{label} raw structure record").bytesize
        end
        copy_bytes = %w[sizes_hex indexes_hex values_hex].sum do |lane|
          read_hex(chunk.fetch(lane), "#{label} Copy #{lane}").bytesize
        end
        read_bytes += metadata_bytes + copy_bytes
        write_bytes += copy_bytes
      end
    end
    {'read' => read_bytes, 'write' => write_bytes}
  rescue KeyError => error
    raise ReconcileError, "#{label}: manifest lacks #{error.key.inspect}"
  end

  def validate_wire_budget_counters!(payload, expected, label)
    {'read' => 'read_budget', 'write' => 'write_budget'}.each do |direction, field|
      actual = payload.fetch(field).fetch('wire_byte_count')
      required = expected.fetch(direction)
      require!(actual == required,
        "#{label}: #{direction} shared wire counter #{actual.inspect} differs from exact raw total #{required}")
    end
    true
  rescue KeyError => error
    raise ReconcileError, "#{label}: budget counters lack #{error.key.inspect}"
  end

  def compare_helper_payload!(payload, manifest, label)
    expected_keys = %w[profile_ids chunk_count chunks budget_scope read_budget write_budget]
    require!(payload.is_a?(Hash) && payload.keys.sort == expected_keys.sort, "#{label}: root keys differ")
    require!(payload.fetch('profile_ids') == PROFILE_ORDER, "#{label}: profile roster/order differs")
    require!(payload.fetch('budget_scope') == 'one read and one write budget shared across all 42 chunks',
      "#{label}: shared budget scope differs")
    %w[read_budget write_budget].each do |direction|
      budget = payload.fetch(direction)
      require!(budget.is_a?(Hash) && budget.keys.sort == %w[element_count node_count wire_byte_count],
        "#{label}: #{direction} counters are absent or malformed")
      budget.each_value do |count|
        require!(count.is_a?(Integer) && count >= 0, "#{label}: #{direction} counter is invalid")
      end
    end
    validate_wire_budget_counters!(payload, expected_wire_counts(manifest, label), label)
    expected_chunks = manifest.fetch('profiles').flat_map do |profile|
      profile.fetch('chunks').map do |chunk|
        counts = read_hex(chunk.fetch('sizes_hex'), "#{label} expected sizes").unpack('Q<*')
        indexes_bytes = read_hex(chunk.fetch('indexes_hex'), "#{label} expected indexes")
        width = chunk.fetch('dictionary_width')
        dictionary_path_count = chunk.fetch('dictionary_path_count')
        entry_count = counts.sum
        require!(width == width_for_dictionary(dictionary_path_count),
          "#{label}: implicit width differs from independently parsed dictionary")
        require!(indexes_bytes.bytesize == entry_count * width,
          "#{label}: index extent differs from per-row counts and dictionary width")
        indexes = decode_indexes(indexes_bytes, width, "#{label} raw indexes")
        require!(indexes == chunk.fetch('expected_indexes'), "#{label}: numeric indexes differ from raw derivation")
        {
          'profile_id' => profile.fetch('profile_id'),
          'chunk_index' => chunk.fetch('chunk_index'),
          'row_count' => chunk.fetch('row_count'),
          'dictionary_path_count' => dictionary_path_count,
          'dictionary_width' => width,
          'size_counts' => counts,
          'expected_indexes' => indexes,
          'rows' => chunk.fetch('expected_rows'),
          'sizes_hex' => chunk.fetch('sizes_hex'),
          'indexes_hex' => chunk.fetch('indexes_hex'),
          'values_hex' => chunk.fetch('values_hex'),
          'entry_count' => entry_count,
        }
      end
    end
    records = payload.fetch('chunks')
    require!(records.is_a?(Array) && records.size == expected_chunks.size, "#{label}: chunk count differs")
    require!(payload.fetch('chunk_count') == expected_chunks.size, "#{label}: declared chunk count differs")
    actual_expected_keys = %w[profile_id chunk_index row_count dictionary_path_count dictionary_width size_counts indexes rows sizes_hex indexes_hex values_hex]
    records.each_with_index do |actual, index|
      expected = expected_chunks.fetch(index)
      chunk_label = "#{label} chunk #{index}"
      require!(actual.is_a?(Hash) && actual.keys.sort == actual_expected_keys.sort, "#{chunk_label}: keys differ")
      %w[profile_id chunk_index row_count dictionary_path_count dictionary_width size_counts rows sizes_hex indexes_hex values_hex].each do |key|
        require!(actual.fetch(key) == expected.fetch(key), "#{chunk_label}: #{key} differs from raw/authored derivation")
      end
      indexes = decode_indexes(read_hex(actual.fetch('indexes_hex'), "#{chunk_label} indexes"), actual.fetch('dictionary_width'), chunk_label)
      require!(actual.fetch('indexes') == indexes && indexes == expected.fetch('expected_indexes'),
        "#{chunk_label}: numeric indexes differ from exact raw index bytes")
      entry_count = expected.fetch('entry_count')
      require!(actual.fetch('dictionary_width').is_a?(Integer) && [1, 2, 4].include?(actual.fetch('dictionary_width')),
        "#{chunk_label}: unsupported dictionary width")
      require!(entry_count * actual.fetch('dictionary_width') == read_hex(expected.fetch('indexes_hex'), "#{chunk_label} raw indexes").bytesize,
        "#{chunk_label}: implicit width differs from exact byte extent")
      require!(actual.fetch('indexes').size == entry_count, "#{chunk_label}: entry/index count differs")
      require!(actual.fetch('indexes').all? { |value| value < expected.fetch('dictionary_path_count') },
        "#{chunk_label}: reported index is outside exact dictionary cardinality")
    end
    true
  end

  def reconcile(capture_root, manifest_path, debug_path, release_path)
    manifest, canonical = derive_manifest(capture_root)
    supplied = W191.read_plain_file(manifest_path, MAX_MANIFEST_BYTES, 'W192 Copy manifest')
    require!(supplied == canonical, 'supplied W192 manifest differs from fresh raw derivation')
    debug = W191.parse_json_file(debug_path, MAX_HELPER_BYTES, 'W192 DEBUG helper output')
    release = W191.parse_json_file(release_path, MAX_HELPER_BYTES, 'W192 RELEASE helper output')
    compare_helper_payload!(debug, manifest, 'DEBUG helper')
    compare_helper_payload!(release, manifest, 'RELEASE helper')
    require!(debug == release, 'DEBUG and RELEASE W192 helper outputs differ')
    {
      'status' => 'reconciled_observation_only',
      'capture_root' => File.realpath(capture_root),
      'manifest_bytes' => canonical.bytesize,
      'profile_count' => PROFILE_ORDER.size,
      'chunk_count' => debug.fetch('chunk_count'),
      'debug_release_equal' => true,
      'raw_and_authored_checks' => true,
      'claim_boundary' => 'All 42 stock-derived exact Copy chunks matched independently authenticated raw lanes and authored JSON shared rows; this does not admit persisted ADVANCED v2/v3 read/write support or qualify complete part IO.',
    }
  end

  def self_test!
    valid = [3, 0x15, 1, 0x76].pack('C*').b
    parsed = parse_copy_values(valid, 'self-test valid')
    require!(parsed.size == 1 && parsed[0].fetch(:value_bytes) == 'v'.b, 'self-test valid outer String failed')
    %w[031501 0480010001 030101].each_with_index do |hex_value, index|
      rejected = false
      begin
        parse_copy_values([hex_value].pack('H*').b, "self-test malformed envelope #{index}")
      rescue ReconcileError
        rejected = true
      end
      require!(rejected, "self-test accepted malformed outer/tag/inner envelope #{index}")
    end

    bad_index_rejected = false
    begin
      indexes = decode_indexes([2].pack('C*').b, 1, 'self-test bad index')
      require!(indexes.all? { |index| index < 2 }, 'self-test bad index escaped range check')
    rescue ReconcileError
      bad_index_rejected = true
    end
    require!(bad_index_rejected, 'self-test failed to reject an out-of-dictionary index')

    raw_sizes = [1, 2].pack('Q<*').b
    require!(decode_sizes(raw_sizes, 'self-test row counts') == [1, 2], 'self-test confused row counts with cumulative offsets')
    bad_counts_rejected = decode_sizes([1, 3].pack('Q<*').b, 'self-test mutated counts') != [1, 2]
    require!(bad_counts_rejected, 'self-test failed to distinguish a cumulative-count mutation')

    grid_rejected = false
    begin
      validate_grid!([1, 1], [1, 2], 'self-test grid')
    rescue ReconcileError
      grid_rejected = true
    end
    require!(grid_rejected, 'self-test failed to reject a changed chunk grid')

    artifact = 'captured-stream'.b
    artifact_digest = Digest::SHA256.hexdigest(artifact)
    raw_mutation_rejected = Digest::SHA256.hexdigest('captured-streAm'.b) != artifact_digest
    require!(raw_mutation_rejected, 'self-test failed to detect a raw artifact mutation')

    wire_manifest = {
      'profiles' => [{
        'bucket_count' => 1,
        'chunks' => [{
          'bucket_records_hex' => ['aabb'],
          'sizes_hex' => '0100000000000000',
          'indexes_hex' => '00',
          'values_hex' => 'abcd',
        }],
      }],
    }
    wire_expected = expected_wire_counts(wire_manifest, 'self-test wire')
    require!(wire_expected == {'read' => 13, 'write' => 11},
      'self-test exact raw wire totals differ')
    wire_payload = {
      'read_budget' => {'wire_byte_count' => 13},
      'write_budget' => {'wire_byte_count' => 11},
    }
    require!(validate_wire_budget_counters!(wire_payload, wire_expected, 'self-test wire'),
      'self-test valid shared wire counters failed')
    zero_counter_rejected = false
    begin
      zeroed = Marshal.load(Marshal.dump(wire_payload))
      zeroed.fetch('read_budget')['wire_byte_count'] = 0
      validate_wire_budget_counters!(zeroed, wire_expected, 'self-test zeroed wire')
    rescue ReconcileError
      zero_counter_rejected = true
    end
    require!(zero_counter_rejected, 'self-test accepted a reset shared wire counter')
    changed_counter_rejected = false
    begin
      changed = Marshal.load(Marshal.dump(wire_payload))
      changed.fetch('write_budget')['wire_byte_count'] += 1
      validate_wire_budget_counters!(changed, wire_expected, 'self-test changed wire')
    rescue ReconcileError
      changed_counter_rejected = true
    end
    require!(changed_counter_rejected, 'self-test accepted a mutated shared wire counter')

    fixture = Probe::Profiles.fetch(0)
    probe = Probe::Probe.new(Probe::Binary, '/private/tmp')
    literal_rows = probe.send(:expected_rows, fixture)
    sql = probe.send(:profile_sql, fixture).b
    profile = {
      'id' => fixture.fetch(:id),
      'kind' => fixture.fetch(:kind).to_s,
      'authored_literal_rows' => literal_rows,
    }
    require!(verify_fixture_binding!(profile, fixture, literal_rows, sql, sql),
      'self-test valid fixed fixture binding failed')
    changed_literals = Marshal.load(Marshal.dump(profile))
    changed_literals.fetch('authored_literal_rows').fetch(0).fetch(2)['alpha'] = 'mutated'
    literal_mutation_rejected = false
    begin
      verify_fixture_binding!(changed_literals, fixture, literal_rows, sql, sql)
    rescue ReconcileError
      literal_mutation_rejected = true
    end
    require!(literal_mutation_rejected, 'self-test failed to reject changed authored literal rows')
    sql_mutation_rejected = false
    begin
      verify_fixture_binding!(profile, fixture, literal_rows, sql, sql + "-- changed\n")
    rescue ReconcileError
      sql_mutation_rejected = true
    end
    require!(sql_mutation_rejected, 'self-test failed to reject changed native SQL input')
    {
      'clean_outer_frame' => 'accepted',
      'bad_outer_frame_tag_and_inner_extent' => 'rejected',
      'out_of_dictionary_index' => 'rejected',
      'cumulative_count_mutation' => 'distinguished from per-row counts',
      'changed_grid' => 'rejected',
      'raw_artifact_mutation' => 'SHA-256 differs',
      'exact_shared_wire_counters' => wire_expected,
      'reset_or_mutated_wire_counters' => 'rejected',
      'changed_authored_literals' => 'rejected against fixed W191 profile constants',
      'changed_native_sql' => 'rejected against generated W191 fixture SQL',
    }
  end

  def main(argv)
    options = {self_test: false}
    OptionParser.new do |parser|
      parser.banner = 'Usage: ruby scripts/reconcile_object_shared_copy_w192.rb --capture-root ROOT (--emit-manifest PATH | --manifest PATH --debug-output PATH --release-output PATH) [--self-test]'
      parser.on('--capture-root ROOT', 'authenticated immutable W191 capture root') { |value| options[:capture_root] = value }
      parser.on('--emit-manifest PATH', 'derive and exclusively create bounded Copy manifest') { |value| options[:emit_manifest] = value }
      parser.on('--manifest PATH', 'manifest previously emitted from this capture') { |value| options[:manifest] = value }
      parser.on('--debug-output PATH', 'bounded DEBUG Crystal helper JSON output') { |value| options[:debug_output] = value }
      parser.on('--release-output PATH', 'bounded RELEASE Crystal helper JSON output') { |value| options[:release_output] = value }
      parser.on('--self-test', 'run bounded synthetic mutation controls') { options[:self_test] = true }
    end.parse!(argv)

    require!(argv.empty?, 'unexpected positional arguments')
    if options[:self_test] && options.keys == [:self_test]
      puts JSON.generate({'self_test' => self_test!})
      return 0
    end
    require!(options[:capture_root].is_a?(String), '--capture-root is required')
    if options[:emit_manifest]
      require!(!options[:manifest] && !options[:debug_output] && !options[:release_output],
        '--emit-manifest cannot be combined with helper comparison paths')
      _manifest, encoded = derive_manifest(options[:capture_root])
      File.open(options[:emit_manifest], File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(encoded)
        file.flush
      end
      puts JSON.generate({'status' => 'manifest_derived', 'path' => options[:emit_manifest], 'bytes' => encoded.bytesize, 'chunks' => 42})
      return 0
    end
    require!(options[:manifest].is_a?(String) && options[:debug_output].is_a?(String) && options[:release_output].is_a?(String),
      '--manifest, --debug-output, and --release-output are required for comparison')
    result = reconcile(options[:capture_root], options[:manifest], options[:debug_output], options[:release_output])
    result['self_test'] = self_test! if options[:self_test]
    puts JSON.pretty_generate(result)
    0
  rescue ReconcileError, W191::ReconcileError, Errno::ENOENT, Errno::EACCES, Errno::ELOOP, Errno::EEXIST, JSON::ParserError, OptionParser::ParseError => error
    warn "W192 Copy reconcile failed: #{error.message}"
    1
  end
end

exit ReconcileObjectSharedCopyW192.main(ARGV) if $PROGRAM_NAME == __FILE__
