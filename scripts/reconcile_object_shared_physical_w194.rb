#!/usr/bin/env ruby
# Independently bind the authenticated W191/W193 stock capture to the W194
# paired six-lane codec helper. This is a finite fixture reconciler, not a
# persisted-format admission claim.

require 'digest'
require 'json'
require 'optparse'
require_relative 'reconcile_object_shared_advanced_w191'
require_relative 'reconcile_object_shared_path_w193'
require_relative 'probe_object_shared_advanced_w191'

module ReconcileObjectSharedPhysicalW194
  extend self

  W191 = ReconcileObjectSharedAdvancedW191
  W193 = ReconcileObjectSharedPathW193
  Probe = ProbeObjectSharedAdvancedW191
  PROFILE_IDS = W191::PROFILE_ORDER
  FORMAT = 'object_shared_physical_w194_manifest_v1'
  HELPER_FORMAT = 'object_shared_physical_w194_helper_v1'
  HELPER_OUTPUT_NAME = 'object_shared_physical_w194_helper_v1.json'
  MAX_MANIFEST_BYTES = 16 * 1024 * 1024
  MAX_HELPER_BYTES = 16 * 1024 * 1024
  MAX_RAW_STREAM_BYTES = W191::MAX_STREAM_BYTES
  MAX_COMPRESSED_BYTES = W191::MAX_COMPRESSED_BYTES
  FRAME_BYTES = [17, 37].freeze
  LANE_NAMES = %w[
    structure data paths_marks substreams substreams_marks paths_substreams_metadata
  ].freeze
  INVOCATION_RECORD_KEYS = %w[
    label process_kind argv argv_file argv_sha256 stdin_file stdin_bytes stdin_sha256
    exit signal timed_out timeout_seconds termination_grace_seconds max_threads
    max_memory_usage_bytes max_memory_usage_applicable required_outer_run_safe_memory_limit_bytes
    expected_binary_sha256 binary_sha_before binary_sha_after spawn_error stdin_write_error
    stdout_read_error stderr_read_error process_classification stdout_bytes stdout_sha256
    stderr_bytes stderr_sha256 stdout_file stderr_file
  ].freeze
  PARENT_ROWS = [2, 2, 2, 2].freeze
  MARK_ROWS = PARENT_ROWS + [0]

  class ReconcileError < StandardError; end

  def require!(condition, message)
    raise ReconcileError, message unless condition
  end

  def hex(bytes)
    bytes.unpack1('H*')
  end

  def read_hex(value, label, maximum = MAX_RAW_STREAM_BYTES)
    require!(value.is_a?(String) && value.bytesize.even?, "#{label}: malformed hex")
    require!(value.bytesize / 2 <= maximum, "#{label}: hex exceeds bound")
    require!(value.match?(/\A[0-9a-f]*\z/), "#{label}: expected lowercase hex")
    [value].pack('H*').b
  end

  def plain_file(path, max_bytes, label)
    require!(File.file?(path) && !File.symlink?(path), "#{label} is not a plain file")
    size = File.size(path)
    require!(size <= max_bytes, "#{label} exceeds #{max_bytes} bytes")
    bytes = File.binread(path)
    require!(bytes.bytesize == size, "#{label} changed while being read")
    bytes
  end

  def contained_real_file!(root, path, label)
    root_real = File.realpath(root)
    require!(File.file?(path) && !File.symlink?(path), "#{label} is absent or symlinked")
    real = File.realpath(path)
    require!(real.start_with?(root_real + File::SEPARATOR), "#{label} escapes the capture root")
    real
  end

  def logical_name(kind, bucket_id, lane)
    column = kind == 'array' ? 'a' : 'j'
    W193.bucket_stream_names(column, bucket_id).fetch(lane.to_sym)
  end

  def raw_mark_triples!(profile, logical_stream, label)
    triples = profile.fetch('part').fetch('mark_triples').fetch(logical_stream)
    require!(triples.is_a?(Array) && triples.size == 5, "#{label}: expected five raw mark triples")
    triples.each_with_index do |triple, index|
      require!(triple.is_a?(Array) && triple.size == 3 &&
               triple.all? { |part| part.is_a?(Integer) && part >= 0 },
        "#{label}[#{index}]: malformed raw mark triple")
    end
    require!(triples.map { |triple| triple[2] } == MARK_ROWS,
      "#{label}: physical rows differ from the authored outer parent grid")
    triples
  end

  def mark_offset(details, logical_stream, triple, label)
    capture = details.fetch(:frame_by_stream).fetch(logical_stream) do
      raise ReconcileError, "#{label}: raw stream frame map is absent"
    end
    W191.coordinate_to_decoded([triple[0], triple[1]], capture.fetch(:frames),
      capture.fetch(:compressed_bytes), capture.fetch(:decoded_bytes), label)
  end

  def lane_descriptor(root, profile, details, kind, bucket_id, lane)
    logical = logical_name(kind, bucket_id, lane)
    capture = profile.fetch('stream_captures').fetch(logical)
    bin_name = capture.fetch('hashed_file')
    require!(bin_name.is_a?(String) && bin_name.match?(/\A[a-f0-9]{32}\.bin\z/),
      "#{profile.fetch('id')} #{logical}: invalid hashed file name")
    mark_name = bin_name.sub(/\.bin\z/, '.mrk2')
    part = profile.fetch('part')
    part_path = File.realpath(part.fetch('part_path'))
    bin_path = contained_real_file!(root, File.join(part_path, bin_name), "#{logical} .bin")
    mark_path = contained_real_file!(root, File.join(part_path, mark_name), "#{logical} .mrk2")
    inventory = part.fetch('stream_file_inventory')
    data_info = inventory.fetch(bin_name)
    marks_info = inventory.fetch(mark_name)
    data_bytes = plain_file(bin_path, MAX_COMPRESSED_BYTES, "#{logical} .bin")
    marks_bytes = plain_file(mark_path, MAX_RAW_STREAM_BYTES, "#{logical} .mrk2")
    require!(data_info.fetch('size') == data_bytes.bytesize &&
             data_info.fetch('sha256') == Digest::SHA256.hexdigest(data_bytes),
      "#{logical} .bin differs from authenticated W191 inventory")
    require!(marks_info.fetch('size') == marks_bytes.bytesize &&
             marks_info.fetch('sha256') == Digest::SHA256.hexdigest(marks_bytes),
      "#{logical} .mrk2 differs from authenticated W191 inventory")
    require!(marks_bytes.bytesize == 5 * 24, "#{logical}: raw .mrk2 is not five plain triples")
    actual_triples = marks_bytes.unpack('Q<*').each_slice(3).to_a
    triples = raw_mark_triples!(profile, logical, "#{logical} captured mark grid")
    require!(actual_triples == triples, "#{logical}: bytes differ from captured raw mark triples")
    decoded_size = details.fetch(:frame_by_stream).fetch(logical).fetch(:decoded_bytes)
    decoded_offsets = triples.map do |triple|
      mark_offset(details, logical, triple, "#{logical} mark coordinate").tap do |offset|
        require!(offset <= decoded_size, "#{logical}: decoded mark exceeds stream")
      end
    end
    require!(decoded_offsets == decoded_offsets.sort, "#{logical}: decoded mark coordinates move backward")
    require!(decoded_offsets.first == 0 && decoded_offsets.last == decoded_size,
      "#{logical}: real/terminal marks do not span the decoded stream")
    {
      'name' => lane,
      'logical_stream' => logical,
      'data_path' => bin_path,
      'marks_path' => mark_path,
      'expected_data_size' => data_bytes.bytesize,
      'expected_marks_size' => marks_bytes.bytesize,
      'data_sha256' => data_info.fetch('sha256'),
      'marks_sha256' => marks_info.fetch('sha256'),
      'mark_triples' => triples,
      'decoded_mark_offsets' => decoded_offsets,
    }
  end

  def expected_chunk(chunk, structure_record, lane_inputs, details, label)
    row_count = chunk.fetch('row_count')
    require!(row_count.is_a?(Integer) && row_count >= 0 && row_count <= MAX_RAW_STREAM_BYTES,
      "#{label}: row count is out of bounds")
    paths = chunk.fetch('paths')
    require!(paths.is_a?(Array) && paths.size <= 65_536, "#{label}: path count exceeds bound")
    path_names = paths.map { |path| path.fetch('path') }
    require!(path_names == path_names.uniq && path_names == path_names.sort_by(&:b),
      "#{label}: path roster is duplicate or not byte sorted")
    transport_offsets = %w[data paths_marks paths_substreams_metadata].to_h do |lane_name|
      lane = lane_inputs.find { |candidate| candidate.fetch('name') == lane_name }
      require!(lane, "#{label}: source #{lane_name} lane is absent")
      stream = lane.fetch('logical_stream')
      frame = details.fetch(:frame_by_stream).fetch(stream)
      pair = structure_record.fetch(:transport_pairs).fetch(lane_name)
      offset = W191.coordinate_to_decoded(pair, frame.fetch(:frames),
        frame.fetch(:compressed_bytes), frame.fetch(:decoded_bytes), "#{label} source #{lane_name} pointer")
      require!(offset <= frame.fetch(:decoded_bytes), "#{label}: source #{lane_name} pointer exceeds decoded lane")
      [lane_name, offset]
    end
    {
      'row_count' => row_count,
      'structure_record_hex' => chunk.fetch('structure_record_hex'),
      'structure_prefix_hex' => hex(structure_record.fetch(:prefix_bytes)),
      'transport_offsets' => transport_offsets,
      'paths' => paths.map do |path|
        data = read_hex(path.fetch('data_hex'), "#{label} path Data")
        events = path.fetch('events')
        require!(events.is_a?(Array) && events.size <= W193::MAX_EVENTS_PER_PATH,
          "#{label} path event count exceeds bound")
        offsets = events.map { |event| event.fetch('relative_offset') }
        require!(offsets.all? { |offset| offset.is_a?(Integer) && offset >= 0 && offset <= data.bytesize } &&
                 offsets.each_cons(2).all? { |left, right| left <= right },
          "#{label} path event coordinates are out of range or move backward")
        {
          'name' => path.fetch('path'),
          'data_hex' => hex(data),
          'events' => events.map do |event|
            {'name' => event.fetch('name'), 'relative_offset' => event.fetch('relative_offset')}
          end,
        }
      end,
    }
  end

  def derive_manifest(capture_root)
    root, summary, copy_manifest, details_by_id, invocation_counts = W193.load_capture!(capture_root)
    path_profiles = W193.derive_path_profiles(summary, copy_manifest, details_by_id)
    require!(path_profiles.map { |profile| profile.fetch('profile_id') } == PROFILE_IDS,
      'W193 profile order differs from W191')
    source_profiles = summary.fetch('profiles').to_h { |profile| [profile.fetch('id'), profile] }
    paths_by_id = path_profiles.to_h { |profile| [profile.fetch('profile_id'), profile] }
    result_profiles = PROFILE_IDS.map do |profile_id|
      source = source_profiles.fetch(profile_id)
      derived = paths_by_id.fetch(profile_id)
      kind = source.fetch('kind')
      expected = W191::PROFILE_EXPECTATIONS.fetch(profile_id)
      bucket_count = expected.fetch(:buckets)
      layout = source.fetch('physical_layout').fetch('object_structure')
      expected_version = expected.fetch(:mode) == 'advanced' ? 2 : 3
      require!(source.fetch('kind') == expected.fetch(:kind).to_s &&
               layout.fetch('shared_data_version') == expected_version &&
               layout.fetch('bucket_count') == bucket_count &&
               source.fetch('physical_layout').fetch('actual_shared_bucket_count') == bucket_count,
        "#{profile_id}: captured Object structure/version/bucket profile differs")
      require!(source.fetch('part').fetch('marks') == '5' &&
               source.fetch('part').fetch('rows').to_s == '8' &&
               source.fetch('part').fetch('plain_mrk2_only') == true,
        "#{profile_id}: captured part dimensions/mark format differ")
      details = details_by_id.fetch(profile_id)
      path_chunks = derived.fetch('chunks')
      chunks_by_bucket = Array.new(bucket_count) { [] }
      path_chunks.each do |chunk|
        chunk.fetch('buckets').each do |bucket|
          chunks_by_bucket.fetch(bucket.fetch('bucket_id')) << bucket.merge('row_count' => chunk.fetch('row_count'))
        end
      end

      buckets = bucket_count.times.map do |bucket_id|
        lane_inputs = LANE_NAMES.map do |lane|
          lane_descriptor(root, source, details, kind, bucket_id, lane)
        end
        structure_lane = lane_inputs.find { |lane| lane.fetch('name') == 'structure' }
        structure_stream = structure_lane.fetch('logical_stream')
        structure_bytes = details.fetch(:decoded_by_stream).fetch(structure_stream)
        raw_records = W191.read_structure_records(structure_bytes, "#{profile_id} bucket #{bucket_id} structure")
        offsets = structure_lane.fetch('decoded_mark_offsets')
        bucket_chunks = chunks_by_bucket.fetch(bucket_id)
        require!(bucket_chunks.size == raw_records.size,
          "#{profile_id} bucket #{bucket_id}: W193 and raw structure chunk counts differ")
        raw_records.each_with_index do |record, chunk_index|
          path_chunk = bucket_chunks.fetch(chunk_index)
          require!(path_chunk.fetch('structure_record_hex') == hex(record.fetch(:record_bytes)) &&
                   path_chunk.fetch('row_count') == record.fetch(:rows) &&
                   path_chunk.fetch('paths').map { |path| path.fetch('path').b } == record.fetch(:paths_bytes),
            "#{profile_id} bucket #{bucket_id} chunk #{chunk_index}: W193 path record differs from raw structure")
        end

        parents = 4.times.map do |mark_index|
          start_offset = offsets.fetch(mark_index)
          end_offset = offsets.fetch(mark_index + 1)
          require!(start_offset <= end_offset,
            "#{profile_id} bucket #{bucket_id}: parent mark interval moves backward")
          selected_indices = raw_records.each_index.select do |index|
            record = raw_records.fetch(index)
            record.fetch(:byte_start) >= start_offset && record.fetch(:byte_end) <= end_offset
          end
          selected = selected_indices.map { |index| raw_records.fetch(index) }
          if selected.empty?
            require!(start_offset == end_offset,
              "#{profile_id} bucket #{bucket_id} mark #{mark_index}: nonempty structure interval lacks a record")
          else
            require!(selected.first.fetch(:byte_start) == start_offset &&
                     selected.last.fetch(:byte_end) == end_offset,
              "#{profile_id} bucket #{bucket_id} mark #{mark_index}: structure records do not cover the interval")
            selected.each_cons(2) do |left, right|
              require!(left.fetch(:byte_end) == right.fetch(:byte_start),
                "#{profile_id} bucket #{bucket_id} mark #{mark_index}: structure record gap/overlap")
            end
          end
          chunk_records = selected_indices.map do |chunk_index|
            expected_chunk(bucket_chunks.fetch(chunk_index), raw_records.fetch(chunk_index), lane_inputs, details,
              "#{profile_id} bucket #{bucket_id} chunk #{chunk_index}")
          end
          {'physical_rows' => structure_lane.fetch('mark_triples').fetch(mark_index).fetch(2),
           'chunks' => chunk_records}
        end
        require!(parents.map { |parent| parent.fetch('physical_rows') } == PARENT_ROWS,
          "#{profile_id} bucket #{bucket_id}: physical parent grid differs")
        {
          'bucket_id' => bucket_id,
          'lanes' => lane_inputs,
          'parent_rows' => parents.map { |parent| parent.fetch('physical_rows') },
          'parents' => parents,
          'structure_record_count' => raw_records.size,
        }
      end
      require!(buckets.all? { |bucket| bucket.fetch('parent_rows') == buckets.first.fetch('parent_rows') },
        "#{profile_id}: buckets disagree on physical parent grid")
      observed_chunk_rows = buckets.first.fetch('parents').flat_map do |parent|
        parent.fetch('chunks').map { |chunk| chunk.fetch('row_count') }
      end
      require!(observed_chunk_rows == expected.fetch(:rows),
        "#{profile_id}: logical chunk schedule differs from actual structure mark intervals")
      if kind == 'root'
        grouped_rows = buckets.first.fetch('parents').map do |parent|
          parent.fetch('chunks').sum { |chunk| chunk.fetch('row_count') }
        end
        require!(grouped_rows == PARENT_ROWS,
          "#{profile_id}: root logical chunk rows differ from physical parent rows")
      end
      {
        'profile_id' => profile_id,
        'kind' => kind,
        'version' => layout.fetch('shared_data_version'),
        'bucket_count' => bucket_count,
        'parent_rows' => buckets.first.fetch('parent_rows'),
        'buckets' => buckets,
      }
    end
    manifest = {
      'format' => FORMAT,
      'capture_root' => root,
      'source_revision' => W191::SOURCE_REVISION,
      'runtime_pin' => {'version' => W191::RUNTIME_VERSION, 'build' => W191::RUNTIME_BUILD, 'sha256' => W191::RUNTIME_SHA256},
      'profile_ids' => PROFILE_IDS,
      'frame_bytes' => FRAME_BYTES,
      'source_inventory_sha256' => W193.source_inventory_hash(summary),
      'source_invocation_count' => invocation_counts.fetch(:count),
      'limits' => {
        'max_compressed_lane_bytes' => MAX_COMPRESSED_BYTES,
        'max_decoded_lane_bytes' => MAX_RAW_STREAM_BYTES,
        'max_profiles' => PROFILE_IDS.size,
        'max_parent_marks_per_profile' => 4,
        'max_buckets_total' => result_profiles.sum { |profile| profile.fetch('bucket_count') },
      },
      'profiles' => result_profiles,
      'claims' => {
        'source_lanes_rederived_from_w191_w193' => true,
        'chunks_bound_to_each_bucket_structure_mark_intervals' => true,
        'physical_parent_rows_are_not_logical_chunk_rows' => true,
        'actual_path_value_decode_scope' => 'W193 captured String shared paths only',
        'persisted_part_admission' => false,
      },
    }
    encoded = JSON.generate(manifest) + "\n"
    require!(encoded.bytesize <= MAX_MANIFEST_BYTES, 'W194 manifest exceeds bound')
    [manifest, encoded]
  rescue KeyError => error
    raise ReconcileError, "W194 source capture lacks #{error.key.inspect}"
  end

  def checked_output_root!(path, label)
    require!(File.directory?(path) && !File.symlink?(path), "#{label} must be an existing real directory")
    real = File.realpath(path)
    require!(File.dirname(real) == File.realpath('/private/tmp') && real == path,
      "#{label} must be a canonical direct child of /private/tmp")
    real
  end

  def safe_relative(root, relative, label)
    require!(relative.is_a?(String) && !relative.empty? && !relative.start_with?('/') &&
             relative.split('/').none? { |part| part.empty? || part == '.' || part == '..' },
      "#{label}: unsafe relative path")
    path = File.expand_path(relative, root)
    require!(path.start_with?(File.realpath(root) + File::SEPARATOR), "#{label}: path escapes generated root")
    path
  end

  def exact_keys!(hash, keys, label)
    require!(hash.is_a?(Hash), "#{label} must be an object")
    require!(hash.keys.sort == keys.sort, "#{label} keys differ")
  end

  def validate_helper_output!(path, manifest, label)
    root = checked_output_root!(File.dirname(path), "#{label} output root")
    require!(File.file?(path) && !File.symlink?(path), "#{label} output is absent or symlinked")
    require!(File.realpath(path) == File.join(root, HELPER_OUTPUT_NAME),
      "#{label} output is not the canonical helper JSON in its output root")
    output = JSON.parse(plain_file(path, MAX_HELPER_BYTES, "#{label} output"))
    exact_keys!(output, %w[format profile_ids frame_bytes source_decode_checked generated_redecode_checked profiles budgets], "#{label} output")
    require!(output.fetch('format') == HELPER_FORMAT &&
             output.fetch('profile_ids') == PROFILE_IDS &&
             output.fetch('frame_bytes') == FRAME_BYTES &&
             output.fetch('source_decode_checked') == true &&
             output.fetch('generated_redecode_checked') == true,
      "#{label}: helper header differs")
    profiles = output.fetch('profiles')
    require!(profiles.is_a?(Array) && profiles.map { |profile| profile.fetch('profile_id') } == PROFILE_IDS,
      "#{label}: profile order differs")
    expected_profiles = manifest.fetch('profiles').to_h { |profile| [profile.fetch('profile_id'), profile] }
    observed_files = []
    profiles.each do |profile|
      exact_keys!(profile, %w[profile_id bucket_count buckets], "#{label} profile")
      expected = expected_profiles.fetch(profile.fetch('profile_id'))
      require!(profile.fetch('bucket_count') == expected.fetch('bucket_count'),
        "#{label}: bucket count differs")
      buckets = profile.fetch('buckets')
      require!(buckets.size == expected.fetch('bucket_count') &&
               buckets.map { |bucket| bucket.fetch('bucket_id') } == (0...buckets.size).to_a,
        "#{label}: bucket roster differs")
      buckets.each do |bucket|
        exact_keys!(bucket, %w[bucket_id parent_rows generated_sets], "#{label} bucket")
        bucket_id = bucket.fetch('bucket_id')
        expected_bucket = expected.fetch('buckets').fetch(bucket_id)
        require!(bucket.fetch('parent_rows') == expected_bucket.fetch('parent_rows'),
          "#{label}: parent rows differ")
        sets = bucket.fetch('generated_sets')
        require!(sets.map { |set| set.fetch('frame_bytes') } == FRAME_BYTES,
          "#{label}: frame-size sets differ")
        sets.each do |set|
          exact_keys!(set, %w[frame_bytes lanes], "#{label} generated set")
          frame_bytes = set.fetch('frame_bytes')
          lanes = set.fetch('lanes')
          require!(lanes.map { |lane| lane.fetch('name') } == LANE_NAMES,
            "#{label}: generated lane roster/order differs")
          lanes.each do |lane|
            exact_keys!(lane, %w[name data_file marks_file data_bytes marks_bytes data_sha256 marks_sha256 mark_triples],
              "#{label} generated lane")
            name = lane.fetch('name')
            prefix = "frame_#{frame_bytes}/#{profile.fetch('profile_id')}/bucket_#{bucket_id}/#{name}"
            data_path = safe_relative(root, lane.fetch('data_file'), "#{label} generated .bin")
            marks_path = safe_relative(root, lane.fetch('marks_file'), "#{label} generated .mrk2")
            require!(data_path == File.join(root, "#{prefix}.bin") &&
                     marks_path == File.join(root, "#{prefix}.mrk2"),
              "#{label}: lane output path is outside its assigned location")
            [data_path, marks_path].each do |file|
              require!(File.file?(file) && !File.symlink?(file), "#{label}: generated lane file absent or symlinked")
              observed_files << file.delete_prefix(root + File::SEPARATOR)
            end
            data = plain_file(data_path, MAX_COMPRESSED_BYTES, "#{label} #{name}.bin")
            marks = plain_file(marks_path, MAX_RAW_STREAM_BYTES, "#{label} #{name}.mrk2")
            require!(lane.fetch('data_bytes') == data.bytesize &&
                     lane.fetch('data_sha256') == Digest::SHA256.hexdigest(data),
              "#{label}: actual .bin size/SHA differs")
            require!(lane.fetch('marks_bytes') == marks.bytesize &&
                     lane.fetch('marks_sha256') == Digest::SHA256.hexdigest(marks),
              "#{label}: actual .mrk2 size/SHA differs")
            require!(marks.bytesize == 5 * 24, "#{label}: output .mrk2 is not four marks plus terminal")
            triples = marks.unpack('Q<*').each_slice(3).to_a
            require!(triples.map { |triple| triple[2] } == MARK_ROWS &&
                     lane.fetch('mark_triples') == triples,
              "#{label}: actual output parent mark triples differ")
          end
        end
      end
    end
    expected_lane_files = FRAME_BYTES.flat_map do |frame_bytes|
      manifest.fetch('profiles').flat_map do |profile|
        profile.fetch('buckets').flat_map do |bucket|
          LANE_NAMES.flat_map do |name|
            prefix = "frame_#{frame_bytes}/#{profile.fetch('profile_id')}/bucket_#{bucket.fetch('bucket_id')}/#{name}"
            ["#{prefix}.bin", "#{prefix}.mrk2"]
          end
        end
      end
    end
    expected_lane_files.sort!
    require!(observed_files.sort == expected_lane_files, "#{label}: generated lane file roster differs")
    expected_files = (expected_lane_files + [HELPER_OUTPUT_NAME]).sort
    actual_entries = Dir.glob(File.join(root, '**', '*'), File::FNM_DOTMATCH).reject do |entry|
      %w[. ..].include?(File.basename(entry))
    end
    require!(actual_entries.none? { |entry| File.symlink?(entry) }, "#{label}: generated tree contains a symlink")
    actual_files = actual_entries.select { |entry| File.file?(entry) }
      .map { |entry| entry.delete_prefix(root + File::SEPARATOR) }.sort
    actual_directories = actual_entries.select { |entry| File.directory?(entry) }
      .map { |entry| entry.delete_prefix(root + File::SEPARATOR) }.sort
    expected_directories = expected_files.flat_map do |entry|
      current = File.dirname(entry)
      ancestors = []
      until current == '.'
        ancestors << current
        parent = File.dirname(current)
        break if parent == current
        current = parent
      end
      ancestors
    end.uniq.sort
    require!(actual_files == expected_files && actual_directories == expected_directories,
      "#{label}: generated directory/file tree is not exact")
    output
  rescue JSON::ParserError => error
    raise ReconcileError, "#{label} output JSON invalid: #{error.message}"
  rescue KeyError => error
    raise ReconcileError, "#{label} output lacks #{error.key.inspect}"
  end

  def validate_budget_snapshots!(budgets, manifest, output, generated_decoded_bytes, label)
    profiles = manifest.fetch('profiles')
    chunks = profiles.flat_map { |profile| profile.fetch('buckets').flat_map { |bucket| bucket.fetch('parents').flat_map { |parent| parent.fetch('chunks') } } }
    paths = chunks.flat_map { |chunk| chunk.fetch('paths') }
    event_count = paths.sum { |path| path.fetch('events').size }
    source_lanes = profiles.flat_map { |profile| profile.fetch('buckets').flat_map { |bucket| bucket.fetch('lanes') } }
    source_file_bytes = source_lanes.sum do |lane|
      lane.fetch('expected_data_size') + lane.fetch('expected_marks_size')
    end
    source_mark_records = source_lanes.sum { |lane| lane.fetch('expected_marks_size') / 24 }
    source_decoded_bytes = source_lanes.sum { |lane| lane.fetch('decoded_mark_offsets').last }
    generated_lanes = output.fetch('profiles').flat_map do |profile|
      profile.fetch('buckets').flat_map { |bucket| bucket.fetch('generated_sets').flat_map { |set| set.fetch('lanes') } }
    end
    generated_file_bytes = generated_lanes.sum { |lane| lane.fetch('data_bytes') + lane.fetch('marks_bytes') }
    generated_mark_records = generated_lanes.sum { |lane| lane.fetch('marks_bytes') / 24 }
    require!([chunks.size, paths.size, event_count, source_file_bytes, source_mark_records,
              source_decoded_bytes, generated_file_bytes, generated_mark_records, generated_decoded_bytes]
              .all? { |value| value.is_a?(Integer) && value > 0 },
      "#{label}: independently derived cumulative work lower bounds are empty or malformed")

    exact_keys!(budgets, %w[codec_read codec_write transport_read transport_write], "#{label} budgets")
    codec_read = budgets.fetch('codec_read')
    codec_write = budgets.fetch('codec_write')
    [codec_read, codec_write].each_with_index do |snapshot, index|
      key = index.zero? ? 'codec_read' : 'codec_write'
      exact_keys!(snapshot, %w[node_count element_count wire_byte_count], "#{label} #{key}")
      snapshot.each_value { |value| require!(value.is_a?(Integer) && value >= 0, "#{label} #{key} has invalid counter") }
    end
    require!(codec_read.fetch('node_count') >= 3 * (chunks.size + event_count) &&
             codec_read.fetch('element_count') >= 3 * (paths.size + event_count) &&
             codec_read.fetch('wire_byte_count') >= source_decoded_bytes + generated_decoded_bytes,
      "#{label}: read codec counters are below source-plus-generated reread lower bounds")
    require!(codec_write.fetch('node_count') >= 2 * (chunks.size + event_count) &&
             codec_write.fetch('element_count') >= 2 * (paths.size + event_count) &&
             codec_write.fetch('wire_byte_count') >= 2 * source_decoded_bytes,
      "#{label}: write codec counters are below two-frame source-derived work lower bounds")

    transport_read = budgets.fetch('transport_read')
    transport_write = budgets.fetch('transport_write')
    [transport_read, transport_write].each_with_index do |snapshot, index|
      key = index.zero? ? 'transport_read' : 'transport_write'
      exact_keys!(snapshot, %w[file_byte_count record_count decoded_byte_count result_byte_count], "#{label} #{key}")
      snapshot.each_value { |value| require!(value.is_a?(Integer) && value >= 0, "#{label} #{key} has invalid counter") }
    end
    require!(transport_read.fetch('file_byte_count') >= source_file_bytes + generated_file_bytes &&
             transport_read.fetch('record_count') >= source_mark_records + generated_mark_records &&
             transport_read.fetch('decoded_byte_count') >= source_decoded_bytes + generated_decoded_bytes &&
             transport_read.fetch('result_byte_count') >= source_decoded_bytes + generated_decoded_bytes,
      "#{label}: transport read counters are below source-plus-generated file/mark/decoded lower bounds")
    require!(transport_write.fetch('file_byte_count') >= generated_file_bytes &&
             transport_write.fetch('record_count') >= generated_mark_records &&
             transport_write.fetch('decoded_byte_count') >= generated_decoded_bytes &&
             transport_write.fetch('result_byte_count') >= generated_file_bytes,
      "#{label}: transport write counters are below generated-file/two-frame lower bounds")
  end

  def captured_invocation_file!(evidence_root, filename, maximum, label)
    require!(filename.is_a?(String) && File.basename(filename) == filename,
      "#{label}: unsafe invocation artifact name")
    invdir = File.join(evidence_root, 'invocations')
    path = File.join(invdir, filename)
    bytes = plain_file(path, maximum, label)
    invdir_real = File.realpath(invdir)
    require!(File.realpath(path).start_with?(invdir_real + File::SEPARATOR),
      "#{label}: invocation artifact escaped its directory")
    bytes
  end

  # Bind the process result returned by Probe to every immutable artifact it
  # just captured. W191's validator below checks the full roster and pinned
  # process/guard fields after both DEBUG and RELEASE passes.
  def validate_live_decompressor!(evidence_root, result, input, label)
    record = result.fetch(:record).transform_keys(&:to_s)
    require!(record.keys.sort == INVOCATION_RECORD_KEYS.sort,
      "#{label}: invocation record field roster differs")
    require!(record.fetch('label') == label &&
             record.fetch('process_kind') == 'clickhouse compressor --decompress' &&
             record.fetch('argv') == [Probe::Binary, 'compressor', '--decompress', '--threads=1'],
      "#{label}: actual decompressor identity/argv differs")
    require!(result.fetch(:classification) == 'success' && result.fetch(:status)&.success? &&
             result.fetch(:status)&.termsig.nil? && result.fetch(:stderr).empty? &&
             record.fetch('exit') == 0 && record.fetch('signal').nil? &&
             record.fetch('timed_out') == false && record.fetch('process_classification') == 'success',
      "#{label}: actual decompressor result is not a clean success")
    require!(record.fetch('expected_binary_sha256') == W191::RUNTIME_SHA256 &&
             record.fetch('binary_sha_before') == W191::RUNTIME_SHA256 &&
             record.fetch('binary_sha_after') == W191::RUNTIME_SHA256 &&
             record.fetch('max_threads') == 1 &&
             record.fetch('max_memory_usage_applicable') == false &&
             record.fetch('max_memory_usage_bytes').nil? &&
             record.fetch('timeout_seconds') == Probe::Timeout &&
             record.fetch('termination_grace_seconds') == Probe::Grace &&
             record.fetch('required_outer_run_safe_memory_limit_bytes') == Probe::OuterRunSafeLimit,
      "#{label}: pin or bounded-process settings differ")
    %w[spawn_error stdin_write_error stdout_read_error stderr_read_error].each do |key|
      require!(record.fetch(key).nil? && result.fetch(:record).fetch(key.to_sym).nil?,
        "#{label}: #{key} is not nil")
    end

    expected_names = {
      'argv_file' => "#{label}.argv.json",
      'stdin_file' => "#{label}.stdin.bin",
      'stdout_file' => "#{label}.stdout",
      'stderr_file' => "#{label}.stderr",
    }
    expected_names.each do |field, filename|
      require!(record.fetch(field) == filename, "#{label}: #{field} differs")
    end
    invocation_json = captured_invocation_file!(evidence_root, "#{label}.json", MAX_HELPER_BYTES,
      "#{label} record JSON")
    require!(invocation_json == JSON.pretty_generate(record) + "\n" &&
             JSON.parse(invocation_json) == record,
      "#{label}: saved invocation record differs from the actual returned record")

    argv_bytes = captured_invocation_file!(evidence_root, record.fetch('argv_file'), MAX_HELPER_BYTES,
      "#{label} argv")
    require!(argv_bytes == JSON.pretty_generate(record.fetch('argv')) + "\n" &&
             Digest::SHA256.hexdigest(argv_bytes) == record.fetch('argv_sha256'),
      "#{label}: saved argv bytes/hash differ")
    stdin = captured_invocation_file!(evidence_root, record.fetch('stdin_file'), MAX_COMPRESSED_BYTES,
      "#{label} stdin")
    stdout = captured_invocation_file!(evidence_root, record.fetch('stdout_file'), MAX_RAW_STREAM_BYTES,
      "#{label} stdout")
    stderr = captured_invocation_file!(evidence_root, record.fetch('stderr_file'), MAX_RAW_STREAM_BYTES,
      "#{label} stderr")
    require!(stdin == input && stdin.bytesize == record.fetch('stdin_bytes') &&
             Digest::SHA256.hexdigest(stdin) == record.fetch('stdin_sha256'),
      "#{label}: saved stdin does not match actual compressed input")
    require!(stdout == result.fetch(:stdout) && stdout.bytesize == record.fetch('stdout_bytes') &&
             Digest::SHA256.hexdigest(stdout) == record.fetch('stdout_sha256'),
      "#{label}: saved stdout does not match actual process output")
    require!(stderr == result.fetch(:stderr) && stderr.bytesize == record.fetch('stderr_bytes') &&
             Digest::SHA256.hexdigest(stderr) == record.fetch('stderr_sha256'),
      "#{label}: saved stderr does not match actual process output")
    record
  rescue KeyError => error
    raise ReconcileError, "#{label}: invocation result lacks #{error.key.inspect}"
  end

  def expected_decompressor_labels(output, direction)
    profile_map = output.fetch('profiles').to_h { |profile| [profile.fetch('profile_id'), profile] }
    FRAME_BYTES.flat_map do |frame_bytes|
      PROFILE_IDS.flat_map do |profile_id|
        profile_map.fetch(profile_id).fetch('buckets').flat_map do |bucket|
          bucket.fetch('generated_sets').find { |set| set.fetch('frame_bytes') == frame_bytes }
            .fetch('lanes').map do |lane|
              next if lane.fetch('data_bytes').zero?
              "w194_#{direction}_f#{frame_bytes}_#{profile_id}_b#{bucket.fetch('bucket_id')}_#{lane.fetch('name')}"
            end.compact
        end
      end
    end
  end

  def validate_generated_invocations!(evidence_root, records, debug_output, release_output)
    expected = expected_decompressor_labels(debug_output, 'debug') +
      expected_decompressor_labels(release_output, 'release')
    observed = records.map { |record| record.fetch('label') }
    require!(observed == expected, 'generated decompressor process roster differs from nonempty lane inputs')
    runtime = {'path' => Probe::Binary}
    summary = {
      'invocations' => records,
      'limits' => {
        'local_max_memory_usage_bytes' => Probe::Memory,
        'required_outer_run_safe_memory_limit_bytes' => Probe::OuterRunSafeLimit,
      },
    }
    _by_label, counts = W191.validate_invocations!(evidence_root, summary, runtime)
    {'count' => counts.fetch(:count), 'artifact_count' => counts.fetch(:files), 'labels' => observed}
  rescue W191::ReconcileError => error
    raise ReconcileError, "generated invocation evidence is invalid: #{error.message}"
  end

  def decompress_generated!(frame_root, evidence_root, output, direction)
    decoded = {}
    invocations = 0
    records = []
    profile_map = output.fetch('profiles').to_h { |profile| [profile.fetch('profile_id'), profile] }
    FRAME_BYTES.each do |frame_bytes|
      decoded[frame_bytes] = {}
      PROFILE_IDS.each do |profile_id|
        profile_map.fetch(profile_id).fetch('buckets').each do |bucket|
          bucket_id = bucket.fetch('bucket_id')
          bucket.fetch('generated_sets').find { |set| set.fetch('frame_bytes') == frame_bytes }
            .fetch('lanes').each do |lane|
              compressed = plain_file(
                safe_relative(frame_root, lane.fetch('data_file'), 'generated compressed lane'),
                MAX_COMPRESSED_BYTES, 'generated compressed lane',
              )
              raw = if compressed.empty?
                      ''.b
                    else
                      label = "w194_#{direction}_f#{frame_bytes}_#{profile_id}_b#{bucket_id}_#{lane.fetch('name')}"
                      result = Probe::Probe.new(Probe::Binary, evidence_root).send(
                        :execute_captured, label,
                        [Probe::Binary, 'compressor', '--decompress', '--threads=1'],
                        compressed, 'clickhouse compressor --decompress', memory_applicable: false,
                      )
                      record = validate_live_decompressor!(evidence_root, result, compressed, label)
                      records << record
                      invocations += 1
                      result.fetch(:stdout)
                    end
              require!(raw.bytesize <= MAX_RAW_STREAM_BYTES, 'generated decompressed lane exceeds bound')
              decoded[frame_bytes][[profile_id, bucket_id, lane.fetch('name')]] = raw
            end
        end
      end
    end
    require!(invocations <= 512 && invocations == records.size,
      'generated decompression invocation count exceeds bound or captured record count')
    [decoded, records]
  end

  def generated_details!(manifest, frame_bytes, output_profile, decoded_by_key, output_root)
    profile_id = output_profile.fetch('profile_id')
    source_profile = manifest.fetch('profiles').find { |profile| profile.fetch('profile_id') == profile_id }
    kind = source_profile.fetch('kind')
    bucket_count = source_profile.fetch('bucket_count')
    decoded_by_stream = {}
    frame_by_stream = {}
    bucket_count.times do |bucket_id|
      names = W193.bucket_stream_names(kind == 'array' ? 'a' : 'j', bucket_id)
      LANE_NAMES.each do |lane|
        logical = names.fetch(lane.to_sym)
        raw = decoded_by_key.fetch(frame_bytes).fetch([profile_id, bucket_id, lane])
        decoded_by_stream[logical] = raw
        marks_path = File.join(output_root, "frame_#{frame_bytes}", profile_id, "bucket_#{bucket_id}", "#{lane}.mrk2")
        marks = plain_file(marks_path, MAX_RAW_STREAM_BYTES, "generated #{logical} .mrk2")
        triples = marks.unpack('Q<*').each_slice(3).to_a
        require!(triples.size == 5 && triples.map { |triple| triple[2] } == MARK_ROWS,
          "generated #{logical}: physical mark grid differs")
        data_path = File.join(output_root, "frame_#{frame_bytes}", profile_id, "bucket_#{bucket_id}", "#{lane}.bin")
        compressed = plain_file(data_path, MAX_COMPRESSED_BYTES, "generated #{logical} .bin")
        walked = W191.walk_compressed_frames(compressed, "generated #{logical}")
        require!(walked.fetch(:decoded_bytes) == raw.bytesize,
          "generated #{logical}: actual compressed frame extent differs from decompressor")
        decoded_offsets = triples.map do |triple|
          W191.coordinate_to_decoded([triple[0], triple[1]], walked.fetch(:spans),
            compressed.bytesize, raw.bytesize, "generated #{logical} outer mark")
        end
        require!(decoded_offsets == decoded_offsets.sort && decoded_offsets.first == 0 &&
                 decoded_offsets.last == raw.bytesize,
          "generated #{logical}: outer marks do not form a monotone whole-stream grid")
        frame_by_stream[logical] = {
          frames: walked.fetch(:spans),
          compressed_bytes: compressed.bytesize,
          decoded_bytes: raw.bytesize,
          decoded_mark_offsets: decoded_offsets,
        }
        # The plain mark file is independently parsed; W193 then maps these
        # coordinates through actual generated LZ4 frame headers.
        profile_marks = output_profile.fetch('buckets').fetch(bucket_id)
          .fetch('generated_sets').find { |set| set.fetch('frame_bytes') == frame_bytes }
          .fetch('lanes').find { |lane_record| lane_record.fetch('name') == lane }
          .fetch('mark_triples')
        require!(profile_marks == triples, "generated #{logical}: helper and raw mark arrays differ")
      end
      structure_name = names.fetch(:structure)
      structure_records = W191.read_structure_records(decoded_by_stream.fetch(structure_name),
        "generated #{profile_id} bucket #{bucket_id} structure")
      expected_profile = manifest.fetch('profiles').find { |profile| profile.fetch('profile_id') == profile_id }
      expected_bucket = expected_profile.fetch('buckets').fetch(bucket_id)
      parents = expected_bucket.fetch('parents')
      parent_offsets = frame_by_stream.fetch(structure_name).fetch(:decoded_mark_offsets)
      require!(parents.size == 4 && parent_offsets.size == 5,
        "generated #{profile_id} bucket #{bucket_id}: outer mark/chunk schedule differs")
      parents.each_with_index do |parent, mark_index|
        start_offset = parent_offsets.fetch(mark_index)
        end_offset = parent_offsets.fetch(mark_index + 1)
        selected = structure_records.select do |record|
          record.fetch(:byte_start) >= start_offset && record.fetch(:byte_end) <= end_offset
        end
        expected_chunks = parent.fetch('chunks')
        require!(selected.size == expected_chunks.size,
          "generated #{profile_id} bucket #{bucket_id} mark #{mark_index}: structure chunk count differs")
        unless selected.empty?
          require!(selected.first.fetch(:byte_start) == start_offset && selected.last.fetch(:byte_end) == end_offset,
            "generated #{profile_id} bucket #{bucket_id} mark #{mark_index}: structure records do not span mark interval")
        else
          require!(start_offset == end_offset,
            "generated #{profile_id} bucket #{bucket_id} mark #{mark_index}: empty chunk group has nonempty structure bytes")
        end
        selected.each_with_index do |record, index|
          expected_chunk = expected_chunks.fetch(index)
          expected_prefix = read_hex(expected_chunk.fetch('structure_prefix_hex'),
            "generated #{profile_id} structure expected prefix")
          require!(record.fetch(:rows) == expected_chunk.fetch('row_count') &&
                   record.fetch(:prefix_bytes) == expected_prefix,
            "generated #{profile_id} bucket #{bucket_id} mark #{mark_index}: structure prefix differs from admitted parent")
          expected_offsets = expected_chunk.fetch('transport_offsets')
          %w[data paths_marks paths_substreams_metadata].each do |lane_name|
            logical = names.fetch(lane_name.to_sym)
            frame = frame_by_stream.fetch(logical)
            pair = record.fetch(:transport_pairs).fetch(lane_name)
            resolved = W191.coordinate_to_decoded(pair, frame.fetch(:frames),
              frame.fetch(:compressed_bytes), frame.fetch(:decoded_bytes),
              "generated #{profile_id} bucket #{bucket_id} chunk #{mark_index} #{lane_name} pointer")
            require!(resolved == expected_offsets.fetch(lane_name),
              "generated #{profile_id} bucket #{bucket_id} chunk #{mark_index}: #{lane_name} pointer resolves to #{resolved}, expected #{expected_offsets.fetch(lane_name)}")
          end
        end
      end
    end
    {decoded_by_stream: decoded_by_stream, frame_by_stream: frame_by_stream}
  end

  def replace_capture_structure_records!(copy_manifest, source_manifest, profile_id, bucket_id, structure_bytes)
    copy_profile = copy_manifest.fetch('profiles').find { |item| item.fetch('profile_id') == profile_id }
    chunks = copy_profile.fetch('chunks')
    records = W191.read_structure_records(structure_bytes, "generated #{profile_id} bucket #{bucket_id}")
    require!(records.size == chunks.size, "generated #{profile_id} bucket #{bucket_id}: structure chunk count differs")
    records.each_with_index do |record, chunk_index|
      chunks.fetch(chunk_index).fetch('bucket_records_hex')[bucket_id] = hex(record.fetch(:record_bytes))
    end
  end

  def semantic_projection(profile)
    {
      'profile_id' => profile.fetch('profile_id'),
      'kind' => profile.fetch('kind'),
      'bucket_count' => profile.fetch('bucket_count'),
      'chunks' => profile.fetch('chunks').map do |chunk|
        {
          'chunk_index' => chunk.fetch('chunk_index'),
          'row_count' => chunk.fetch('row_count'),
          'buckets' => chunk.fetch('buckets').map do |bucket|
            {
              'bucket_id' => bucket.fetch('bucket_id'),
              'paths' => bucket.fetch('paths').map do |path|
                {
                  'path' => path.fetch('path'),
                  'row_count' => path.fetch('row_count'),
                  'expected_values_hex' => path.fetch('expected_values_hex'),
                  'events' => path.fetch('events').map do |event|
                    {'name' => event.fetch('name'), 'relative_offset' => event.fetch('relative_offset')}
                  end,
                  'data_hex' => path.fetch('data_hex'),
                  'decoded_values_hex' => path.fetch('physical').fetch('decoded_values_hex'),
                }
              end,
            }
          end,
        }
      end,
    }
  end

  def compare_semantics!(expected_profiles, observed_profiles, frame_bytes)
    observed = observed_profiles.to_h { |profile| [profile.fetch('profile_id'), profile] }
    PROFILE_IDS.each do |profile_id|
      require!(semantic_projection(observed.fetch(profile_id)) == semantic_projection(expected_profiles.fetch(profile_id)),
        "frame_#{frame_bytes} #{profile_id}: independent W193 lane decode differs from stock semantics")
    end
  end

  def validate_generated_semantics!(manifest, summary, copy_manifest, output_root, evidence_root, output, direction, invocation_records)
    original_details = W193.load_capture!(manifest.fetch('capture_root')).fetch(3)
    expected_profiles = W193.derive_path_profiles(summary, copy_manifest, original_details)
      .to_h { |profile| [profile.fetch('profile_id'), profile] }
    decoder_counts = {}
    decoded_by_key, records = decompress_generated!(output_root, evidence_root, output, direction)
    invocation_records.concat(records)
    FRAME_BYTES.each do |frame_bytes|
      profiles = output.fetch('profiles')
      details_by_id = {}
      regenerated_copy = Marshal.load(Marshal.dump(copy_manifest))
      profiles.each do |profile|
        profile_id = profile.fetch('profile_id')
        details = generated_details!(manifest, frame_bytes, profile, decoded_by_key, output_root)
        details_by_id[profile_id] = details
        bucket_count = manifest.fetch('profiles').find { |item| item.fetch('profile_id') == profile_id }.fetch('bucket_count')
        bucket_count.times do |bucket_id|
          structure_name = W193.bucket_stream_names(
            manifest.fetch('profiles').find { |item| item.fetch('profile_id') == profile_id }.fetch('kind') == 'array' ? 'a' : 'j',
            bucket_id,
          ).fetch(:structure)
          replace_capture_structure_records!(
            regenerated_copy, manifest, profile_id, bucket_id, details.fetch(:decoded_by_stream).fetch(structure_name),
          )
        end
      end
      generated_profiles = W193.derive_path_profiles(summary, regenerated_copy, details_by_id)
      compare_semantics!(expected_profiles, generated_profiles, frame_bytes)
      decoder_counts[frame_bytes] = decoded_by_key.fetch(frame_bytes).values.sum(&:bytesize)
    end
    {'frame_bytes' => decoder_counts.keys.sort, 'decoded_stream_bytes_by_frame' => decoder_counts}
  end

  def write_new(path, bytes, label)
    require!(!File.exist?(path) && !File.symlink?(path), "#{label} already exists")
    parent = File.realpath(File.dirname(path))
    io = File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600)
    io.write(bytes)
    io.flush
    io.fsync
    io.close
    require!(File.realpath(path).start_with?(parent + File::SEPARATOR), "#{label} escaped its parent")
  ensure
    io&.close unless io&.closed?
  end

  def self_test!
    raise ReconcileError, 'frame set differs' unless FRAME_BYTES == [17, 37]
    raise ReconcileError, 'W191/W193 profile roster differs' unless PROFILE_IDS.size == 8
    raise ReconcileError, 'lane roster differs' unless LANE_NAMES.size == 6 && LANE_NAMES.uniq == LANE_NAMES
    raise ReconcileError, 'Array schedule control differs' unless W191::PROFILE_EXPECTATIONS
      .fetch('array_advanced_v2').fetch(:rows) == [0, 1, 3, 0]
    puts 'W194 Ruby self-test passed'
    true
  end

  def run(argv)
    return self_test! ? 0 : 1 if argv == ['--self-test']
    options = {}
    parser = OptionParser.new do |flags|
      flags.banner = 'Usage: ruby reconcile_object_shared_physical_w194.rb --capture-root ROOT (--manifest-out PATH | --manifest PATH --debug-output PATH --release-output PATH ...)'
      flags.on('--capture-root PATH') { |value| options[:capture_root] = value }
      flags.on('--manifest-out PATH') { |value| options[:manifest_out] = value }
      flags.on('--manifest PATH') { |value| options[:manifest] = value }
      flags.on('--debug-output PATH') { |value| options[:debug_output] = value }
      flags.on('--release-output PATH') { |value| options[:release_output] = value }
      flags.on('--debug-generated-root PATH') { |value| options[:debug_root] = value }
      flags.on('--release-generated-root PATH') { |value| options[:release_root] = value }
      flags.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
    end
    parser.parse!(argv)
    require!(argv.empty?, 'unexpected positional arguments')
    require!(options.key?(:capture_root), '--capture-root is required')
    derived, encoded = derive_manifest(options.fetch(:capture_root))
    if options[:manifest_out]
      require!(!options[:manifest], 'choose --manifest-out or --manifest')
      write_new(options.fetch(:manifest_out), encoded, 'W194 manifest')
      puts "W194 manifest derived: profiles=#{PROFILE_IDS.size}, buckets=#{derived.fetch('limits').fetch('max_buckets_total')}"
      return 0
    end
    required = %i[manifest debug_output release_output debug_root release_root evidence_root]
    require!(required.all? { |key| options.key?(key) },
      "comparison requires #{required.map { |key| "--#{key.to_s.tr('_', '-')}" }.join(', ')}")
    supplied = JSON.parse(plain_file(options.fetch(:manifest), MAX_MANIFEST_BYTES, 'W194 manifest'))
    require!(supplied == derived, 'supplied manifest differs from fresh W191/W193 derivation')
    debug_root = checked_output_root!(options.fetch(:debug_root), 'DEBUG generated root')
    release_root = checked_output_root!(options.fetch(:release_root), 'RELEASE generated root')
    require!(debug_root != release_root && !Dir.children(debug_root).empty? && !Dir.children(release_root).empty?,
      'generated roots must be distinct and contain helper outputs')
    evidence_root = checked_output_root!(options.fetch(:evidence_root), 'evidence root')
    require!(Dir.children(evidence_root).empty?, 'evidence root must be empty')
    Dir.mkdir(File.join(evidence_root, 'invocations'), 0o700)
    debug = validate_helper_output!(options.fetch(:debug_output), derived, 'DEBUG')
    release = validate_helper_output!(options.fetch(:release_output), derived, 'RELEASE')
    require!(debug == release, 'DEBUG and RELEASE helper output JSON differs')
    capture = W193.load_capture!(derived.fetch('capture_root'))
    generated_invocations = []
    debug_semantics = validate_generated_semantics!(derived, capture.fetch(1), capture.fetch(2),
      debug_root, evidence_root, debug, 'debug', generated_invocations)
    release_semantics = validate_generated_semantics!(derived, capture.fetch(1), capture.fetch(2),
      release_root, evidence_root, release, 'release', generated_invocations)
    invocation_evidence = validate_generated_invocations!(evidence_root, generated_invocations, debug, release)
    validate_budget_snapshots!(debug.fetch('budgets'), derived, debug,
      debug_semantics.fetch('decoded_stream_bytes_by_frame').values.sum, 'DEBUG')
    validate_budget_snapshots!(release.fetch('budgets'), derived, release,
      release_semantics.fetch('decoded_stream_bytes_by_frame').values.sum, 'RELEASE')
    require!(debug_semantics == release_semantics, 'DEBUG and RELEASE semantic reconciliation differs')
    result = {
      'status' => 'paired_physical_semantics_reconciled',
      'source_inventory_sha256' => derived.fetch('source_inventory_sha256'),
      'profile_ids' => PROFILE_IDS,
      'profile_count' => PROFILE_IDS.size,
      'bucket_count' => derived.fetch('limits').fetch('max_buckets_total'),
      'lane_count' => LANE_NAMES.size,
      'frame_bytes' => FRAME_BYTES,
      'debug_reconciliation' => debug_semantics,
      'release_reconciliation' => release_semantics,
      'generated_invocation_evidence' => invocation_evidence,
      'claim_boundary' => 'Paired six-lane codec semantics for the authenticated W191/W193 String corpus only; not full part publication or general persisted admission.',
    }
    puts JSON.pretty_generate(result)
    0
  rescue ReconcileError, JSON::ParserError, OptionParser::ParseError, KeyError,
         Errno::ENOENT, Errno::EEXIST, TypeError, NoMethodError => error
    warn "W194 reconciliation failed: #{error.class}: #{error.message}"
    1
  end
end

exit ReconcileObjectSharedPhysicalW194.run(ARGV) if $PROGRAM_NAME == __FILE__
