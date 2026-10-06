require "json"
require "../src/crystal_click"

W192_PROFILE_IDS = [
  "root_advanced_v2",
  "root_advanced_chunked_v3",
  "array_advanced_v2",
  "array_advanced_chunked_v3",
  "empty_root_advanced_v2",
  "empty_root_advanced_chunked_v3",
  "empty_array_advanced_v2",
  "empty_array_advanced_chunked_v3",
]
W192_MAX_MANIFEST_BYTES = 16 * 1024 * 1024
W192_MAX_HEX_LANE_BYTES = 1_048_576

private def w192_require(condition : Bool, message : String) : Nil
  raise ArgumentError.new(message) unless condition
end

private def w192_decode_hex(value : JSON::Any, label : String) : Bytes
  text = value.as_s
  w192_require(text.bytesize.even?, "#{label} hex length is odd")
  byte_count = text.bytesize // 2
  w192_require(byte_count <= W192_MAX_HEX_LANE_BYTES, "#{label} exceeds the bounded lane size")
  output = Bytes.new(byte_count)
  byte_count.times do |index|
    high = w192_hex_nibble(text.byte_at(index * 2), label)
    low = w192_hex_nibble(text.byte_at(index * 2 + 1), label)
    output[index] = ((high << 4) | low).to_u8
  end
  output
end

private def w192_hex_nibble(byte : UInt8, label : String) : UInt8
  case byte
  when 48_u8..57_u8  then byte - 48_u8
  when 65_u8..70_u8  then byte - 55_u8
  when 97_u8..102_u8 then byte - 87_u8
  else
    raise ArgumentError.new("#{label} contains a non-hex byte")
  end
end

private def w192_hex(bytes : Bytes) : String
  digits = "0123456789abcdef".to_slice
  String.build(bytes.size * 2) do |io|
    bytes.each do |byte|
      io.write_byte(digits[(byte >> 4).to_i])
      io.write_byte(digits[(byte & 0x0f_u8).to_i])
    end
  end
end

