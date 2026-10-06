#!/usr/bin/env ruby
# Derive and independently decode authenticated W193 Object shared path Data
# slices. This is a bounded stock-fixture reconciliation, not persisted-format
# admission.

require 'digest'
require 'json'
require 'optparse'
require_relative 'reconcile_object_shared_advanced_w191'
require_relative 'reconcile_object_shared_copy_w192'
require_relative 'probe_object_shared_advanced_w191'

module ReconcileObjectSharedPathW193
  extend self

  W191 = ReconcileObjectSharedAdvancedW191
  W192 = ReconcileObjectSharedCopyW192
  Probe = ProbeObjectSharedAdvancedW191
  PROFILE_ORDER = W191::PROFILE_ORDER
  PROFILE_EXPECTATIONS = W191::PROFILE_EXPECTATIONS
  MAX_MANIFEST_BYTES = 16 * 1024 * 1024
  MAX_HELPER_BYTES = 16 * 1024 * 1024
  MAX_STREAM_BYTES = W191::MAX_STREAM_BYTES
  MAX_PATHS_PER_CHUNK = 65_536
  MAX_EVENTS_PER_PATH = 128
  EVENT_NAMES = %w[
    .dynamic_structure
    .variant_discr_prefix
    .variant_discr
    .SharedVariant.size
    .SharedVariant
  ].freeze
  FORMAT = 'object_shared_path_w193_manifest_v1'

  class ReconcileError < StandardError; end

  def require!(condition, message)
    raise ReconcileError, message unless condition
  end

  def hex(bytes)
    bytes.unpack1('H*')
  end

  def read_hex(value, label, maximum = MAX_STREAM_BYTES)
    require!(value.is_a?(String) && value.bytesize.even?, "#{label}: malformed hex")
    require!(value.bytesize / 2 <= maximum, "#{label}: hex exceeds bound")
    require!(value.match?(/\A[0-9a-fA-F]*\z/), "#{label}: contains a non-hex byte")
    [value].pack('H*').b
  end

  def logical_offset(details, stream_name, pair, label)
    frame = details.fetch(:frame_by_stream).fetch(stream_name) do
      raise ReconcileError, "#{label}: frame coordinates for #{stream_name} are absent"
    end
    W191.coordinate_to_decoded(pair, frame.fetch(:frames), frame.fetch(:compressed_bytes),
                               frame.fetch(:decoded_bytes), label)
  end

  def stream_bytes(details, stream_name, label)
    details.fetch(:decoded_by_stream).fetch(stream_name) do
      raise ReconcileError, "#{label}: decoded stream #{stream_name} is absent"
    end
  end

  def read_mark_pair(bytes, offset, label)
    require!(offset.is_a?(Integer) && offset >= 0 && offset <= bytes.bytesize - 16,
      "#{label}: 16-byte mark pair exceeds stream")
    pair = bytes.byteslice(offset, 16).unpack('Q<2')
    [pair, offset + 16]
  end

  def read_var_uint(bytes, offset, label)
    value, ending = W191.canonical_var_uint(bytes, offset, label)
    [value, ending]
  rescue ReconcileError
    raise
  end

  def read_binary_string(bytes, offset, label)
    length, offset = read_var_uint(bytes, offset, "#{label} length")
    require!(length <= bytes.bytesize - offset, "#{label}: string exceeds remaining stream")
    value = bytes.byteslice(offset, length).to_s.b
    [value, offset + length]
  end

  def require_contiguous_offset!(actual, expected, label)
    require!(actual.is_a?(Integer) && expected.is_a?(Integer) && actual == expected,
      "#{label}: pointer offset is not contiguous (#{actual.inspect} != #{expected.inspect})")
  end

  def copy_expected_values(copy_chunk, row_count, label)
    rows = copy_chunk.fetch('expected_rows')
    require!(rows.is_a?(Array) && rows.size == row_count, "#{label}: Copy expected row count differs")
    seen_by_row = []
    all_paths = {}
    rows.each_with_index do |row, row_index|
      require!(row.is_a?(Array), "#{label} row #{row_index}: Copy row is malformed")
      seen = {}
      row.each do |entry|
        path_hex = entry.fetch('path_hex')
        value_hex = entry.fetch('value_hex')
        path = read_hex(path_hex, "#{label} Copy path", 1_048_576)
        read_hex(value_hex, "#{label} Copy String", MAX_STREAM_BYTES)
        require!(!seen.key?(path_hex), "#{label} row #{row_index}: duplicate Copy path")
        seen[path_hex] = value_hex
        all_paths[path_hex] = path
      end
      seen_by_row << seen
    end
    values = all_paths.keys.to_h do |path_hex|
      [path_hex, seen_by_row.map { |row| row[path_hex] }]
    end
    [values, all_paths]
  rescue KeyError => error
    raise ReconcileError, "#{label}: Copy expected row lacks #{error.key.inspect}"
  end

  def decode_path_string_data!(data, events, row_count, expected_values, label)
    require!(data.bytesize <= MAX_STREAM_BYTES, "#{label}: Data slice exceeds bound")
    require!(row_count.is_a?(Integer) && row_count.positive? && row_count <= 1_048_576,
      "#{label}: path row count is outside supported capture bounds")
    require!(events.is_a?(Array) && events.size == EVENT_NAMES.size,
      "#{label}: event count differs from the captured String profile")
    require!(events.map { |event| event.fetch('name') } == EVENT_NAMES,
      "#{label}: ordered event names differ from the captured String profile")
    offsets = events.map { |event| event.fetch('relative_offset') }
    require!(offsets.all? { |offset| offset.is_a?(Integer) && offset >= 0 && offset <= data.bytesize },
      "#{label}: event offset is outside Data")
    require!(offsets.each_cons(2).all? { |left, right| left <= right },
      "#{label}: ordered events move backward")
    require!(offsets.first == 0, "#{label}: Dynamic prefix does not start at Data offset zero")
    spans = events.each_with_index.map do |event, index|
      start_at = offsets.fetch(index)
      end_at = index + 1 < offsets.size ? offsets.fetch(index + 1) : data.bytesize
      [event.fetch('name'), data.byteslice(start_at, end_at - start_at).to_s.b]
    end.to_h

    structure = spans.fetch('.dynamic_structure')
    require!(structure.bytesize == 9 && structure.byteslice(0, 8).unpack1('Q<') == 4,
      "#{label}: Dynamic V3 NONE prefix extent/version differs")
    ordinary_types, prefix_end = read_var_uint(structure, 8, "#{label} Dynamic type count")
    require!(ordinary_types.zero? && prefix_end == structure.bytesize,
      "#{label}: stock fixture is not an empty ordinary-type roster with StatisticsMode::NONE")

    variant_mode = spans.fetch('.variant_discr_prefix')
    require!(variant_mode.bytesize == 8 && variant_mode.unpack1('Q<') == 1,
      "#{label}: Variant discriminator mode is not COMPACT")

    discr_bytes = spans.fetch('.variant_discr')
    parsed_rows, discr_offset = read_var_uint(discr_bytes, 0, "#{label} discriminator row count")
    require!(parsed_rows == row_count, "#{label}: discriminator row count differs from structure")
    require!(discr_offset < discr_bytes.bytesize, "#{label}: discriminator granule format is absent")
    granule_format = discr_bytes.getbyte(discr_offset)
    discr_offset += 1
    case granule_format
    when 0
      require!(discr_bytes.bytesize - discr_offset == row_count,
        "#{label}: PLAIN discriminator extent differs from row count")
      discriminators = discr_bytes.byteslice(discr_offset, row_count).bytes
    when 1
      require!(discr_bytes.bytesize - discr_offset == 1,
        "#{label}: COMPACT discriminator must contain one arm byte")
      discriminator = discr_bytes.getbyte(discr_offset)
      require!(discriminator == 0, "#{label}: COMPACT fixture is not the SharedVariant arm")
      discriminators = Array.new(row_count, discriminator)
    else
      raise ReconcileError, "#{label}: unknown Variant granule format #{granule_format}"
    end
    require!(discriminators.all? { |tag| tag == 0 || tag == 0xff },
      "#{label}: discriminator selects an ordinary arm outside the captured profile")
    shared_rows = discriminators.count(0)
    size_bytes = spans.fetch('.SharedVariant.size')
    require!(size_bytes.bytesize == shared_rows * 8,
      "#{label}: SharedVariant size vector extent differs from non-NULL rows")
    sizes = size_bytes.unpack('Q<*')

    shared_bytes = spans.fetch('.SharedVariant')
    shared_offset = 0
    decoded_by_row = Array.new(row_count)
    shared_index = 0
    discriminators.each_with_index do |tag, row_index|
      next if tag == 0xff
      require!(shared_offset < shared_bytes.bytesize, "#{label}: SharedVariant child is truncated")
      start = shared_offset
      type_tag = shared_bytes.getbyte(shared_offset)
      shared_offset += 1
      require!(type_tag == 0x15, "#{label}: retained stock actual type is not String tag 0x15")
      value, shared_offset = read_binary_string(shared_bytes, shared_offset, "#{label} SharedVariant String")
      child_extent = shared_offset - start
      require!(sizes.fetch(shared_index) == child_extent,
        "#{label}: position-independent SharedVariant size differs from child extent")
      decoded_by_row[row_index] = hex(value)
      shared_index += 1
    end
    require!(shared_offset == shared_bytes.bytesize && shared_index == shared_rows,
      "#{label}: SharedVariant lane has trailing or unassigned bytes")
    require!(decoded_by_row == expected_values,
      "#{label}: per-row String/NULL values differ from authenticated Copy and authored literals")
    {
      'dynamic_structure_prefix_hex' => hex(structure),
      'dynamic_version' => 4,
      'ordinary_type_count' => 0,
      'statistics_mode' => 'NONE',
      'variant_mode_prefix_hex' => hex(variant_mode),
      'variant_discriminator_mode' => 'COMPACT',
      'granule_format' => granule_format.zero? ? 'PLAIN' : 'COMPACT',
      'discriminators' => discriminators,
      'shared_variant_sizes' => sizes,
      'decoded_values_hex' => decoded_by_row,
    }
  rescue KeyError => error
    raise ReconcileError, "#{label}: missing required String path event #{error.key.inspect}"
  end

  def load_capture!(capture_root)
    root = File.realpath(capture_root)
    require!(File.directory?(root) && !File.symlink?(capture_root), 'capture root is not a real directory')
    summary = W191.parse_json_file(File.join(root, 'summary.json'), W191::MAX_SUMMARY_BYTES, 'W191 summary')
    require!(summary['status'] == 'all_stock_profiles_observed' && summary['evidence_root'] == root,
      'capture is not the complete W191 stock observation at the supplied root')
    runtime = W191.validate_runtime!(summary)
    profiles = summary.fetch('profiles')
    require!(profiles.is_a?(Array) && profiles.map { |profile| profile.fetch('id') } == PROFILE_ORDER,
      'W191 profile roster/order differs')
    invocation_by_label, invocation_counts = W191.validate_invocations!(root, summary, runtime)

    # W192 re-derives authenticated Copy slices and binds their String bytes to
    # the fixed authored SQL/literals. Its resulting rows are the expected
    # SharedVariant values for this independent per-path decode.
    copy_manifest, = W192.derive_manifest(root)
    require!(copy_manifest.fetch('profile_ids') == PROFILE_ORDER,
      'W192 Copy manifest profile roster differs')
    require!(copy_manifest.fetch('source_checks').fetch('raw_slices_derived_from_authenticated_decoded_streams') == true &&
             copy_manifest.fetch('source_checks').fetch('copy_sizes_are_per_row_counts') == true &&
             copy_manifest.fetch('source_checks').fetch('value_envelopes_independently_parsed_by_ruby') == true,
      'W192 Copy source checks are incomplete')

    details_by_id = {}
    linked = []
    profiles.each do |profile|
      profile_id = profile.fetch('id')
      require!(profile['status'] == 'stock_profile_observed', "#{profile_id}: stock observation failed")
      native = invocation_by_label.fetch("stock_#{profile_id}")
      require!(profile.fetch('native_invocation') == native, "#{profile_id}: native invocation binding differs")
      linked << native.fetch('label')
      profile.fetch('stream_captures').each_value do |capture|
        linked << capture['decompressor_invocation'] if capture['decompressor_invocation']
      end
      details_by_id[profile_id] = W191.validate_part_and_streams!(root, profile, invocation_by_label)
    end
    require!(linked.sort == invocation_by_label.keys.sort, 'W191 invocation roster has orphaned/unlinked processes')
    W191.validate_structure_profiles!(summary, details_by_id)
    [root, summary, copy_manifest, details_by_id, invocation_counts]
  rescue KeyError => error
    raise ReconcileError, "W193 capture lacks #{error.key.inspect}"
  end

  def bucket_stream_names(column, bucket_id)
    base = "#{column}.object_shared_data.#{bucket_id}"
    {
      structure: "#{base}.structure",
      data: "#{base}.data",
      paths_marks: "#{base}.paths_marks",
      substreams: "#{base}.substreams",
      substreams_marks: "#{base}.substreams_marks",
      paths_substreams_metadata: "#{base}.paths_substreams_metadata",
    }
  end

  def source_inventory_hash(summary)
    entries = summary.fetch('profiles').flat_map do |profile|
      profile.fetch('part').fetch('stream_file_inventory').sort_by { |filename, _| filename }.map do |filename, item|
        [profile.fetch('id'), filename, item.fetch('size'), item.fetch('sha256')]
      end
    end.sort
    Digest::SHA256.hexdigest(JSON.generate(entries))
  end

  def derive_path_profiles(summary, copy_manifest, details_by_id)
    copy_by_id = copy_manifest.fetch('profiles').to_h { |profile| [profile.fetch('profile_id'), profile] }
    summary.fetch('profiles').map do |profile|
      profile_id = profile.fetch('id')
      expectation = PROFILE_EXPECTATIONS.fetch(profile_id)
      column = expectation.fetch(:kind) == 'array' ? 'a' : 'j'
      bucket_count = expectation.fetch(:buckets)
      copy_profile = copy_by_id.fetch(profile_id)
      require!(copy_profile.fetch('kind') == expectation.fetch(:kind).to_s &&
               copy_profile.fetch('bucket_count') == bucket_count,
        "#{profile_id}: W192 kind/bucket binding differs")
      details = details_by_id.fetch(profile_id)
      chunk_count = expectation.fetch(:rows).size
      copy_chunks = copy_profile.fetch('chunks')
      require!(copy_chunks.size == chunk_count, "#{profile_id}: W192 chunk count differs from W191 row schedule")

      structure_by_bucket = {}
      bucket_count.times do |bucket_id|
        streams = bucket_stream_names(column, bucket_id)
        structure_bytes = stream_bytes(details, streams.fetch(:structure), "#{profile_id} structure")
        structure_by_bucket[bucket_id] = W191.read_structure_records(
          structure_bytes, "#{profile_id} bucket #{bucket_id} structure",
        )
      end
      schedules = structure_by_bucket.values.map { |records| records.map { |record| record.fetch(:rows) } }
      require!(schedules.all? { |rows| rows == expectation.fetch(:rows) },
        "#{profile_id}: raw structure chunk row schedule differs")
      profile_chunks = copy_chunks.each_with_index.map do |copy_chunk, chunk_index|
        {
          'chunk_index' => chunk_index,
          'row_count' => expectation.fetch(:rows).fetch(chunk_index),
          'buckets' => [],
        }
      end

      bucket_count.times do |bucket_id|
        streams = bucket_stream_names(column, bucket_id)
        decoded = %i[data paths_marks substreams substreams_marks paths_substreams_metadata].to_h do |kind|
          [kind, stream_bytes(details, streams.fetch(kind), "#{profile_id} bucket #{bucket_id} #{kind}")]
        end
        cursors = {paths_marks: 0, substreams: 0, substreams_marks: 0,
                   paths_substreams_metadata: 0}
        pending_paths = []
        bucket_chunks = []

        chunk_count.times do |chunk_index|
          structure = structure_by_bucket.fetch(bucket_id).fetch(chunk_index)
          copy_chunk = copy_chunks.fetch(chunk_index)
          row_count = structure.fetch(:rows)
          require!(copy_chunk.fetch('chunk_index') == chunk_index && copy_chunk.fetch('row_count') == row_count,
            "#{profile_id} bucket #{bucket_id} chunk #{chunk_index}: Copy/structure rows differ")
          raw_record = structure.fetch(:record_bytes)
          require!(copy_chunk.fetch('bucket_records_hex').fetch(bucket_id) == hex(raw_record),
            "#{profile_id} bucket #{bucket_id} chunk #{chunk_index}: Copy manifest structure bytes differ")
          expected_by_path, expected_all_paths = copy_expected_values(
            copy_chunk, row_count, "#{profile_id} chunk #{chunk_index}",
          )
          chunk_paths = structure.fetch(:paths)
          path_hexes = chunk_paths.map { |path| hex(path.b) }
          require!(path_hexes == path_hexes.uniq &&
                   path_hexes == path_hexes.sort_by { |path| [path].pack('H*').b },
            "#{profile_id} bucket #{bucket_id} chunk #{chunk_index}: path list is duplicate or not byte sorted")
          require!(path_hexes.all? { |path_hex| expected_all_paths.key?(path_hex) },
            "#{profile_id} bucket #{bucket_id} chunk #{chunk_index}: structure contains a path absent from Copy rows")

          pairs = structure.fetch(:transport_pairs)
          data_start = logical_offset(details, streams.fetch(:data), pairs.fetch('data'),
                                      "#{profile_id} bucket #{bucket_id} chunk #{chunk_index} Data mark")
          paths_marks_start = logical_offset(details, streams.fetch(:paths_marks), pairs.fetch('paths_marks'),
                                             "#{profile_id} bucket #{bucket_id} chunk #{chunk_index} PathsMarks mark")
          metadata_start = logical_offset(details, streams.fetch(:paths_substreams_metadata),
                                          pairs.fetch('paths_substreams_metadata'),
                                          "#{profile_id} bucket #{bucket_id} chunk #{chunk_index} metadata mark")
          require!(data_start <= decoded.fetch(:data).bytesize,
            "#{profile_id} bucket #{bucket_id} chunk #{chunk_index}: Data mark exceeds stream")
          require_contiguous_offset!(paths_marks_start, cursors.fetch(:paths_marks),
            "#{profile_id} bucket #{bucket_id} chunk #{chunk_index} PathsMarks pointer")
          require_contiguous_offset!(metadata_start, cursors.fetch(:paths_substreams_metadata),
            "#{profile_id} bucket #{bucket_id} chunk #{chunk_index} metadata pointer")

          path_records = []
          chunk_paths.each_with_index do |path, path_index|
            path_mark, cursors[:paths_marks] = read_mark_pair(
              decoded.fetch(:paths_marks), cursors.fetch(:paths_marks),
              "#{profile_id} bucket #{bucket_id} chunk #{chunk_index} path #{path_index} mark",
            )
            path_data_start = logical_offset(details, streams.fetch(:data), path_mark,
                                             "#{profile_id} bucket #{bucket_id} chunk #{chunk_index} path #{path_index} Data mark")
            metadata_offset = cursors.fetch(:paths_substreams_metadata)
            require!(metadata_offset <= decoded.fetch(:paths_substreams_metadata).bytesize - 32,
              "#{profile_id} bucket #{bucket_id} chunk #{chunk_index}: path metadata record is truncated")
            list_mark, next_meta = read_mark_pair(decoded.fetch(:paths_substreams_metadata), metadata_offset,
                                                  "#{profile_id} names-list pointer")
            marks_mark, next_meta = read_mark_pair(decoded.fetch(:paths_substreams_metadata), next_meta,
                                                   "#{profile_id} event-marks pointer")
            cursors[:paths_substreams_metadata] = next_meta
            names_offset = logical_offset(details, streams.fetch(:substreams), list_mark,
                                          "#{profile_id} bucket #{bucket_id} path names pointer")
            marks_offset = logical_offset(details, streams.fetch(:substreams_marks), marks_mark,
                                          "#{profile_id} bucket #{bucket_id} path event-marks pointer")
            path_hex = hex(path.b)
            require!(expected_by_path.key?(path_hex),
              "#{profile_id} bucket #{bucket_id} chunk #{chunk_index}: Copy lacks path #{path.inspect}")
            record = {
              'path' => path,
              'path_hex' => path_hex,
              'chunk_index' => chunk_index,
              'row_count' => row_count,
              'type' => 'Dynamic(max_types=0)',
              'structure_types_by_site' => {'root' => []},
              'expected_values_hex' => expected_by_path.fetch(path_hex),
              'data_mark' => path_mark,
              'data_offset' => path_data_start,
              'names_mark' => list_mark,
              'names_offset' => names_offset,
              'substreams_marks_mark' => marks_mark,
              'substreams_marks_offset' => marks_offset,
            }
            path_records << record
            pending_paths << record
          end
          bucket_chunk = {
            'bucket_id' => bucket_id,
            'paths' => path_records,
            'structure_record_hex' => hex(raw_record),
            'data_mark' => pairs.fetch('data'),
            'data_offset' => data_start,
            'paths_marks_mark' => pairs.fetch('paths_marks'),
            'paths_marks_offset' => paths_marks_start,
            'metadata_mark' => pairs.fetch('paths_substreams_metadata'),
            'metadata_offset' => metadata_start,
          }
          bucket_chunks << bucket_chunk
          profile_chunks.fetch(chunk_index).fetch('buckets') << bucket_chunk
        end

        require!(cursors.fetch(:paths_marks) == decoded.fetch(:paths_marks).bytesize,
          "#{profile_id} bucket #{bucket_id}: PathsMarks bytes remain unreferenced")
        require!(cursors.fetch(:paths_substreams_metadata) == decoded.fetch(:paths_substreams_metadata).bytesize,
          "#{profile_id} bucket #{bucket_id}: path metadata bytes remain unreferenced")

        pending_paths.each_with_index do |path_record, path_index|
          names_offset = path_record.fetch('names_offset')
          marks_offset = path_record.fetch('substreams_marks_offset')
          require_contiguous_offset!(names_offset, cursors.fetch(:substreams),
            "#{profile_id} bucket #{bucket_id} path #{path_index} names pointer")
          count, names_cursor = read_var_uint(decoded.fetch(:substreams), names_offset,
                                              "#{profile_id} bucket #{bucket_id} substream count")
          require!(count <= MAX_EVENTS_PER_PATH,
            "#{profile_id} bucket #{bucket_id} path #{path_index}: event count exceeds bound")
          require_contiguous_offset!(marks_offset, cursors.fetch(:substreams_marks),
            "#{profile_id} bucket #{bucket_id} path #{path_index} event-marks pointer")
          require!(count <= (decoded.fetch(:substreams_marks).bytesize - marks_offset) / 16,
            "#{profile_id} bucket #{bucket_id} path #{path_index}: event marks exceed stream")
          events = []
          count.times do |event_index|
            name_bytes, names_cursor = read_binary_string(decoded.fetch(:substreams), names_cursor,
                                                          "#{profile_id} bucket #{bucket_id} event name #{event_index}")
            name = name_bytes.dup.force_encoding(Encoding::UTF_8)
            require!(name.valid_encoding?, "#{profile_id} bucket #{bucket_id}: substream name is invalid UTF-8")
            mark, = read_mark_pair(decoded.fetch(:substreams_marks), marks_offset + event_index * 16,
                                   "#{profile_id} bucket #{bucket_id} event mark #{event_index}")
            event_offset = logical_offset(details, streams.fetch(:data), mark,
                                          "#{profile_id} bucket #{bucket_id} event #{event_index} Data mark")
            require!(event_offset >= path_record.fetch('data_offset'),
              "#{profile_id} bucket #{bucket_id}: event precedes path Data")
            events << {
              'name' => name,
              'relative_offset' => event_offset - path_record.fetch('data_offset'),
              'data_mark' => mark,
            }
          end
          require!(events.map { |event| event.fetch('name') } == EVENT_NAMES,
            "#{profile_id} bucket #{bucket_id} path #{path_index}: captured event names/order differ")
          require!(events.map { |event| event.fetch('relative_offset') }.each_cons(2).all? { |left, right| left <= right },
            "#{profile_id} bucket #{bucket_id} path #{path_index}: event marks move backward")
          cursors[:substreams] = names_cursor
          cursors[:substreams_marks] += count * 16
          path_record['events'] = events
        end
        require!(cursors.fetch(:substreams) == decoded.fetch(:substreams).bytesize,
          "#{profile_id} bucket #{bucket_id}: unreferenced names-list bytes remain")
        require!(cursors.fetch(:substreams_marks) == decoded.fetch(:substreams_marks).bytesize,
          "#{profile_id} bucket #{bucket_id}: unreferenced event-mark bytes remain")

        ordered_paths = pending_paths
        offsets = ordered_paths.map { |path_record| path_record.fetch('data_offset') }
        require!(offsets.all? { |offset| offset.is_a?(Integer) && offset >= 0 && offset < decoded.fetch(:data).bytesize },
          "#{profile_id} bucket #{bucket_id}: path Data mark is outside Data") unless ordered_paths.empty?
        require!(offsets.each_cons(2).all? { |left, right| left < right },
          "#{profile_id} bucket #{bucket_id}: path Data marks are not strictly increasing")
        require!(ordered_paths.empty? ? decoded.fetch(:data).empty? : offsets.first.zero?,
          "#{profile_id} bucket #{bucket_id}: path Data slices do not start at stream offset zero")

        ordered_paths.each_with_index do |path_record, path_index|
          ending = ordered_paths[path_index + 1]&.fetch('data_offset') || decoded.fetch(:data).bytesize
          require!(ending > path_record.fetch('data_offset'),
            "#{profile_id} bucket #{bucket_id}: path Data slice is empty or marks move backward")
          data = decoded.fetch(:data).byteslice(path_record.fetch('data_offset'), ending - path_record.fetch('data_offset')).to_s.b
          path_record['data_hex'] = hex(data)
          path_record['data_bytes'] = data.bytesize
          path_record['path_ordinal'] = path_index
          observed = decode_path_string_data!(data, path_record.fetch('events'), path_record.fetch('row_count'),
                                              path_record.fetch('expected_values_hex'),
                                              "#{profile_id} bucket #{bucket_id} chunk #{path_record.fetch('chunk_index')} path #{path_record.fetch('path')}")
          path_record['physical'] = observed
        end
        require!(ordered_paths.empty? ||
                 ordered_paths.last.fetch('data_offset') + ordered_paths.last.fetch('data_bytes') == decoded.fetch(:data).bytesize,
          "#{profile_id} bucket #{bucket_id}: path Data slices do not cover the decoded Data stream")

        cursor = 0
        bucket_chunks.each_with_index do |chunk, chunk_index|
          require_contiguous_offset!(chunk.fetch('data_offset'), cursor,
            "#{profile_id} bucket #{bucket_id} chunk Data cursor")
          paths = chunk.fetch('paths')
          if paths.any?
            require_contiguous_offset!(paths.first.fetch('data_offset'), cursor,
              "#{profile_id} bucket #{bucket_id} chunk first path mark")
            after_chunk_path = pending_paths.drop_while { |path| path.fetch('chunk_index') <= chunk_index }.first
            cursor = after_chunk_path ? after_chunk_path.fetch('data_offset') : decoded.fetch(:data).bytesize
          end
        end
        require!(cursor == decoded.fetch(:data).bytesize,
          "#{profile_id} bucket #{bucket_id}: chunk Data cursor does not end at stream EOF")
      end

      profile_chunks.each_with_index do |chunk, chunk_index|
        copy_chunk = copy_chunks.fetch(chunk_index)
        expected_union = copy_chunk.fetch('expected_rows').flat_map do |row|
          row.map { |entry| entry.fetch('path_hex') }
        end.uniq.sort
        actual_paths = chunk.fetch('buckets').flat_map do |bucket|
          bucket.fetch('paths').map { |path| path.fetch('path_hex') }
        end
        require!(actual_paths.size == actual_paths.uniq.size && actual_paths.sort == expected_union,
          "#{profile_id} chunk #{chunk_index}: combined bucket paths are not exactly the Copy row-key union")
      end

      {
        'profile_id' => profile_id,
        'kind' => expectation.fetch(:kind).to_s,
        'bucket_count' => bucket_count,
        'chunks' => profile_chunks,
      }
    rescue KeyError => error
      raise ReconcileError, "#{profile_id}: path profile lacks #{error.key.inspect}"
    end
  end

  def derive_manifest(capture_root)
    root, summary, copy_manifest, details_by_id, invocations = load_capture!(capture_root)
    profiles = derive_path_profiles(summary, copy_manifest, details_by_id)
    records = profiles.sum do |profile|
      profile.fetch('chunks').sum do |chunk|
        chunk.fetch('buckets').sum { |bucket| bucket.fetch('paths').size }
      end
    end
    require!(profiles.map { |profile| profile.fetch('profile_id') } == PROFILE_ORDER,
      'derived W193 profile roster/order differs')
    require!(profiles.sum { |profile| profile.fetch('chunks').size } == 42,
      'derived W193 structure chunk count differs from 42')
    plain = profiles.flat_map { |profile| profile.fetch('chunks') }
      .flat_map { |chunk| chunk.fetch('buckets') }
      .flat_map { |bucket| bucket.fetch('paths') }
    require!(plain.any? { |path| path.fetch('physical').fetch('granule_format') == 'PLAIN' },
      'capture does not qualify PLAIN discriminator granules')
    require!(plain.any? { |path| path.fetch('physical').fetch('granule_format') == 'COMPACT' },
      'capture does not qualify COMPACT discriminator granules')
    require!(plain.any? { |path| path.fetch('physical').fetch('decoded_values_hex').any?(&:nil?) },
      'capture does not qualify a NULL row discriminator')
    manifest = {
      'format' => FORMAT,
      'capture_root' => root,
      'source_revision' => W191::SOURCE_REVISION,
      'runtime_pin' => {
        'version' => W191::RUNTIME_VERSION,
        'build' => W191::RUNTIME_BUILD,
        'sha256' => W191::RUNTIME_SHA256,
      },
      'stream_inventory_sha256' => source_inventory_hash(summary),
      'profile_ids' => PROFILE_ORDER,
      'profiles' => profiles,
      'source_checks' => {
        'w191_raw_part_streams_authenticated' => true,
        'w192_copy_slices_bound_to_authored_sql_and_literals' => true,
        'path_values_independently_decoded_from_raw_data' => true,
        'string_null_plain_and_compact_capture_coverage' => true,
        'shared_variant_actual_type' => 'String',
        'structure_chunk_count' => 42,
        'path_record_count' => records,
        'physical_data_byte_count' => plain.sum { |path| path.fetch('data_bytes') },
        'invocation_count' => invocations.fetch(:count),
      },
    }
    encoded = JSON.generate(manifest) + "\n"
    require!(encoded.bytesize <= MAX_MANIFEST_BYTES, 'derived W193 manifest exceeds bound')
    [manifest, encoded]
  rescue KeyError => error
    raise ReconcileError, "W193 capture lacks #{error.key.inspect}"
  end

  def compare_manifest!(supplied_path, expected_manifest)
    supplied = W191.parse_json_file(supplied_path, MAX_MANIFEST_BYTES, 'W193 path manifest')
    require!(supplied == expected_manifest, 'supplied W193 manifest differs from fresh authenticated source derivation')
    true
  end

  def validate_helper_output!(payload, expected_manifest, label)
    require!(payload.is_a?(Hash), "#{label}: root is not an object")
    require!(payload.keys.sort == %w[budget_scope chunk_count format path_record_count path_records physical_data_byte_count profile_ids read_budget write_budget].sort,
      "#{label}: root keys differ")
    require!(payload.fetch('format') == 'object_shared_path_w193_helper_v1', "#{label}: output format differs")
    require!(payload.fetch('profile_ids') == PROFILE_ORDER, "#{label}: profile roster/order differs")
    require!(payload.fetch('chunk_count') == 42, "#{label}: chunk count differs")
    require!(payload.fetch('budget_scope') == 'one read and one write budget shared across all path records',
      "#{label}: caller-owned budget scope differs")
    expected_records = expected_manifest.fetch('profiles').flat_map do |profile|
      profile.fetch('chunks').flat_map do |chunk|
        chunk.fetch('buckets').flat_map do |bucket|
          bucket.fetch('paths').map do |path|
            [profile.fetch('profile_id'), bucket.fetch('bucket_id'), chunk.fetch('chunk_index'), path]
          end
        end
      end
    end
    actual_records = payload.fetch('path_records')
    require!(actual_records.is_a?(Array) && actual_records.size == expected_records.size,
      "#{label}: path record count differs")
    require!(payload.fetch('path_record_count') == expected_records.size,
      "#{label}: declared path record count differs")
    previous_read = {'node_count' => 0, 'element_count' => 0, 'wire_byte_count' => 0}
    previous_write = {'node_count' => 0, 'element_count' => 0, 'wire_byte_count' => 0}
    expected_records.each_with_index do |(profile_id, bucket_id, chunk_index, expected), index|
      actual = actual_records.fetch(index)
      record_label = "#{label} path record #{index}"
      required_keys = %w[profile_id bucket_id chunk_index path path_hex row_count type structure_types_by_site events data_hex reencoded_data_hex decoded_values_hex physical_data_bytes read_budget_after write_budget_after]
      require!(actual.is_a?(Hash) && actual.keys.sort == required_keys.sort,
        "#{record_label}: record keys differ")
      require!(actual.fetch('profile_id') == profile_id && actual.fetch('bucket_id') == bucket_id &&
               actual.fetch('chunk_index') == chunk_index && actual.fetch('path') == expected.fetch('path') &&
               actual.fetch('path_hex') == expected.fetch('path_hex') &&
               actual.fetch('row_count') == expected.fetch('row_count') &&
               actual.fetch('type') == expected.fetch('type') &&
               actual.fetch('structure_types_by_site') == expected.fetch('structure_types_by_site'),
        "#{record_label}: path identity or type differs")
      expected_events = expected.fetch('events').map do |event|
        {'name' => event.fetch('name'), 'relative_offset' => event.fetch('relative_offset')}
      end
      require!(actual.fetch('events') == expected_events,
        "#{record_label}: ordered event names/offsets differ from authenticated mark metadata")
      require!(actual.fetch('data_hex') == expected.fetch('data_hex'),
        "#{record_label}: raw Data bytes differ from authenticated capture")
      require!(actual.fetch('reencoded_data_hex') == expected.fetch('data_hex'),
        "#{record_label}: re-encoded Data bytes differ from stock capture")
      require!(actual.fetch('decoded_values_hex') == expected.dig('physical', 'decoded_values_hex'),
        "#{record_label}: decoded String/NULL values differ from independent raw decode")
      require!(actual.fetch('physical_data_bytes') == expected.fetch('data_bytes'),
        "#{record_label}: physical Data byte extent differs")
      %w[read_budget_after write_budget_after].each do |key|
        snapshot = actual.fetch(key)
        require!(snapshot.is_a?(Hash) && snapshot.keys.sort == %w[element_count node_count wire_byte_count].sort,
          "#{record_label}: #{key} counters are malformed")
        snapshot.each_value do |count|
          require!(count.is_a?(Integer) && count >= 0, "#{record_label}: #{key} counter is invalid")
        end
      end
      read_after = actual.fetch('read_budget_after')
      write_after = actual.fetch('write_budget_after')
      previous_read.each do |metric, prior|
        require!(read_after.fetch(metric) >= prior, "#{record_label}: read budget #{metric} reset or decreased")
        require!(write_after.fetch(metric) >= previous_write.fetch(metric),
          "#{record_label}: write budget #{metric} reset or decreased")
      end
      require!(read_after.fetch('wire_byte_count') > previous_read.fetch('wire_byte_count'),
        "#{record_label}: nonempty path slice did not increase the shared read wire counter")
      require!(write_after.fetch('wire_byte_count') > previous_write.fetch('wire_byte_count'),
        "#{record_label}: nonempty path slice did not increase the shared write wire counter")
      previous_read = read_after
      previous_write = write_after
    end
    physical_total = expected_records.sum { |_profile, _bucket, _chunk, path| path.fetch('data_bytes') }
    require!(payload.fetch('physical_data_byte_count') == physical_total,
      "#{label}: physical Data byte total differs from authenticated slices")
    %w[read_budget write_budget].each do |key|
      budget = payload.fetch(key)
      require!(budget.is_a?(Hash) && budget.keys.sort == %w[element_count node_count wire_byte_count].sort,
        "#{label}: #{key} counters are malformed")
      budget.each_value { |count| require!(count.is_a?(Integer) && count >= 0, "#{label}: #{key} counter is invalid") }
    end
    require!(payload.fetch('read_budget') == previous_read && payload.fetch('write_budget') == previous_write,
      "#{label}: final caller-owned budget differs from the last per-path snapshot")
    true
  rescue KeyError => error
    raise ReconcileError, "#{label}: helper output lacks #{error.key.inspect}"
  end

  def reconcile(capture_root, manifest_path, debug_path, release_path)
    expected_manifest, = derive_manifest(capture_root)
    compare_manifest!(manifest_path, expected_manifest)
    debug = W191.parse_json_file(debug_path, MAX_HELPER_BYTES, 'DEBUG W193 helper output')
    release = W191.parse_json_file(release_path, MAX_HELPER_BYTES, 'RELEASE W193 helper output')
    require!(debug == release, 'DEBUG and RELEASE W193 helper output differs')
    validate_helper_output!(debug, expected_manifest, 'DEBUG helper')
    validate_helper_output!(release, expected_manifest, 'RELEASE helper')
    {
      'status' => 'reconciled_w193_stock_path_data',
      'capture_root' => expected_manifest.fetch('capture_root'),
      'stream_inventory_sha256' => expected_manifest.fetch('stream_inventory_sha256'),
      'manifest_sha256' => Digest::SHA256.hexdigest(JSON.generate(expected_manifest) + "\n"),
      'profile_ids' => PROFILE_ORDER,
      'structure_chunk_count' => 42,
      'path_record_count' => expected_manifest.dig('source_checks', 'path_record_count'),
      'exact_debug_release_and_raw_data_match' => true,
      'raw_data_and_metadata_bound_to_w191_streams' => true,
      'copy_rows_bound_to_w192_authored_literals' => true,
      'claim_boundary' => 'Retained W191 stock String SharedVariant path Data slices only; not a general Dynamic type/profile admission claim or persisted ADVANCED reader/writer qualification.',
    }
  end

  def self_test!
    prefix = [4].pack('Q<') + "\x00".b
    mode = [1].pack('Q<')
    discr = "\x02\x00\x00\xff".b
    child = "\x15\x01v".b
    sizes = [child.bytesize].pack('Q<')
    data = prefix + mode + discr + sizes + child
    events = EVENT_NAMES.zip([0, 9, 17, 21, 29]).map do |name, offset|
      {'name' => name, 'relative_offset' => offset}
    end
    expected = ['76', nil]
    decoded = decode_path_string_data!(data, events, 2, expected, 'W193 self-test positive')
    require!(decoded.fetch('decoded_values_hex') == expected && decoded.fetch('granule_format') == 'PLAIN',
      'W193 self-test positive path failed')

    compact_children = "\x15\x01v\x15\x01w".b
    compact_sizes = [3, 3].pack('Q<2')
    compact_data = prefix + mode + "\x02\x01\x00".b + compact_sizes + compact_children
    compact_events = EVENT_NAMES.zip([0, 9, 17, 20, 36]).map do |name, offset|
      {'name' => name, 'relative_offset' => offset}
    end
    compact = decode_path_string_data!(compact_data, compact_events, 2, ['76', '77'],
                                       'W193 self-test compact positive')
    require!(compact.fetch('granule_format') == 'COMPACT' &&
             compact.fetch('decoded_values_hex') == ['76', '77'],
      'W193 self-test positive COMPACT path failed')

    reject = lambda do |label, changed_data = data, changed_events = events|
      accepted = true
      begin
        decode_path_string_data!(changed_data, changed_events, 2, expected, "W193 self-test #{label}")
      rescue ReconcileError
        accepted = false
      end
      require!(!accepted, "W193 self-test accepted mutation #{label}")
    end
    bad_prefix = data.dup
    bad_prefix.setbyte(8, 1)
    reject.call('Dynamic ordinary type count', bad_prefix)
    reject.call('discriminator row count', data.dup.tap { |bytes| bytes.setbyte(17, 3) })
    shifted_events = Marshal.load(Marshal.dump(events))
    shifted_events[2]['relative_offset'] += 1
    reject.call('event offset', data, shifted_events)
    renamed_events = Marshal.load(Marshal.dump(events))
    renamed_events[2]['name'] = '.variant_discr_mutated'
    reject.call('event name', data, renamed_events)

    metadata = [0, 0, 0, 0].pack('Q<4')
    names_pointer = metadata.byteslice(0, 16).unpack('Q<2')
    require!(names_pointer == [0, 0], 'W193 self-test metadata pointer control differs')
    metadata.setbyte(0, 1)
    mutated_pointer = metadata.byteslice(0, 16).unpack('Q<2')
    pointer_rejected = false
    begin
      require_contiguous_offset!(mutated_pointer.first, 0, 'W193 self-test metadata names pointer')
    rescue ReconcileError
      pointer_rejected = true
    end
    require!(pointer_rejected, 'W193 self-test accepted a mutated metadata pointer')
    {
      'positive_plain_string_with_null' => 'accepted',
      'positive_compact_shared_string' => 'accepted',
      'dynamic_prefix_mutation' => 'rejected',
      'discriminator_count_mutation' => 'rejected',
      'event_offset_mutation' => 'rejected',
      'event_name_mutation' => 'rejected',
      'metadata_pointer_mutation' => 'rejected',
    }
  end

  def main(argv)
    options = {}
    OptionParser.new do |parser|
      parser.banner = 'Usage: ruby scripts/reconcile_object_shared_path_w193.rb --capture-root ROOT (--emit-manifest PATH | --manifest PATH --debug-output PATH --release-output PATH)'
      parser.on('--capture-root ROOT', 'authenticated immutable W191 capture root') { |value| options[:capture_root] = value }
      parser.on('--emit-manifest PATH', 'derive and exclusively create bounded W193 path manifest') { |value| options[:emit_manifest] = value }
      parser.on('--manifest PATH', 'manifest previously emitted from this capture') { |value| options[:manifest] = value }
      parser.on('--debug-output PATH', 'DEBUG Crystal helper JSON output') { |value| options[:debug_output] = value }
      parser.on('--release-output PATH', 'RELEASE Crystal helper JSON output') { |value| options[:release_output] = value }
    end.parse!(argv)
    require!(argv.empty?, 'unexpected positional arguments')
    require!(options[:capture_root].is_a?(String), '--capture-root is required')
    mutation_controls = self_test!
    if options[:emit_manifest]
      require!(!options[:manifest] && !options[:debug_output] && !options[:release_output],
        '--emit-manifest cannot be combined with helper comparison paths')
      _manifest, encoded = derive_manifest(options[:capture_root])
      File.open(options[:emit_manifest], File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(encoded)
        file.flush
      end
      puts JSON.generate({
        'status' => 'manifest_derived',
        'manifest_sha256' => Digest::SHA256.hexdigest(encoded),
        'bytes' => encoded.bytesize,
        'self_test' => mutation_controls,
      })
      return 0
    end
    require!(options[:manifest].is_a?(String) && options[:debug_output].is_a?(String) && options[:release_output].is_a?(String),
      '--manifest, --debug-output, and --release-output are required for comparison')
    result = reconcile(options[:capture_root], options[:manifest], options[:debug_output], options[:release_output])
    result['self_test'] = mutation_controls
    puts JSON.pretty_generate(result)
    0
  rescue ReconcileError, W191::ReconcileError, W192::ReconcileError, Errno::ENOENT, Errno::EACCES,
         Errno::ELOOP, Errno::EEXIST, JSON::ParserError, OptionParser::ParseError => error
    warn "W193 path reconcile failed: #{error.message}"
    1
  end
end

exit ReconcileObjectSharedPathW193.main(ARGV) if $PROGRAM_NAME == __FILE__
