#!/usr/bin/env ruby
# Independent reconciliation of the W191 stock capture and DEBUG/RELEASE
# structure-codec helper outputs. This is evidence checking, not format support.

require 'digest'
require 'json'
require 'optparse'

module ReconcileObjectSharedAdvancedW191
  extend self

  SOURCE_REVISION = 'ef037e60fc7f5654c8c80eefb8be82e3c56f9a67'.freeze
  RUNTIME_VERSION = '26.10.1.1201'.freeze
  RUNTIME_BUILD = 'd9bcb5ab007f0f6299f7f973f2642245bab3d028'.freeze
  RUNTIME_SHA256 = 'bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2'.freeze
  MAX_SUMMARY_BYTES = 16 * 1024 * 1024
  MAX_HELPER_BYTES = 16 * 1024 * 1024
  MAX_STREAM_BYTES = 1_048_576
  MAX_COMPRESSED_BYTES = 65_536
  MAX_RECORDS = 65_536
  U64_MAX = (1 << 64) - 1
  METADATA_FILE_NAMES = %w[
    checksums.txt
    columns.txt
    columns_substreams.txt
    count.txt
    default_compression_codec.txt
    metadata_version.txt
    primary.idx
    serialization.json
    statistics.packed
  ].freeze

  PROFILE_ORDER = %w[
    root_advanced_v2
    root_advanced_chunked_v3
    array_advanced_v2
    array_advanced_chunked_v3
    empty_root_advanced_v2
    empty_root_advanced_chunked_v3
    empty_array_advanced_v2
    empty_array_advanced_chunked_v3
  ].freeze

  PROFILE_EXPECTATIONS = {
    'root_advanced_v2' => {kind: 'root', mode: 'advanced', buckets: 2, rows: [2, 2, 2, 2]},
    'root_advanced_chunked_v3' => {kind: 'root', mode: 'advanced_chunked', buckets: 2, rows: [1, 1, 1, 1, 1, 1, 1, 1]},
    'array_advanced_v2' => {kind: 'array', mode: 'advanced', buckets: 2, rows: [0, 1, 3, 0]},
    'array_advanced_chunked_v3' => {kind: 'array', mode: 'advanced_chunked', buckets: 2, rows: [0, 1, 1, 1, 1, 0]},
    'empty_root_advanced_v2' => {kind: 'root', mode: 'advanced', buckets: 1, rows: [2, 2, 2, 2]},
    'empty_root_advanced_chunked_v3' => {kind: 'root', mode: 'advanced_chunked', buckets: 1, rows: [1, 1, 1, 1, 1, 1, 1, 1]},
    'empty_array_advanced_v2' => {kind: 'array', mode: 'advanced', buckets: 1, rows: [0, 0, 0, 0]},
    'empty_array_advanced_chunked_v3' => {kind: 'array', mode: 'advanced_chunked', buckets: 1, rows: [0, 0, 0, 0]},
  }.freeze

  class ReconcileError < StandardError; end

  def require!(condition, message)
    raise ReconcileError, message unless condition
  end

  def digest(bytes)
    Digest::SHA256.hexdigest(bytes)
  end

  def hex(bytes)
    bytes.unpack1('H*')
  end

  def read_plain_file(path, max_bytes, label)
    require!(File.file?(path) && !File.symlink?(path), "#{label} is not a plain file")
    size = File.size(path)
    require!(size <= max_bytes, "#{label} exceeds #{max_bytes} bytes")
    bytes = File.binread(path)
    require!(bytes.bytesize == size, "#{label} changed while being read")
    bytes
  end

  def parse_json_file(path, max_bytes, label)
    bytes = read_plain_file(path, max_bytes, label)
    JSON.parse(bytes)
  rescue JSON::ParserError => error
    raise ReconcileError, "#{label} is invalid JSON: #{error.message}"
  end

  def checked_uint(value, label, max = U64_MAX)
    require!(value.is_a?(Integer) && value >= 0 && value <= max, "#{label} is not a bounded unsigned integer")
    value
  end

  def canonical_var_uint(bytes, offset, label)
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
    encoded = encode_var_uint(value)
    require!(bytes.byteslice(start, offset - start) == encoded, "#{label}: noncanonical VarUInt")
    [value, offset]
  end

  def encode_var_uint(value)
    require!(value.is_a?(Integer) && value >= 0 && value <= U64_MAX, 'cannot encode non-UInt64 VarUInt')
    output = +''.b
    loop do
      byte = value & 0x7f
      value >>= 7
      output << (value.zero? ? byte : (byte | 0x80))
      break if value.zero?
    end
    output.b
  end

  def read_structure_records(bytes, label)
    require!(bytes.bytesize <= MAX_STREAM_BYTES, "#{label}: structure stream exceeds decoded bound")
    records = []
    offset = 0
    while offset < bytes.bytesize
      start_offset = offset
      rows, offset = canonical_var_uint(bytes, offset, "#{label} rows")
      require!(rows <= MAX_STREAM_BYTES, "#{label}: row count exceeds bound")
      path_count, offset = canonical_var_uint(bytes, offset, "#{label} path count")
      require!(path_count <= 65_536, "#{label}: path count exceeds bound")
      paths_bytes = []
      path_count.times do |path_index|
        length, offset = canonical_var_uint(bytes, offset, "#{label} path #{path_index} length")
        require!(length <= bytes.bytesize - offset, "#{label}: path exceeds remaining stream")
        paths_bytes << bytes.byteslice(offset, length).b
        offset += length
      end
      require!(paths_bytes.uniq == paths_bytes, "#{label}: duplicate path in one chunk")
      require!(paths_bytes == paths_bytes.sort, "#{label}: paths are not strictly byte-sorted")
      prefix_end = offset
      require!(bytes.bytesize - offset >= 48, "#{label}: truncated six-UInt64 suffix")
      suffix = bytes.byteslice(offset, 48)
      fields = suffix.unpack('Q<6')
      offset += 48
      record_bytes = bytes.byteslice(start_offset, offset - start_offset).b
      records << {
        rows: rows,
        paths_bytes: paths_bytes,
        paths: paths_bytes.map do |path|
          value = path.dup.force_encoding(Encoding::UTF_8)
          require!(value.valid_encoding?, "#{label}: path bytes cannot be represented by captured JSON")
          value
        end,
        prefix_bytes: bytes.byteslice(start_offset, prefix_end - start_offset).b,
        suffix_bytes: suffix.b,
        fields: fields,
        transport_pairs: {
          'data' => fields[0, 2],
          'paths_marks' => fields[2, 2],
          'paths_substreams_metadata' => fields[4, 2],
        },
        record_bytes: record_bytes,
        byte_start: start_offset,
        byte_end: offset,
      }
      require!(records.size <= MAX_RECORDS, "#{label}: record count exceeds bound")
    end
    records
  end

  def sha_field!(bytes, object, bytes_key, sha_key, label)
    require!(object[bytes_key] == bytes.bytesize, "#{label} byte length differs")
    require!(object[sha_key] == digest(bytes), "#{label} SHA-256 differs")
  end

  def frame_uint32(bytes, offset)
    bytes.byteslice(offset, 4).unpack1('V')
  end

  # Independently walk ClickHouse compressed blocks from the immutable .bin.
  # The decompressed bytes are separately checked against the captured utility
  # output; this function does not trust frame offsets from the summary.
  def walk_compressed_frames(bytes, label)
    require!(bytes.bytesize <= MAX_COMPRESSED_BYTES, "#{label}: compressed stream exceeds bound")
    spans = []
    compressed_offset = 0
    decoded_offset = 0
    while compressed_offset < bytes.bytesize
      require!(bytes.bytesize - compressed_offset >= 25, "#{label}: truncated compressed frame header")
      require!(bytes.getbyte(compressed_offset + 16) == 0x82, "#{label}: frame is not ClickHouse LZ4")
      block_size = frame_uint32(bytes, compressed_offset + 17)
      decoded_size = frame_uint32(bytes, compressed_offset + 21)
      require!(block_size >= 9, "#{label}: invalid compressed block extent")
      require!(decoded_size.positive?, "#{label}: zero decoded frame")
      ending = compressed_offset + 16 + block_size
      require!(ending <= bytes.bytesize, "#{label}: compressed frame exceeds .bin")
      require!(decoded_size <= MAX_STREAM_BYTES - decoded_offset, "#{label}: decoded frames exceed bound")
      spans << {
        'compressed_offset' => compressed_offset,
        'compressed_end_offset' => ending,
        'decoded_offset' => decoded_offset,
        'decoded_size' => decoded_size,
        'decoded_end_offset' => decoded_offset + decoded_size,
      }
      compressed_offset = ending
      decoded_offset += decoded_size
    end
    require!(spans.empty? == bytes.empty?, "#{label}: empty-frame state differs")
    {spans: spans, decoded_bytes: decoded_offset}
  end

  def coordinate_to_decoded(pair, frames, compressed_bytes, decoded_bytes, label)
    require!(pair.is_a?(Array) && pair.size == 2, "#{label}: coordinate is not a pair")
    compressed_offset = checked_uint(pair[0], "#{label} compressed offset")
    in_block_offset = checked_uint(pair[1], "#{label} in-block offset")
    if compressed_offset == compressed_bytes
      require!(in_block_offset.zero?, "#{label}: terminal compressed coordinate has nonzero in-block offset")
      return decoded_bytes
    end
    frame = frames.find { |item| item.fetch('compressed_offset') == compressed_offset }
    require!(frame, "#{label}: compressed offset is not an actual frame boundary")
    require!(in_block_offset <= frame.fetch('decoded_size'), "#{label}: in-block offset exceeds frame")
    frame.fetch('decoded_offset') + in_block_offset
  end

  def compare_frame_manifest!(actual_frames, actual_decoded_bytes, capture, label)
    require!(capture['frames'] == actual_frames, "#{label}: frame manifest differs from actual .bin headers")
    require!(capture['decoded_bytes'] == actual_decoded_bytes, "#{label}: decoded extent differs from actual frame walk")
    require!(capture['empty_no_frame'] == actual_frames.empty?, "#{label}: empty-no-frame flag differs")
  end

  def parse_object_structure(bytes, label)
    require!(bytes.bytesize >= 9, "#{label}: Object structure prefix is truncated")
    version = bytes.byteslice(0, 8).unpack1('Q<')
    path_count, offset = canonical_var_uint(bytes, 8, "#{label} dynamic path count")
    require!(path_count.zero?, "#{label}: unexpected dynamic paths in this fixture")
    shared_version, offset = canonical_var_uint(bytes, offset, "#{label} shared data version")
    bucket_count = 1
    bucket_count, offset = canonical_var_uint(bytes, offset, "#{label} bucket count") unless shared_version.zero?
    require!(offset < bytes.bytesize, "#{label}: statistics flag is truncated")
    statistics_flag = bytes.getbyte(offset)
    require!([0, 1].include?(statistics_flag), "#{label}: invalid statistics flag")
    offset += 1
    require!(statistics_flag == 1 || offset == bytes.bytesize, "#{label}: unexpected bytes after no-statistics flag")
    {
      'version' => version,
      'dynamic_path_count' => path_count,
      'shared_data_version' => shared_version,
      'bucket_count' => bucket_count,
      'statistics_flag' => statistics_flag,
      'statistics_suffix_bytes' => bytes.bytesize - offset,
    }
  end

  def require_exact_keys!(hash, keys, label)
    require!(hash.is_a?(Hash) && hash.keys.sort == keys.sort, "#{label} keys differ")
  end

  def validate_runtime!(summary)
    runtime = summary.fetch('runtime')
    require!(runtime['source_revision'] == SOURCE_REVISION, 'source snapshot revision differs from pinned W191 source')
    require!(runtime['expected_sha256'] == RUNTIME_SHA256, 'runtime SHA pin differs')
    require!(runtime['expected_version'] == RUNTIME_VERSION, 'runtime version pin differs')
    require!(runtime['expected_build'] == RUNTIME_BUILD, 'runtime build pin differs')
    require!(runtime['sha256_before'] == RUNTIME_SHA256 && runtime['sha256_after'] == RUNTIME_SHA256,
      'runtime before/after SHA differs from immutable pin')
    summary.fetch('limits').tap do |limits|
      require!(limits['per_stream_compressed_input_bytes'] == MAX_COMPRESSED_BYTES, 'compressed-input limit differs')
      require!(limits['per_stream_decoded_output_bytes'] == MAX_STREAM_BYTES, 'decoded-output limit differs')
      require!(limits['max_threads'] == 1, 'capture thread limit differs')
    end
    runtime
  end

  def validate_invocations!(root, summary, runtime)
    records = summary.fetch('invocations')
    require!(records.is_a?(Array) && records.size <= 512, 'invocation roster is malformed or exceeds bound')
    labels = {}
    expected_files = []
    by_label = {}
    records.each do |record|
      label = record.fetch('label')
      require!(label.is_a?(String) && label.match?(/\A[a-zA-Z0-9_-]+\z/), 'unsafe invocation label')
      require!(!labels.key?(label), "duplicate invocation label #{label}")
      labels[label] = true
      by_label[label] = record
      require!(record['expected_binary_sha256'] == RUNTIME_SHA256 &&
               record['binary_sha_before'] == RUNTIME_SHA256 && record['binary_sha_after'] == RUNTIME_SHA256,
        "#{label}: executable pin differs")
      require!(record['exit'] == 0 && record['signal'].nil? && record['timed_out'] == false &&
               record['process_classification'] == 'success', "#{label}: invocation did not succeed cleanly")
      %w[spawn_error stdin_write_error stdout_read_error stderr_read_error].each do |key|
        require!(record[key].nil?, "#{label}: #{key} is not nil")
      end
      require!(record['max_threads'] == 1, "#{label}: max_threads differs")
      require!(record['argv'].is_a?(Array) && record['argv'][0] == runtime['path'],
        "#{label}: executable argv differs from pinned path")

      {
        'argv_file' => record.fetch('argv_file'),
        'stdin_file' => record.fetch('stdin_file'),
        'stdout_file' => record.fetch('stdout_file'),
        'stderr_file' => record.fetch('stderr_file'),
      }.each do |field, filename|
        require!(filename.is_a?(String) && File.basename(filename) == filename, "#{label}: unsafe #{field}")
        expected_files << filename
      end
      expected_files << "#{label}.json"

      invdir = File.join(root, 'invocations')
      argv_bytes = read_plain_file(File.join(invdir, record.fetch('argv_file')), MAX_HELPER_BYTES, "#{label} argv capture")
      require!(digest(argv_bytes) == record['argv_sha256'], "#{label}: argv hash differs")
      require!(JSON.parse(argv_bytes) == record['argv'], "#{label}: captured argv differs")

      stdin = read_plain_file(File.join(invdir, record.fetch('stdin_file')), MAX_STREAM_BYTES + 65_536,
        "#{label} stdin capture")
      sha_field!(stdin, record, 'stdin_bytes', 'stdin_sha256', "#{label} stdin")
      stdout = read_plain_file(File.join(invdir, record.fetch('stdout_file')), MAX_STREAM_BYTES + 65_536,
        "#{label} stdout capture")
      sha_field!(stdout, record, 'stdout_bytes', 'stdout_sha256', "#{label} stdout")
      stderr = read_plain_file(File.join(invdir, record.fetch('stderr_file')), MAX_STREAM_BYTES + 65_536,
        "#{label} stderr capture")
      sha_field!(stderr, record, 'stderr_bytes', 'stderr_sha256', "#{label} stderr")
      require!(stderr.empty?, "#{label}: successful capture unexpectedly wrote stderr")

      record_bytes = read_plain_file(File.join(invdir, "#{label}.json"), MAX_HELPER_BYTES, "#{label} invocation record")
      require!(JSON.parse(record_bytes) == record, "#{label}: immutable invocation JSON differs from summary")

      if record['process_kind'] == 'clickhouse local'
        require!(record['max_memory_usage_applicable'] == true, "#{label}: local memory guard is absent")
        require!(record['max_memory_usage_bytes'] == summary.dig('limits', 'local_max_memory_usage_bytes'),
          "#{label}: local max memory differs")
        expected_pin = "__W191_PIN__\t#{RUNTIME_VERSION}\t#{RUNTIME_BUILD}"
        pins = stdout.lines.map(&:chomp).select { |line| line.start_with?("__W191_PIN__\t") }
        require!(pins == [expected_pin], "#{label}: runtime stdout pin differs")
        require!(record['argv'][1] == 'local', "#{label}: expected clickhouse local invocation")
      elsif record['process_kind'] == 'clickhouse compressor --decompress'
        require!(record['max_memory_usage_applicable'] == false && record['max_memory_usage_bytes'].nil?,
          "#{label}: compressor utility memory applicability differs")
        require!(record['argv'][1..] == ['compressor', '--decompress', '--threads=1'],
          "#{label}: decompressor argv differs")
      else
        raise ReconcileError, "#{label}: unknown process kind #{record['process_kind'].inspect}"
      end
      require!(record['required_outer_run_safe_memory_limit_bytes'] ==
               summary.dig('limits', 'required_outer_run_safe_memory_limit_bytes'),
        "#{label}: outer memory guard pin differs")
    end

    invdir = File.join(root, 'invocations')
    require!(File.directory?(invdir) && !File.symlink?(invdir), 'invocations directory is absent or a symlink')
    expected_files = expected_files.uniq.sort
    actual_files = Dir.children(invdir).sort
    require!(actual_files == expected_files, 'invocations directory file roster differs from invocation records')
    [by_label, {count: records.size, files: actual_files.size}]
  rescue KeyError => error
    raise ReconcileError, "invocation record lacks #{error.key.inspect}"
  rescue JSON::ParserError => error
    raise ReconcileError, "invocation argv capture is invalid JSON: #{error.message}"
  end

  def validate_part_and_streams!(root, profile, invocation_by_label)
    profile_id = profile.fetch('id')
    part = profile.fetch('part')
    require!(part['part_type'] == 'Wide' && part['rows'].to_s == '8' && part['marks'].to_s == '5',
      "#{profile_id}: part dimensions/type differ")
    logical = part.fetch('logical_substreams')
    require!(logical.is_a?(Array) && logical.uniq == logical, "#{profile_id}: logical stream roster malformed")
    captures = profile.fetch('stream_captures')
    require!(captures.is_a?(Hash) && captures.keys.sort == logical.sort, "#{profile_id}: stream capture roster differs")
    inventory = part.fetch('stream_file_inventory')
    names = part.fetch('physical_file_names')
    require!(names.is_a?(Array) && names.uniq == names, "#{profile_id}: physical file list malformed")
    stream_names = names.select { |filename| filename.end_with?('.bin', '.mrk2') }
    require!(stream_names.sort == inventory.keys.sort,
      "#{profile_id}: stream file inventory differs from the .bin/.mrk2 subset of the physical roster")
    require!(part['hashed_stream_files'] == stream_names.sort,
      "#{profile_id}: hashed stream roster differs from physical .bin/.mrk2 roster")
    require!(part['plain_mrk2_only'] == true, "#{profile_id}: mark format is not plain .mrk2")
    require!((names - stream_names).sort == METADATA_FILE_NAMES,
      "#{profile_id}: nonstream metadata roster differs from fixed Wide-part fixture")

    part_path_text = part.fetch('part_path')
    part_path = File.realpath(part_path_text)
    root_real = File.realpath(root)
    require!(part_path.start_with?(root_real + File::SEPARATOR), "#{profile_id}: part path escapes capture root")
    require!(File.directory?(part_path) && !File.symlink?(part_path), "#{profile_id}: part path is not a real directory")
    actual_part_names = Dir.children(part_path).sort
    require!(actual_part_names == names.sort, "#{profile_id}: actual immutable part roster differs")

    file_bytes = {}
    inventory.each do |filename, info|
      require!(File.basename(filename) == filename, "#{profile_id}: unsafe part filename")
      path = File.join(part_path, filename)
      bytes = read_plain_file(path, MAX_COMPRESSED_BYTES + 16 * 1024 * 1024, "#{profile_id} part file #{filename}")
      require!(info['size'] == bytes.bytesize, "#{profile_id} #{filename}: physical size differs")
      require!(info['sha256'] == digest(bytes), "#{profile_id} #{filename}: physical SHA-256 differs")
      file_bytes[filename] = bytes
    end
    checksums_bytes = read_plain_file(File.join(part_path, 'checksums.txt'), MAX_STREAM_BYTES,
      "#{profile_id} checksums.txt")
    require!(checksums_bytes.bytesize == part['checksums_bytes'] &&
             digest(checksums_bytes) == part['checksums_sha256'],
      "#{profile_id}: checksums.txt size/hash differs from captured metadata")
    serialization_bytes = read_plain_file(File.join(part_path, 'serialization.json'), MAX_STREAM_BYTES,
      "#{profile_id} serialization.json")
    require!(digest(serialization_bytes) == part['serialization_json_sha256'],
      "#{profile_id}: serialization.json SHA-256 differs from captured metadata")
    require!(read_plain_file(File.join(part_path, 'columns.txt'), MAX_STREAM_BYTES,
      "#{profile_id} columns.txt") == part['columns_text'].b,
      "#{profile_id}: columns.txt bytes differ from captured metadata")
    require!(read_plain_file(File.join(part_path, 'columns_substreams.txt'), MAX_STREAM_BYTES,
      "#{profile_id} columns_substreams.txt") == part['columns_substreams_text'].b,
      "#{profile_id}: columns_substreams.txt bytes differ from captured metadata")
    require!(read_plain_file(File.join(part_path, 'count.txt'), 1024,
      "#{profile_id} count.txt").strip == part['count_text'],
      "#{profile_id}: count.txt differs from captured metadata")
    require!(read_plain_file(File.join(part_path, 'default_compression_codec.txt'), 1024,
      "#{profile_id} default codec").strip == part['default_compression_codec'],
      "#{profile_id}: default codec differs from captured metadata")
    require!(read_plain_file(File.join(part_path, 'metadata_version.txt'), 1024,
      "#{profile_id} metadata version").strip == part['metadata_version'],
      "#{profile_id}: metadata version differs from captured metadata")

    mark_map = part.fetch('mark_triples')
    require!(mark_map.is_a?(Hash) && mark_map.keys.sort == logical.sort, "#{profile_id}: .mrk2 logical roster differs")
    raw_dir = File.join(root, 'raw_streams', profile_id)
    require!(File.directory?(raw_dir) && !File.symlink?(raw_dir), "#{profile_id}: raw stream directory absent or symlinked")
    expected_decoded_names = []
    decoded_by_stream = {}
    frame_by_stream = {}
    logical.each do |logical_name|
      capture = captures.fetch(logical_name)
      bin_name = capture.fetch('hashed_file')
      require!(bin_name.is_a?(String) && File.basename(bin_name) == bin_name && bin_name.end_with?('.bin'),
        "#{profile_id} #{logical_name}: invalid hashed stream filename")
      mrk_name = bin_name.sub(/\.bin\z/, '.mrk2')
      require!(inventory.key?(bin_name) && inventory.key?(mrk_name), "#{profile_id} #{logical_name}: .bin/.mrk2 absent from part inventory")
      compressed = file_bytes.fetch(bin_name)
      require!(compressed.bytesize == capture['compressed_bytes'] &&
               digest(compressed) == capture['compressed_sha256'], "#{profile_id} #{logical_name}: compressed capture differs")
      decoded_path_name = "#{File.basename(bin_name, '.bin')}.decoded.bin"
      expected_decoded_names << decoded_path_name
      decoded = read_plain_file(File.join(raw_dir, decoded_path_name), MAX_STREAM_BYTES,
        "#{profile_id} #{logical_name} decoded stream")
      require!(decoded.bytesize == capture['decoded_bytes'] &&
               digest(decoded) == capture['decoded_sha256'], "#{profile_id} #{logical_name}: decoded capture differs")
      frames = walk_compressed_frames(compressed, "#{profile_id} #{logical_name}")
      require!(frames[:decoded_bytes] == decoded.bytesize, "#{profile_id} #{logical_name}: actual frame output extent differs")
      compare_frame_manifest!(frames[:spans], frames[:decoded_bytes], capture, "#{profile_id} #{logical_name}")
      decoded_by_stream[logical_name] = decoded
      frame_by_stream[logical_name] = {
        frames: frames[:spans], compressed_bytes: compressed.bytesize, decoded_bytes: decoded.bytesize,
      }

      invocation_label = capture['decompressor_invocation']
      if compressed.empty?
        require!(invocation_label.nil?, "#{profile_id} #{logical_name}: empty stream has a decompressor invocation")
        require!(decoded.empty?, "#{profile_id} #{logical_name}: no-frame stream decoded nonempty")
      else
        invocation = invocation_by_label[invocation_label] ||
          raise(ReconcileError, "#{profile_id} #{logical_name}: decompressor invocation is missing")
        invdir = File.join(root, 'invocations')
        input = read_plain_file(File.join(invdir, invocation.fetch('stdin_file')), MAX_COMPRESSED_BYTES,
          "#{profile_id} #{logical_name} decompressor stdin")
        output = read_plain_file(File.join(invdir, invocation.fetch('stdout_file')), MAX_STREAM_BYTES,
          "#{profile_id} #{logical_name} decompressor stdout")
        require!(input == compressed, "#{profile_id} #{logical_name}: decompressor stdin is not the immutable .bin")
        require!(output == decoded, "#{profile_id} #{logical_name}: decompressor stdout differs from decoded capture")
        require!(invocation['label'] == invocation_label, "#{profile_id} #{logical_name}: decompressor label differs")
      end

      mrk_bytes = file_bytes.fetch(mrk_name)
      require!((mrk_bytes.bytesize % 24).zero?, "#{profile_id} #{logical_name}: .mrk2 length is not 24-byte aligned")
      triples_flat = mrk_bytes.unpack('Q<*')
      triples = triples_flat.each_slice(3).to_a
      manifest_triples = mark_map.fetch(logical_name)
      require!(triples == manifest_triples, "#{profile_id} #{logical_name}: physical .mrk2 triples differ from manifest")
      require!(triples.size == part['marks'].to_i, "#{profile_id} #{logical_name}: mark count differs from part")
      require!(triples.map { |triple| triple[2] } == [2, 2, 2, 2, 0],
        "#{profile_id} #{logical_name}: physical parent mark row grid differs")
      normalized = capture.fetch('mrk2')
      require!(normalized.size == triples.size, "#{profile_id} #{logical_name}: normalized mark count differs")
      previous_decoded = -1
      triples.each_with_index do |(compressed_offset, in_block_offset, rows), index|
        derived_decoded = coordinate_to_decoded([compressed_offset, in_block_offset],
          frames[:spans], compressed.bytesize, decoded.bytesize, "#{profile_id} #{logical_name} .mrk2[#{index}]")
        item = normalized.fetch(index)
        require!(item == {
          'compressed_offset' => compressed_offset,
          'in_block_offset' => in_block_offset,
          'decoded_offset' => derived_decoded,
          'physical_rows' => rows,
        }, "#{profile_id} #{logical_name}: normalized mark #{index} differs from actual bytes")
        require!(derived_decoded >= previous_decoded, "#{profile_id} #{logical_name}: normalized marks move backward")
        previous_decoded = derived_decoded
      end
    end
    require!(Dir.children(raw_dir).sort == expected_decoded_names.sort,
      "#{profile_id}: decoded raw-stream roster differs from captures")

    {physical_roster_entries: names.size, stream_inventory_entries: inventory.size,
     checksums_sha_verified: true, serialization_json_sha_verified: true,
     logical_streams: logical.size, marks: mark_map.values.sum(&:size),
     decoded_by_stream: decoded_by_stream, frame_by_stream: frame_by_stream}
  rescue KeyError => error
    raise ReconcileError, "#{profile_id}: missing part/stream field #{error.key.inspect}"
  end

  def compare_json_value!(actual, expected, label)
    require!(actual == expected, "#{label} differs")
  end

  def validate_structure_manifest!(profile_id, bucket_id, logical_name, records, profile, decoded)
    bucket = profile.dig('physical_layout', 'chunk_layout', 'buckets', bucket_id)
    require!(bucket.is_a?(Hash), "#{profile_id} bucket #{bucket_id}: structure manifest is absent")
    require!(bucket['structure_streams'] == [logical_name], "#{profile_id} bucket #{bucket_id}: combined structure roster differs")
    chunks = bucket.fetch('chunks')
    require!(chunks.size == records.size, "#{profile_id} bucket #{bucket_id}: summary record count differs from raw bytes")
    require!(records.map { |record| record[:record_bytes] }.join.b == decoded,
      "#{profile_id} bucket #{bucket_id}: parsed raw record ranges do not cover actual decoded stream")
    records.each_with_index do |record, index|
      manifest = chunks.fetch(index)
      label = "#{profile_id} bucket #{bucket_id} record #{index}"
      require!(manifest['rows'] == record[:rows], "#{label}: row count differs")
      require!(manifest['paths'] == record[:paths], "#{label}: ordered paths differ")
      require!(manifest['prefix_bytes_hex'] == hex(record[:prefix_bytes]), "#{label}: prefix byte range differs")
      require!(manifest['suffix_bytes_hex'] == hex(record[:suffix_bytes]), "#{label}: six-field suffix differs")
      require!(manifest['record_bytes_hex'] == hex(record[:record_bytes]), "#{label}: complete raw record bytes differ")
      require!(manifest['transport_pairs'] == record[:transport_pairs], "#{label}: decoded transport pairs differ")
    end
  rescue KeyError => error
    raise ReconcileError, "#{profile_id} bucket #{bucket_id}: missing structure manifest field #{error.key.inspect}"
  end

  def validate_structure_profiles!(summary, profile_details)
    expected_records = []
    profile_counts = {}
    total_records = 0
    total_with_paths = 0
    total_pathless = 0
    total_frames = 0
    total_structure_bytes = 0

    summary.fetch('profiles').each do |profile|
      profile_id = profile.fetch('id')
      expectation = PROFILE_EXPECTATIONS.fetch(profile_id)
      kind = profile.fetch('kind')
      mode = profile.fetch('requested_shared_version')
      require!(kind == expectation.fetch(:kind) && mode == expectation.fetch(:mode),
        "#{profile_id}: profile kind/mode differs from fixed fixture")
      require!(profile.fetch('expected_actual_bucket_count') == expectation.fetch(:buckets),
        "#{profile_id}: expected bucket count differs from fixed fixture")

      physical = profile.fetch('physical_layout')
      object_name = kind == 'array' ? 'a.object_structure' : 'j.object_structure'
      object_bytes = profile_details.fetch(profile_id).fetch(:decoded_by_stream).fetch(object_name) do
        raise ReconcileError, "#{profile_id}: Object structure stream is missing"
      end
      require!(physical['object_structure_bytes_hex'] == hex(object_bytes),
        "#{profile_id}: decoded Object structure bytes differ from summary")
      parsed_object = parse_object_structure(object_bytes, "#{profile_id} Object structure")
      require!(parsed_object == physical.fetch('object_structure'), "#{profile_id}: Object structure fields differ")
      expected_shared_version = mode == 'advanced' ? 2 : 3
      require!(parsed_object['version'] == 4 && parsed_object['shared_data_version'] == expected_shared_version,
        "#{profile_id}: raw Object structure version/mode differs")
      require!(parsed_object['bucket_count'] == expectation.fetch(:buckets) &&
               physical['actual_shared_bucket_count'] == expectation.fetch(:buckets),
        "#{profile_id}: raw Object structure bucket count differs")

      part = profile.fetch('part')
      column = kind == 'array' ? 'a' : 'j'
      structure_streams = part.fetch('logical_substreams').grep(/\A#{Regexp.escape(column)}\.object_shared_data\.\d+\.structure\z/)
      forbidden_split = part.fetch('logical_substreams').any? do |name|
        name.start_with?("#{column}.object_shared_data.") &&
          (name.end_with?('.structure_prefix') || name.end_with?('.structure_suffix'))
      end
      require!(!forbidden_split, "#{profile_id}: expected combined structure bytes, found split structure streams")
      buckets_from_streams = structure_streams.map { |name| name.match(/\.object_shared_data\.(\d+)\.structure\z/)[1] }
      expected_bucket_ids = (0...expectation.fetch(:buckets)).map(&:to_s)
      require!(buckets_from_streams.sort_by(&:to_i) == expected_bucket_ids,
        "#{profile_id}: actual structure stream bucket roster differs")
      layout = physical.fetch('chunk_layout')
      require!(layout.fetch('bucket_ids') == expected_bucket_ids.map(&:to_i),
        "#{profile_id}: summary bucket IDs differ from actual structure streams")
      require!(layout.fetch('buckets').keys.sort_by(&:to_i) == expected_bucket_ids,
        "#{profile_id}: summary bucket map differs from actual structure streams")

      per_bucket = {}
      structure_streams.sort_by { |name| name.match(/\.object_shared_data\.(\d+)\.structure\z/)[1].to_i }.each do |logical_name|
        bucket_id = logical_name.match(/\.object_shared_data\.(\d+)\.structure\z/)[1]
        decoded = profile_details.fetch(profile_id).fetch(:decoded_by_stream).fetch(logical_name)
        records = read_structure_records(decoded, "#{profile_id} #{logical_name}")
        validate_structure_manifest!(profile_id, bucket_id, logical_name, records, profile, decoded)
        per_bucket[bucket_id] = records
        records.each_with_index do |record, chunk_index|
          expected_records << {
            'profile_id' => profile_id,
            'bucket_id' => bucket_id,
            'chunk_index' => chunk_index,
            'rows' => record[:rows],
            'paths' => record[:paths],
            'transport_pairs' => record[:transport_pairs],
            'record_bytes_hex' => hex(record[:record_bytes]),
            'reencoded_hex' => hex(record[:record_bytes]),
            'byte_start' => record[:byte_start],
            'byte_end' => record[:byte_end],
          }
          total_records += 1
          total_with_paths += 1 unless record[:paths].empty?
          total_pathless += 1 if record[:paths].empty?
          total_structure_bytes += record[:record_bytes].bytesize
        end
      end

      schedules = per_bucket.transform_values { |records| records.map { |record| record[:rows] } }
      require!(schedules.values.uniq.size <= 1, "#{profile_id}: buckets have different chunk row schedules")
      observed_rows = schedules.values.first || []
      require!(observed_rows == expectation.fetch(:rows),
        "#{profile_id}: raw chunk schedule #{observed_rows.inspect} differs from fixture falsifier")
      if profile_id.start_with?('empty_')
        require!(per_bucket.values.flatten.all? { |record| record[:paths].empty? },
          "#{profile_id}: empty control contains a shared path")
      end
      summary_schedules = layout.fetch('chunks_per_bucket')
      require!(summary_schedules == schedules, "#{profile_id}: summary per-bucket row counts differ from raw bytes")

      # Every suffix pair is a transport coordinate in its own physical stream.
      per_bucket.each do |bucket_id, records|
        {
          'data' => "#{column}.object_shared_data.#{bucket_id}.data",
          'paths_marks' => "#{column}.object_shared_data.#{bucket_id}.paths_marks",
          'paths_substreams_metadata' => "#{column}.object_shared_data.#{bucket_id}.paths_substreams_metadata",
        }.each do |pair_name, target_stream|
          target = profile_details.fetch(profile_id).fetch(:frame_by_stream)[target_stream] ||
            raise(ReconcileError, "#{profile_id} bucket #{bucket_id}: target stream #{target_stream} is absent")
          previous = -1
          records.each_with_index do |record, index|
            decoded_offset = coordinate_to_decoded(record[:transport_pairs].fetch(pair_name),
              target.fetch(:frames), target.fetch(:compressed_bytes), target.fetch(:decoded_bytes),
              "#{profile_id} bucket #{bucket_id} record #{index} #{pair_name}")
            require!(decoded_offset >= previous,
              "#{profile_id} bucket #{bucket_id} #{pair_name} coordinates move backward")
            previous = decoded_offset
          end
        end
      end

      profile_counts[profile_id] = {
        'kind' => kind,
        'mode' => mode,
        'bucket_count' => per_bucket.size,
        'records' => per_bucket.transform_values(&:size),
        'records_with_shared_paths' => per_bucket.transform_values { |records| records.count { |record| !record[:paths].empty? } },
        'pathless_records' => per_bucket.transform_values { |records| records.count { |record| record[:paths].empty? } },
        'rows_per_bucket' => schedules,
      }
      total_frames += profile_details.fetch(profile_id).fetch(:frame_by_stream).values.sum { |item| item.fetch(:frames).size }
    end
    [expected_records, {
      'profiles' => profile_counts,
      'totals' => {
        'raw_structure_records' => total_records,
        'records_with_shared_paths' => total_with_paths,
        'pathless_structure_records' => total_pathless,
        'actual_structure_record_bytes' => total_structure_bytes,
        'compressed_frames' => total_frames,
      },
    }]
  rescue KeyError => error
    raise ReconcileError, "capture/profile lacks #{error.key.inspect}"
  end

  def validate_helper_payload!(payload, expected_records, profile_order, label)
    require_exact_keys!(payload, %w[profile_ids profiles_without_records record_count records], label)
    expected_profile_ids = profile_order
    require!(payload.fetch('profile_ids') == expected_profile_ids, "#{label}: profile ID roster/order differs")
    records = payload.fetch('records')
    require!(records.is_a?(Array) && records.size == expected_records.size, "#{label}: record count differs")
    empty_profiles = profile_order.select do |profile_id|
      expected_records.none? { |record| record.fetch('profile_id') == profile_id }
    end
    require!(payload.fetch('profiles_without_records') == empty_profiles,
      "#{label}: profiles_without_records differs from actual raw records")
    require!(payload.fetch('record_count') == expected_records.size, "#{label}: declared record count differs")
    expected_records.each_with_index do |expected, index|
      actual = records.fetch(index)
      record_label = "#{label} record #{index}"
      require_exact_keys!(actual,
        %w[profile_id bucket_id chunk_index row_count paths transport_pairs record_bytes_hex reencoded_hex],
        record_label)
      require!(actual['profile_id'] == expected['profile_id'] &&
               actual['bucket_id'] == expected['bucket_id'] &&
               actual['chunk_index'] == expected['chunk_index'],
        "#{record_label}: profile/bucket/chunk ordering differs")
      require!(actual['row_count'] == expected['rows'].to_s, "#{record_label}: row count differs")
      require!(actual['paths'] == expected['paths'], "#{record_label}: ordered path list differs")
      pairs = expected.fetch('transport_pairs').transform_values { |pair| pair.map(&:to_s) }
      require!(actual['transport_pairs'] == pairs, "#{record_label}: six transport values differ")
      require!(actual['record_bytes_hex'] == expected['record_bytes_hex'], "#{record_label}: raw record bytes differ")
      require!(actual['reencoded_hex'] == expected['reencoded_hex'], "#{record_label}: codec re-encoding differs from raw record")
    end
    true
  end

  def validate_helpers!(debug_path, release_path, expected_records)
    debug = parse_json_file(debug_path, MAX_HELPER_BYTES, 'DEBUG helper output')
    release = parse_json_file(release_path, MAX_HELPER_BYTES, 'RELEASE helper output')
    require!(debug == release, 'DEBUG and RELEASE helper outputs differ')
    validate_helper_payload!(debug, expected_records, PROFILE_ORDER, 'DEBUG helper')
    validate_helper_payload!(release, expected_records, PROFILE_ORDER, 'RELEASE helper')
    {debug_records: debug.fetch('record_count'), release_records: release.fetch('record_count'),
     profiles_without_records: debug.fetch('profiles_without_records')}
  end

  def reconcile(capture_root, debug_path, release_path)
    root = File.realpath(capture_root)
    require!(File.directory?(root) && !File.symlink?(capture_root), 'capture root is not a real directory')
    summary_path = File.join(root, 'summary.json')
    summary = parse_json_file(summary_path, MAX_SUMMARY_BYTES, 'W191 summary')
    require!(summary['status'] == 'all_stock_profiles_observed', 'capture is not a complete all-profile observation')
    require!(summary['evidence_root'] == root, 'summary evidence root differs from supplied root')
    runtime = validate_runtime!(summary)

    profiles = summary.fetch('profiles')
    require!(profiles.is_a?(Array) && profiles.map { |profile| profile['id'] } == PROFILE_ORDER,
      'profile roster/order differs from fixed W191 fixture')
    profiles.each do |profile|
      require!(profile['status'] == 'stock_profile_observed', "#{profile['id']}: stock profile did not complete")
    end

    invocation_by_label, invocation_counts = validate_invocations!(root, summary, runtime)
    linked_labels = []
    profile_details = {}
    profiles.each do |profile|
      profile_id = profile.fetch('id')
      native_invocation = profile.fetch('native_invocation')
      local = invocation_by_label["stock_#{profile_id}"] ||
        raise(ReconcileError, "#{profile_id}: stock invocation is absent")
      require!(native_invocation == local, "#{profile_id}: nested stock invocation differs from raw roster")
      linked_labels << local.fetch('label')
      details = validate_part_and_streams!(root, profile, invocation_by_label)
      profile.fetch('stream_captures').each_value do |capture|
        linked_labels << capture['decompressor_invocation'] if capture['decompressor_invocation']
      end
      profile_details[profile_id] = details
    end
    require!(linked_labels.sort == invocation_by_label.keys.sort,
      'invocation roster contains an orphan or an unlinked subprocess')

    expected_records, counts = validate_structure_profiles!(summary, profile_details)
    helper_counts = validate_helpers!(debug_path, release_path, expected_records)
    part_rosters = profile_details.transform_values do |details|
      details.slice(:physical_roster_entries, :stream_inventory_entries,
                    :checksums_sha_verified, :serialization_json_sha_verified)
    end
    {
      'status' => 'reconciled_observation_only',
      'source' => {'revision' => SOURCE_REVISION},
      'runtime' => {'version' => RUNTIME_VERSION, 'build' => RUNTIME_BUILD, 'sha256' => RUNTIME_SHA256},
      'capture_root' => root,
      'invocations' => invocation_counts,
      'helper_outputs' => helper_counts.merge('debug_release_equal' => true),
      'part_roster_and_hash_scope' => {
        'profiles' => part_rosters,
        'physical_roster_entries' => part_rosters.values.sum { |item| item.fetch(:physical_roster_entries) },
        'stream_files_size_and_sha_verified' => part_rosters.values.sum { |item| item.fetch(:stream_inventory_entries) },
        'checksums_txt_and_serialization_json_sha_verified' => part_rosters.size * 2,
        'boundary' => 'Full physical filename rosters are matched to actual directories. Individual size/SHA checks cover only the .bin/.mrk2 stream inventory; checksums.txt and serialization.json are checked against captured hashes. Other nonstream metadata is checked by captured roster/literals, not claimed individually hashed here.',
      },
      'counts' => counts,
      'claim_boundary' => 'Raw W191 capture, structure codec bytes, selected transport coordinates and helper agreement were reconciled; this does not admit persisted ADVANCED v2/v3 read/write support.',
    }
  rescue KeyError => error
    raise ReconcileError, "capture lacks #{error.key.inspect}"
  end

  def self_test!
    high_var_uint = encode_var_uint(128)
    require!(high_var_uint.bytes == [0x80, 0x01], 'self-test failed to encode a multi-byte VarUInt canonically')
    require!(canonical_var_uint(high_var_uint, 0, 'self-test high VarUInt') == [128, high_var_uint.bytesize],
      'self-test failed to parse a multi-byte VarUInt canonically')
    max_var_uint = encode_var_uint(U64_MAX)
    require!(canonical_var_uint(max_var_uint, 0, 'self-test UInt64 maximum') == [U64_MAX, max_var_uint.bytesize],
      'self-test failed to preserve canonical UInt64 maximum')
    noncanonical_rejected = false
    begin
      canonical_var_uint([0x80, 0x00].pack('C*').b, 0, 'self-test noncanonical VarUInt')
    rescue ReconcileError
      noncanonical_rejected = true
    end
    require!(noncanonical_rejected, 'self-test accepted a noncanonical VarUInt')

    rows = 2
    path = 'aa'.b
    prefix = encode_var_uint(rows) + encode_var_uint(1) + encode_var_uint(path.bytesize) + path
    suffix = [0, 1, 2, 3, U64_MAX, 5].pack('Q<6')
    raw = (prefix + suffix).b
    records = read_structure_records(raw, 'self-test')
    require!(records.size == 1 && records[0][:byte_start].zero? && records[0][:byte_end] == raw.bytesize,
      'self-test parser lost the exact raw record range')
    record = {
      'profile_id' => 'fixture', 'bucket_id' => '0', 'chunk_index' => 0,
      'row_count' => rows.to_s, 'paths' => ['aa'],
      'transport_pairs' => {
        'data' => ['0', '1'],
        'paths_marks' => ['2', '3'],
        'paths_substreams_metadata' => [U64_MAX.to_s, '5'],
      },
      'record_bytes_hex' => hex(raw), 'reencoded_hex' => hex(raw),
    }
    expected = [{
      'profile_id' => 'fixture', 'bucket_id' => '0', 'chunk_index' => 0,
      'rows' => rows, 'paths' => ['aa'],
      'transport_pairs' => {
        'data' => [0, 1], 'paths_marks' => [2, 3],
        'paths_substreams_metadata' => [U64_MAX, 5],
      },
      'record_bytes_hex' => hex(raw), 'reencoded_hex' => hex(raw),
    }]
    payload = {
      'profile_ids' => ['fixture'], 'profiles_without_records' => [],
      'record_count' => 1, 'records' => [record],
    }
    validate_helper_payload!(payload, expected, ['fixture'], 'self-test clean helper')
    mutated = Marshal.load(Marshal.dump(payload))
    mutated['records'][0]['record_bytes_hex'] = mutated['records'][0]['record_bytes_hex'].sub(/\A../, 'ff')
    rejected = false
    begin
      validate_helper_payload!(mutated, expected, ['fixture'], 'self-test mutated helper')
    rescue ReconcileError
      rejected = true
    end
    require!(rejected, 'self-test failed to reject a mutated helper byte field')
    # A second mutation attacks a middle mark/value in the independently parsed
    # raw record and must be caught by the same field reconciliation.
    changed_suffix = (prefix + [0, 1, 99, 3, U64_MAX, 5].pack('Q<6')).b
    changed = read_structure_records(changed_suffix, 'self-test changed raw')
    raw_mutation_rejected = changed[0][:transport_pairs] != expected[0][:transport_pairs]
    require!(raw_mutation_rejected, 'self-test failed to detect a raw transport-field mutation')
    {
      'clean_control' => 'accepted',
      'mutated_helper_bytes' => 'rejected by shared helper validator',
      'mutated_raw_transport_field' => 'distinguished by independent raw parser',
    }
  end

  def main(argv)
    options = {self_test: false}
    OptionParser.new do |parser|
      parser.banner = 'Usage: ruby scripts/reconcile_object_shared_advanced_w191.rb CAPTURE_ROOT HELPER_DEBUG.json HELPER_RELEASE.json [--self-test]'
      parser.on('--self-test', 'also run the bounded synthetic mutation control (works standalone)') do
        options[:self_test] = true
      end
    end.parse!(argv)

    if argv.empty? && options[:self_test]
      puts JSON.pretty_generate({'self_test' => self_test!})
      return 0
    end
    require!(argv.size == 3, 'expected CAPTURE_ROOT HELPER_DEBUG.json HELPER_RELEASE.json')
    output = reconcile(*argv)
    output['self_test'] = self_test! if options[:self_test]
    puts JSON.pretty_generate(output)
    0
  rescue ReconcileError, Errno::ENOENT, Errno::EACCES, Errno::ELOOP, JSON::ParserError => error
    warn "W191 reconcile failed: #{error.message}"
    1
  end
end

exit ReconcileObjectSharedAdvancedW191.main(ARGV)