private def w192_read_u64_le(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times do |byte_index|
    value |= bytes[offset + byte_index].to_u64 << (byte_index * 8)
  end
  value
end

private def w192_read_index(bytes : Bytes, offset : Int, width : Int32) : UInt64
  value = 0_u64
  width.times do |byte_index|
    value |= bytes[offset + byte_index].to_u64 << (byte_index * 8)
  end
  value
end

private def w192_validate_manifest!(manifest : JSON::Any) : Array(JSON::Any)
  object = manifest.as_h
  w192_require(object["format"]?.try(&.as_s) == "object_shared_copy_w192_manifest_v1", "manifest format differs")
  ids = object["profile_ids"]?.try(&.as_a.map(&.as_s)) || raise ArgumentError.new("manifest profile_ids are absent")
  w192_require(ids == W192_PROFILE_IDS, "manifest profile roster/order differs")
  profiles = object["profiles"]?.try(&.as_a) || raise ArgumentError.new("manifest profiles are absent")
  w192_require(profiles.size == W192_PROFILE_IDS.size, "manifest profile count differs")
  profiles.each_with_index do |profile, index|
    profile_object = profile.as_h
    w192_require(profile_object["profile_id"]?.try(&.as_s) == W192_PROFILE_IDS[index], "manifest profile order differs")
    bucket_count = profile_object["bucket_count"]?.try(&.as_i) || raise ArgumentError.new("profile bucket_count is absent")
    w192_require(1 <= bucket_count <= 256, "profile bucket count is outside 1..256")
    chunks = profile_object["chunks"]?.try(&.as_a) || raise ArgumentError.new("profile chunks are absent")
    w192_require(!chunks.empty?, "profile has no chunk records")
  end
  profiles
end

private def w192_expected_rows(chunk : JSON::Any) : Array(Array(Tuple(String, String)))
  rows = chunk["expected_rows"]?.try(&.as_a) || raise ArgumentError.new("chunk expected_rows are absent")
  rows.map do |row|
    row.as_a.map do |entry|
      fields = entry.as_h
      path_hex = fields["path_hex"]?.try(&.as_s) || raise ArgumentError.new("expected path_hex is absent")
      value_hex = fields["value_hex"]?.try(&.as_s) || raise ArgumentError.new("expected value_hex is absent")
      {path_hex, value_hex}
    end
  end
end

private def w192_run : Int32
  unless ARGV.size == 1
    raise ArgumentError.new("usage: crystal scripts/validate_object_shared_copy_w192.cr MANIFEST.json")
  end
  path = ARGV[0]
  raise ArgumentError.new("manifest is not a plain file") unless File.file?(path) && !File.symlink?(path)
  size = File.size(path)
  w192_require(size <= W192_MAX_MANIFEST_BYTES, "manifest exceeds #{W192_MAX_MANIFEST_BYTES} bytes")
  bytes = Bytes.new(size.to_i)
  File.open(path) { |file| file.read_fully(bytes) }
  w192_require(File.size(path) == size, "manifest changed while being read")
  manifest = JSON.parse(String.new(bytes))
  profiles = w192_validate_manifest!(manifest)

  limits = CrystalClick::BinaryCodecLimits.default
  read_budget = CrystalClick::BinaryCodecBudget.new(limits)
  write_budget = CrystalClick::BinaryCodecBudget.new(limits, true)
  chunks_output = [] of JSON::Any
  total_chunks = 0

  profiles.each do |profile|
    profile_object = profile.as_h
    profile_id = profile_object["profile_id"].as_s
    bucket_count = profile_object["bucket_count"].as_i
    profile_chunks = profile_object["chunks"].as_a
    profile_chunks.each_with_index do |chunk, expected_chunk_index|
      chunk_object = chunk.as_h
      chunk_index = chunk_object["chunk_index"]?.try(&.as_i) || raise ArgumentError.new("chunk index is absent")
      w192_require(chunk_index == expected_chunk_index, "#{profile_id}: chunk order differs")
      row_count = chunk_object["row_count"]?.try(&.as_i) || raise ArgumentError.new("chunk row_count is absent")
      w192_require(0 <= row_count <= Int32::MAX, "#{profile_id} chunk #{chunk_index}: row_count is outside Int32")
      record_hexes = chunk_object["bucket_records_hex"]?.try(&.as_a) || raise ArgumentError.new("bucket_records_hex are absent")
      w192_require(record_hexes.size == bucket_count, "#{profile_id} chunk #{chunk_index}: bucket record count differs")

      structures = Array(CrystalClick::ObjectSharedChunkStructure).new(bucket_count)
      record_hexes.each_with_index do |record_hex, bucket_index|
        record_bytes = w192_decode_hex(record_hex, "#{profile_id} chunk #{chunk_index} bucket #{bucket_index} record")
        context = CrystalClick::BinaryCodecContext.new(limits, record_bytes, false, read_budget)
        structures << CrystalClick::ObjectSharedChunkStructureCodec.read_from(context)
        context.ensure_consumed
      end

      sizes = w192_decode_hex((chunk_object["sizes_hex"]? || raise ArgumentError.new("sizes_hex is absent")), "#{profile_id} sizes")
      indexes = w192_decode_hex((chunk_object["indexes_hex"]? || raise ArgumentError.new("indexes_hex is absent")), "#{profile_id} indexes")
      values = w192_decode_hex((chunk_object["values_hex"]? || raise ArgumentError.new("values_hex is absent")), "#{profile_id} values")
      w192_require(sizes.size == row_count * 8, "#{profile_id} chunk #{chunk_index}: sizes extent differs from row count")
      total_entries = 0_u64
      row_count.times do |row_index|
        count = w192_read_u64_le(sizes, row_index * 8)
        w192_require(count <= Int32::MAX.to_u64 && count <= UInt64::MAX - total_entries,
          "#{profile_id} chunk #{chunk_index}: sizes count exceeds the in-memory domain")
        total_entries += count
      end
      w192_require(total_entries <= Int32::MAX.to_u64, "#{profile_id} chunk #{chunk_index}: total entries exceed Int32")
      read_budget.ensure_future_elements(row_count.to_u64)
      read_budget.ensure_future_nodes(row_count.to_u64)
      counts = Array(UInt64).new(row_count)
      row_count.times do |row_index|
        counts << w192_read_u64_le(sizes, row_index * 8)
      end
      path_count = structures.sum(&.path_count)
      width = path_count <= 256 ? 1 : path_count <= 65_536 ? 2 : 4
      w192_require(indexes.size == total_entries * width, "#{profile_id} chunk #{chunk_index}: indexes extent differs")

      rows = CrystalClick::ObjectSharedCopyCodec.decode_with_budget(sizes, indexes, values, structures, read_budget)
      encoded = CrystalClick::ObjectSharedCopyCodec.encode_with_budget(rows, structures, write_budget)
      reencoded_sizes = encoded.sizes
      reencoded_indexes = encoded.indexes
      reencoded_values = encoded.values
      w192_require(reencoded_sizes == sizes && reencoded_indexes == indexes && reencoded_values == values,
        "#{profile_id} chunk #{chunk_index}: Copy lanes did not exactly re-encode")
      w192_require(rows.size == row_count, "#{profile_id} chunk #{chunk_index}: decoded row count differs")

      dictionary = structures.flat_map(&.paths)
      semantic_rows = Array(JSON::Any).new(row_count)
      expected = w192_expected_rows(chunk)
      w192_require(expected.size == row_count, "#{profile_id} chunk #{chunk_index}: authored row count differs")
      flattened_entries = 0_u64
      rows.each_with_index do |row, row_index|
        w192_require(row.entry_count.to_u64 == counts[row_index], "#{profile_id} chunk #{chunk_index}: row count differs")
        actual_items = Array(Tuple(String, String)).new(row.entry_count)
        output_items = Array(JSON::Any).new(row.entry_count)
        previous_path : Bytes? = nil
        row.entry_count.times do |entry_index|
          entry = row.entry_at(entry_index)
          path_bytes = entry.path
          if previous = previous_path
            w192_require(CrystalClick::ObjectSharedChunkStructure.compare_paths(String.new(previous), String.new(path_bytes)) < 0,
              "#{profile_id} chunk #{chunk_index}: reconstructed row paths are not byte sorted")
          end
          value = entry.value
          w192_require(value.type.tag == CrystalClick::BinaryDataType::TAG_STRING,
            "#{profile_id} chunk #{chunk_index}: stock actual value is not String")
          value_hex = w192_hex(value.as_string.to_slice)
          path_hex = w192_hex(path_bytes)
          actual_items << {path_hex, value_hex}
          output_items << JSON::Any.new({
            "path_hex"  => JSON::Any.new(path_hex),
            "value_hex" => JSON::Any.new(value_hex),
          })
          previous_path = path_bytes
          flattened_entries += 1_u64
        end
        w192_require(actual_items == expected[row_index], "#{profile_id} chunk #{chunk_index} row #{row_index}: decoded values differ from authored literals")
        semantic_rows << JSON::Any.new(output_items)
      end
      w192_require(flattened_entries == total_entries, "#{profile_id} chunk #{chunk_index}: flattened entry total differs")

      numeric_indexes = Array(JSON::Any).new(total_entries.to_i)
      index_offset = 0
      row_index = 0
      while row_index < row_count
        counts[row_index].to_i.times do
          index = w192_read_index(indexes, index_offset, width)
          w192_require(index < dictionary.size.to_u64, "#{profile_id} chunk #{chunk_index}: index is outside dictionary")
          numeric_indexes << JSON::Any.new(index.to_i64)
          index_offset += width
        end
        row_index += 1
      end

      chunks_output << JSON::Any.new({
        "profile_id"            => JSON::Any.new(profile_id),
        "chunk_index"           => JSON::Any.new(chunk_index),
        "row_count"             => JSON::Any.new(row_count),
        "dictionary_path_count" => JSON::Any.new(dictionary.size),
        "dictionary_width"      => JSON::Any.new(width),
        "size_counts"           => JSON::Any.new(counts.map { |count| JSON::Any.new(count.to_i64) }),
        "indexes"               => JSON::Any.new(numeric_indexes),
        "rows"                  => JSON::Any.new(semantic_rows),
        "sizes_hex"             => JSON::Any.new(w192_hex(reencoded_sizes)),
        "indexes_hex"           => JSON::Any.new(w192_hex(reencoded_indexes)),
        "values_hex"            => JSON::Any.new(w192_hex(reencoded_values)),
      })
      total_chunks += 1
    end
  end

  w192_require(total_chunks == 42, "manifest has #{total_chunks} chunks; expected 42")
  read_budget_output = JSON::Any.new({
    "node_count"      => JSON::Any.new(read_budget.node_count),
    "element_count"   => JSON::Any.new(read_budget.element_count),
    "wire_byte_count" => JSON::Any.new(read_budget.wire_byte_count),
  })
  write_budget_output = JSON::Any.new({
    "node_count"      => JSON::Any.new(write_budget.node_count),
    "element_count"   => JSON::Any.new(write_budget.element_count),
    "wire_byte_count" => JSON::Any.new(write_budget.wire_byte_count),
  })
  output = JSON::Any.new({
    "profile_ids"  => JSON::Any.new(W192_PROFILE_IDS.map { |id| JSON::Any.new(id) }),
    "chunk_count"  => JSON::Any.new(total_chunks),
    "chunks"       => JSON::Any.new(chunks_output),
    "budget_scope" => JSON::Any.new("one read and one write budget shared across all 42 chunks"),
    "read_budget"  => read_budget_output,
    "write_budget" => write_budget_output,
  })
  puts output.to_json
  0
end

status = begin
  w192_run
rescue ex : Exception
  STDERR.puts "W192 Copy validation failed: #{ex.message}"
  1
end
exit status
