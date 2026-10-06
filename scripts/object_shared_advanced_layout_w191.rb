# frozen_string_literal: true
# Bounded parsers and byte-level self-tests for W191 Object shared layouts.

module ObjectSharedAdvancedLayoutW191
  MarkRows = [2, 2, 2, 2, 0].freeze
  ArraySizes = [0, 0, 0, 1, 2, 1, 0, 0].freeze
  module_function

  def fail!(message)
    raise ArgumentError, message
  end

  def read_varuint(bytes, offset, label)
    value = 0
    shift = 0
    start = offset
    loop do
      fail!("#{label}: truncated VarUInt") if offset >= bytes.bytesize || shift >= 64
      byte = bytes.getbyte(offset)
      fail!("#{label}: VarUInt overflows UInt64") if shift == 63 && (byte & 0x7e) != 0
      offset += 1
      value |= (byte & 0x7f) << shift
      break if (byte & 0x80).zero?
      shift += 7
    end
    canonical = []
    rest = value
    loop do
      byte = rest & 0x7f
      rest >>= 7
      canonical << (rest.zero? ? byte : byte | 0x80)
      break if rest.zero?
    end
    fail!("#{label}: noncanonical VarUInt") unless bytes.byteslice(start, offset - start).bytes == canonical
    [value, offset]
  end

  def read_binary_string(bytes, offset, label, validate_utf8: true)
    length, offset = read_varuint(bytes, offset, label)
    fail!("#{label}: string exceeds remaining bytes") if length > bytes.bytesize - offset
    value = bytes.byteslice(offset, length)
    if validate_utf8
      value = value.dup.force_encoding(Encoding::UTF_8)
      fail!("#{label}: invalid UTF-8 path") unless value.valid_encoding?
    end
    [value, offset + length]
  end

  def parse_chunk_prefixes(bytes, label)
    records = []
    offset = 0
    while offset < bytes.bytesize
      start_offset = offset
      rows, offset = read_varuint(bytes, offset, label)
      fail!("#{label}: unbounded chunk row count") if rows > 1_048_576
      path_count, offset = read_varuint(bytes, offset, label)
      fail!("#{label}: unbounded path count") if path_count > 65_536
      paths = []
      path_count.times do
        path, offset = read_binary_string(bytes, offset, label)
        paths << path
      end
      fail!("#{label}: duplicate path within chunk") unless paths.uniq == paths
      fail!("#{label}: paths are not strictly sorted within chunk") unless paths == paths.sort
      prefix = bytes.byteslice(start_offset, offset - start_offset)
      records << {rows: rows, paths: paths, prefix_bytes_hex: prefix.unpack('H*').first,
                  record_bytes_hex: prefix.unpack('H*').first}
      fail!("#{label}: unbounded chunk count") if records.size > 65_536
    end
    records
  end

  def parse_combined_structure(bytes, label)
    records = []
    offset = 0
    while offset < bytes.bytesize
      start_offset = offset
      rows, offset = read_varuint(bytes, offset, label)
      fail!("#{label}: unbounded chunk row count") if rows > 1_048_576
      path_count, offset = read_varuint(bytes, offset, label)
      fail!("#{label}: unbounded path count") if path_count > 65_536
      paths = []
      path_count.times do
        path, offset = read_binary_string(bytes, offset, label)
        paths << path
      end
      fail!("#{label}: duplicate path within chunk") unless paths.uniq == paths
      fail!("#{label}: paths are not strictly sorted within chunk") unless paths == paths.sort
      prefix_end = offset
      fail!("#{label}: truncated three-pair suffix") if bytes.bytesize - offset < 48
      suffix = bytes.byteslice(offset, 48)
      fields = suffix.unpack('Q<6')
      offset += 48
      prefix = bytes.byteslice(start_offset, prefix_end - start_offset)
      complete_record = bytes.byteslice(start_offset, offset - start_offset)
      records << {rows: rows, paths: paths, prefix_bytes_hex: prefix.unpack('H*').first,
                  suffix_bytes_hex: suffix.unpack('H*').first,
                  record_bytes_hex: complete_record.unpack('H*').first,
                  transport_pairs: transport_pairs(fields)}
      fail!("#{label}: unbounded chunk count") if records.size > 65_536
    end
    records
  end

  def parse_suffix_stream(bytes, record_count, label)
    fail!("#{label}: suffix extent is not 48 bytes per record") unless bytes.bytesize == record_count * 48
    bytes.unpack('Q<*').each_slice(6).with_index.map do |fields, index|
      suffix = bytes.byteslice(index * 48, 48)
      {suffix_bytes_hex: suffix.unpack('H*').first,
       transport_pairs: transport_pairs(fields)}
    end
  end

  def transport_pairs(fields)
    {
      data: fields[0, 2], paths_marks: fields[2, 2],
      paths_substreams_metadata: fields[4, 2],
    }
  end

  def parse_dynamic_string_envelopes(bytes, label)
    values = []
    offset = 0
    while offset < bytes.bytesize
      start_offset = offset
      dynamic_bytes, offset = read_binary_string(bytes, offset, "#{label} outer String", validate_utf8: false)
      inner_offset = 0
      tag = dynamic_bytes.getbyte(inner_offset)
      fail!("#{label}: expected Dynamic String type tag 0x15, got #{tag.inspect}") unless tag == 0x15
      inner_offset += 1
      value, inner_offset = read_binary_string(dynamic_bytes, inner_offset, "#{label} inner Dynamic String", validate_utf8: false)
      fail!("#{label}: trailing bytes in inner Dynamic envelope") unless inner_offset == dynamic_bytes.bytesize
      values << {type_tag: tag, value_bytes: value, dynamic_bytes_hex: dynamic_bytes.unpack('H*').first,
                 byte_start: start_offset, byte_end: offset,
                 raw_bytes_hex: bytes.byteslice(start_offset, offset - start_offset).unpack('H*').first}
      fail!("#{label}: unbounded Dynamic value count") if values.size > 1_048_576
    end
    values
  end

  def decode_sizes(bytes, label)
    fail!("#{label}: UInt64 size extent is not aligned") unless (bytes.bytesize % 8).zero?
    bytes.unpack('Q<*')
  end

  def width_for_dictionary(path_count)
    return 1 if path_count <= 256
    return 2 if path_count <= 65_536
    return 4 if path_count <= 4_294_967_296
    8
  end

  def decode_indexes(bytes, width, label)
    fail!("#{label}: index bytes are not aligned to UInt#{width * 8}") unless (bytes.bytesize % width).zero?
    case width
    when 1 then bytes.unpack('C*')
    when 2 then bytes.unpack('v*')
    when 4 then bytes.unpack('V*')
    when 8 then bytes.unpack('Q<*')
    else fail!("#{label}: unsupported index width #{width}")
    end
  end

  def decode_index_chunk(bytes, byte_offset, entry_count, dictionary_size, label)
    fail!("#{label}: negative index byte offset/count") if byte_offset.negative? || entry_count.negative?
    fail!("#{label}: index byte offset exceeds stream") if byte_offset > bytes.bytesize
    width = width_for_dictionary(dictionary_size)
    available = bytes.bytesize - byte_offset
    fail!("#{label}: index chunk exceeds remaining bytes") if entry_count > available / width
    length = entry_count * width
    chunk_bytes = bytes.byteslice(byte_offset, length).to_s.b
    indexes = decode_indexes(chunk_bytes, width, label)
    fail!("#{label}: copy index exceeds its chunk dictionary") unless indexes.all? { |index| index < dictionary_size }
    {width: width, indexes: indexes, bytes: chunk_bytes, next_byte_offset: byte_offset + length}
  end

  def resolve_copy_indexes(indexes, values, dictionary, label)
    fail!("#{label}: copy index/value counts differ") unless indexes.size == values.size
    pairs = indexes.zip(values).map do |index, value|
      {path: dictionary.fetch(index), value_bytes: value.fetch(:value_bytes)}
    end
    pairs
  end

  def resolve_copy_pairs(index_bytes, values, width, dictionary, label)
    indexes = decode_indexes(index_bytes, width, label)
    fail!("#{label}: copy index exceeds its chunk dictionary") unless indexes.all? { |index| index < dictionary.size }
    [indexes, resolve_copy_indexes(indexes, values, dictionary, label)]
  end

  def chunk_rows_by_parent_mark(profile, array_sizes)
    parent_cursor = 0
    # .mrk2 has one extra terminal entry with rows=0; structure records are
    # per real granule, so schedule exactly those parent mark groups.
    schedule = MarkRows[0...-1].map do |physical_rows|
      if profile.fetch(:kind) == :array
        counts = array_sizes[parent_cursor, physical_rows] || []
        parent_cursor += physical_rows
        counts.sum
      else
        physical_rows
      end
    end
    if profile.fetch(:kind) == :array
      fail!('Array size schedule does not cover the real parent mark grid') unless parent_cursor == array_sizes.size
    end
    schedule
  end

  def expected_chunk_row_schedule(profile, array_sizes)
    by_mark = chunk_rows_by_parent_mark(profile, array_sizes)
    if profile.fetch(:mode) == 'advanced_chunked'
      by_mark.flat_map { |rows| rows.zero? ? [0] : Array.new(rows, 1) }
    else
      by_mark
    end
  end

  def validate_chunk_rows!(records, expected_rows, label)
    actual = records.map { |record| record.fetch(:rows) }
    fail!("#{label}: chunk row layout #{actual.inspect} != #{expected_rows.inspect}") unless actual == expected_rows
    true
  end

  def decode_coordinate(pair, frames, compressed_size, decoded_size, label)
    compressed_offset, in_block_offset = pair
    if compressed_offset == compressed_size && in_block_offset.zero?
      return decoded_size
    end
    frame = frames.find { |item| item.fetch(:compressed_offset) == compressed_offset }
    fail!("#{label}: mark compressed offset is not a frame boundary: #{pair.inspect}") unless frame
    fail!("#{label}: mark exceeds decoded frame") if in_block_offset > frame.fetch(:decoded_size)
    frame.fetch(:decoded_offset) + in_block_offset
  end

  def self_test!
    encode_varuint = lambda do |value|
      bytes = []
      loop do
        byte = value & 0x7f
        value >>= 7
        bytes << (value.zero? ? byte : byte | 0x80)
        break if value.zero?
      end
      bytes.pack('C*')
    end
    encode_string = lambda do |value|
      encode_varuint.call(value.bytesize) + value.b
    end
    record = lambda do |rows, paths, seed|
      bytes = encode_varuint.call(rows) + encode_varuint.call(paths.size) + paths.map { |path| encode_string.call(path) }.join
      bytes + [seed, 0, seed, 1, seed, 2].pack('Q<6')
    end
    combined = record.call(1, %w[aa alpha], 0) + record.call(1, %w[beta], 4)
    parsed = parse_combined_structure(combined, 'self-test positive')
    validate_chunk_rows!(parsed, [1, 1], 'self-test positive')
    fail!('self-test lost embedded transport pairs') unless parsed[1].fetch(:transport_pairs).fetch(:paths_marks) == [4, 1]
    fail!('self-test lost raw prefix/record bytes') unless parsed[0].fetch(:prefix_bytes_hex) == record.call(1, %w[aa alpha], 0).byteslice(0, record.call(1, %w[aa alpha], 0).bytesize - 48).unpack('H*').first &&
      parsed[0].fetch(:record_bytes_hex) == record.call(1, %w[aa alpha], 0).unpack('H*').first
    row_sizes = [0, 1, 3, 0].pack('Q<*')
    fail!('self-test confused per-row sizes with cumulative offsets') unless decode_sizes(row_sizes, 'self-test row sizes') == [0, 1, 3, 0]

    malformed_rows = record.call(2, %w[aa alpha], 0) + record.call(1, %w[beta], 4)
    rejected_rows = false
    begin
      validate_chunk_rows!(parse_combined_structure(malformed_rows, 'self-test bad rows'), [1, 1], 'self-test bad rows')
    rescue ArgumentError
      rejected_rows = true
    end
    fail!('self-test did not reject a seeded row-layout mismatch') unless rejected_rows

    rejected_index = false
    begin
      value = {type_tag: 0x15, value_bytes: 'v'.b, raw_bytes_hex: '150176'}
      resolve_copy_pairs([2].pack('C'), [value], 1, %w[aa alpha], 'self-test bad dictionary index')
    rescue ArgumentError
      rejected_index = true
    end
    fail!('self-test did not reject a seeded dictionary index outside the dictionary') unless rejected_index

    captured_root_prefix = ['0b1509722d616c7068612d31'].pack('H*')
    observed_value = parse_dynamic_string_envelopes(captured_root_prefix, 'self-test observed stock prefix').fetch(0)
      fail!('self-test observed outer String/Dynamic bytes differ') unless
        observed_value.fetch(:raw_bytes_hex) == '0b1509722d616c7068612d31' &&
        observed_value.fetch(:dynamic_bytes_hex) == '1509722d616c7068612d31' &&
        observed_value.fetch(:value_bytes) == 'r-alpha-1'.b &&
        observed_value.fetch(:byte_start) == 0 && observed_value.fetch(:byte_end) == captured_root_prefix.bytesize
      captured_array_prefix = ['0c150a612d616c7068612d3431'].pack('H*')
      observed_array_value = parse_dynamic_string_envelopes(captured_array_prefix, 'self-test observed Array prefix').fetch(0)
      fail!('self-test observed Array outer String/Dynamic bytes differ') unless
        observed_array_value.fetch(:raw_bytes_hex) == '0c150a612d616c7068612d3431' &&
        observed_array_value.fetch(:dynamic_bytes_hex) == '150a612d616c7068612d3431' &&
        observed_array_value.fetch(:value_bytes) == 'a-alpha-41'.b &&
        observed_array_value.fetch(:byte_end) == captured_array_prefix.bytesize

    empty_values = parse_dynamic_string_envelopes(''.b, 'self-test empty Dynamic String stream')
    fail!('self-test empty String stream was not empty') unless empty_values.empty?
    opaque = parse_dynamic_string_envelopes([3, 0x15, 1, 0xff].pack('C*'), 'self-test opaque String byte').fetch(0)
    fail!('self-test rejected or changed opaque non-UTF8 String bytes') unless opaque.fetch(:value_bytes) == [0xff].pack('C*')

    rejected_inner = false
    begin
      parse_dynamic_string_envelopes([2, 0x15, 1].pack('C*'), 'self-test truncated inner String')
    rescue ArgumentError
      rejected_inner = true
    end
    fail!('self-test did not reject truncated inner Dynamic String bytes') unless rejected_inner

    rejected_trailing_inner = false
    begin
      parse_dynamic_string_envelopes([4, 0x15, 1, 0x76, 0x00].pack('C*'), 'self-test trailing inner bytes')
    rescue ArgumentError
      rejected_trailing_inner = true
    end
    fail!('self-test did not reject trailing inner Dynamic bytes') unless rejected_trailing_inner

    rejected_outer = false
    begin
      parse_dynamic_string_envelopes(['0b1509722d616c7068612d3108150672'].pack('H*'), 'self-test truncated outer String')
    rescue ArgumentError
      rejected_outer = true
    end
    fail!('self-test did not reject truncated outer String envelope') unless rejected_outer

    string_value = parse_dynamic_string_envelopes([3, 0x15, 1, 0x76].pack('C*'), 'self-test positive Dynamic String').fetch(0)
    fail!('self-test Dynamic String raw envelope differs') unless string_value.fetch(:dynamic_bytes_hex) == '150176'
    _indexes, resolved = resolve_copy_pairs([1].pack('C'), [string_value], 1, %w[aa alpha], 'self-test positive copy')
    fail!('self-test positive shared key/value pair differs') unless resolved == [{path: 'alpha', value_bytes: 'v'.b}]

    adjacent_width_bytes = [255, 0, 1].pack('C*')
    first_width_chunk = decode_index_chunk(adjacent_width_bytes, 0, 1, 256, 'self-test UInt8 indexes')
    second_width_chunk = decode_index_chunk(adjacent_width_bytes, first_width_chunk.fetch(:next_byte_offset),
                                            1, 257, 'self-test UInt16 indexes')
    dictionary_256 = Array.new(256) { |index| "p#{index}" }
    dictionary_257 = Array.new(257) { |index| "p#{index}" }
    fail!('self-test UInt8/UInt16 boundary indexes differ') unless
      first_width_chunk.fetch(:width) == 1 && first_width_chunk.fetch(:indexes) == [255] &&
      second_width_chunk.fetch(:width) == 2 && second_width_chunk.fetch(:indexes) == [256] &&
      resolve_copy_indexes(first_width_chunk.fetch(:indexes), [{value_bytes: 'a'.b}], dictionary_256,
                           'self-test UInt8 boundary pair') == [{path: 'p255', value_bytes: 'a'.b}] &&
      resolve_copy_indexes(second_width_chunk.fetch(:indexes), [{value_bytes: 'b'.b}], dictionary_257,
                           'self-test UInt16 boundary pair') == [{path: 'p256', value_bytes: 'b'.b}] &&
      second_width_chunk.fetch(:next_byte_offset) == adjacent_width_bytes.bytesize
    fail!('self-test changed-width byte cursor did not consume the full stream') unless
      first_width_chunk.fetch(:next_byte_offset) == 1 && second_width_chunk.fetch(:next_byte_offset) == 3

    array_profile = {kind: :array, mode: 'advanced'}
    chunked_array_profile = {kind: :array, mode: 'advanced_chunked'}
    sizes = ArraySizes
    fail!('self-test lost zero and positive Array child mark schedule') unless
      chunk_rows_by_parent_mark(array_profile, sizes) == [0, 1, 3, 0] &&
      expected_chunk_row_schedule(array_profile, sizes) == [0, 1, 3, 0] &&
      expected_chunk_row_schedule(chunked_array_profile, sizes) == [0, 1, 1, 1, 1, 0]

    rejected_string_tag = false
    begin
      parse_dynamic_string_envelopes([0x01, 0x01, 0x76].pack('C*'), 'self-test wrong Dynamic tag')
    rescue ArgumentError
      rejected_string_tag = true
    end
    fail!('self-test did not reject a non-String Dynamic envelope') unless rejected_string_tag
    true
  end
end
