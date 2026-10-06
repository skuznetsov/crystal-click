require "json"
require "set"
require "../src/crystal_click"

W193_PROFILE_IDS = [
  "root_advanced_v2",
  "root_advanced_chunked_v3",
  "array_advanced_v2",
  "array_advanced_chunked_v3",
  "empty_root_advanced_v2",
  "empty_root_advanced_chunked_v3",
  "empty_array_advanced_v2",
  "empty_array_advanced_chunked_v3",
]
W193_SOURCE_REVISION              = "ef037e60fc7f5654c8c80eefb8be82e3c56f9a67"
W193_RUNTIME_VERSION              = "26.10.1.1201"
W193_RUNTIME_BUILD                = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
W193_RUNTIME_SHA256               = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
W193_STREAM_INVENTORY_SHA256      = "8f45fc0a7542fb464e360648b19967408f5f55ddd31beba52a757dc70dcc0b2a"
W193_MAX_MANIFEST_BYTES           = 16 * 1024 * 1024
W193_MAX_DATA_BYTES               = 1_048_576
W193_MAX_PATH_RECORDS             =    65_536
W193_EXPECTED_PATH_RECORDS        =        34
W193_EXPECTED_PHYSICAL_DATA_BYTES =     1_347
W193_MAX_ROWS                     = 1_048_576
W193_EVENT_NAMES                  = [
  ".dynamic_structure",
  ".variant_discr_prefix",
  ".variant_discr",
  ".SharedVariant.size",
  ".SharedVariant",
]
W193_EXPECTED_PROFILES = {
  "root_advanced_v2"                => {"root", 2, [2, 2, 2, 2]},
  "root_advanced_chunked_v3"        => {"root", 2, [1, 1, 1, 1, 1, 1, 1, 1]},
  "array_advanced_v2"               => {"array", 2, [0, 1, 3, 0]},
  "array_advanced_chunked_v3"       => {"array", 2, [0, 1, 1, 1, 1, 0]},
  "empty_root_advanced_v2"          => {"root", 1, [2, 2, 2, 2]},
  "empty_root_advanced_chunked_v3"  => {"root", 1, [1, 1, 1, 1, 1, 1, 1, 1]},
  "empty_array_advanced_v2"         => {"array", 1, [0, 0, 0, 0]},
  "empty_array_advanced_chunked_v3" => {"array", 1, [0, 0, 0, 0]},
}
W193_EXPECTED_PATH_COUNTS = {
  "root_advanced_v2"                => 12,
  "root_advanced_chunked_v3"        => 13,
  "array_advanced_v2"               => 4,
  "array_advanced_chunked_v3"       => 5,
  "empty_root_advanced_v2"          => 0,
  "empty_root_advanced_chunked_v3"  => 0,
  "empty_array_advanced_v2"         => 0,
  "empty_array_advanced_chunked_v3" => 0,
}

private def w193_require(condition : Bool, message : String) : Nil
  raise ArgumentError.new(message) unless condition
end

private def w193_object(value : JSON::Any, label : String) : Hash(String, JSON::Any)
  value.as_h
rescue TypeCastError
  raise ArgumentError.new("#{label} is not an object")
end

private def w193_array(value : JSON::Any, label : String) : Array(JSON::Any)
  value.as_a
rescue TypeCastError
  raise ArgumentError.new("#{label} is not an array")
end

private def w193_field(object : Hash(String, JSON::Any), key : String, label : String) : JSON::Any
  object[key]? || raise ArgumentError.new("#{label} lacks #{key}")
end

private def w193_string(object : Hash(String, JSON::Any), key : String, label : String) : String
  w193_field(object, key, label).as_s
rescue TypeCastError
  raise ArgumentError.new("#{label}.#{key} is not a string")
end

private def w193_int(object : Hash(String, JSON::Any), key : String, label : String, maximum : Int64 = Int64::MAX) : Int64
  value = w193_field(object, key, label).as_i64
  w193_require(value >= 0 && value <= maximum, "#{label}.#{key} is outside its supported range")
  value
rescue TypeCastError
  raise ArgumentError.new("#{label}.#{key} is not an integer")
end

private def w193_exact_keys!(object : Hash(String, JSON::Any), expected : Array(String), label : String) : Nil
  actual = object.keys.sort
  wanted = expected.sort
  w193_require(actual == wanted, "#{label} keys differ: #{actual}")
end

private def w193_hex_nibble(byte : UInt8, label : String) : UInt8
  case byte
  when 48_u8..57_u8  then byte - 48_u8
  when 97_u8..102_u8 then byte - 87_u8
  else
    raise ArgumentError.new("#{label} contains noncanonical lowercase hex")
  end
end

private def w193_decode_hex(value : JSON::Any, label : String, maximum : Int32 = W193_MAX_DATA_BYTES) : Bytes
  text = value.as_s
  w193_require(text.bytesize.even?, "#{label} hex length is odd")
  byte_count = text.bytesize // 2
  w193_require(byte_count <= maximum, "#{label} exceeds the bounded byte count")
  output = Bytes.new(byte_count)
  byte_count.times do |index|
    high = w193_hex_nibble(text.byte_at(index * 2), label)
    low = w193_hex_nibble(text.byte_at(index * 2 + 1), label)
    output[index] = ((high << 4) | low).to_u8
  end
  output
rescue TypeCastError
  raise ArgumentError.new("#{label} hex is not a string")
end

private def w193_hex(bytes : Bytes) : String
  digits = "0123456789abcdef".to_slice
  String.build(bytes.size * 2) do |io|
    bytes.each do |byte|
      io.write_byte(digits[(byte >> 4).to_i])
      io.write_byte(digits[(byte & 0x0f_u8).to_i])
    end
  end
end

private def w193_expected_values(path : Hash(String, JSON::Any), row_count : Int32, label : String) : Array(String?)
  values = w193_array(w193_field(path, "expected_values_hex", label), "#{label}.expected_values_hex")
  w193_require(values.size == row_count, "#{label}: expected value count differs from row count")
  decoded = Array(String?).new(row_count)
  values.each_with_index do |value, index|
    if value.raw.nil?
      decoded << nil
    else
      hex = value.as_s
      w193_require(hex.bytesize.even? && hex.bytesize // 2 <= W193_MAX_DATA_BYTES,
        "#{label} row #{index}: expected String hex is outside its bound")
      hex.each_byte { |byte| w193_hex_nibble(byte, "#{label} row #{index} expected String") }
      decoded << hex
    end
  end
  w193_require(decoded.any? { |value| !value.nil? }, "#{label}: path has no present Copy row")
  decoded
rescue TypeCastError
  raise ArgumentError.new("#{label}: expected value is neither NULL nor hex text")
end

private def w193_parse_events(path : Hash(String, JSON::Any), data_size : Int32, label : String) : Array(CrystalClick::ObjectSharedPathSubstreamEvent)
  records = w193_array(w193_field(path, "events", label), "#{label}.events")
  w193_require(records.size == W193_EVENT_NAMES.size, "#{label}: event count differs from captured String profile")
  events = Array(CrystalClick::ObjectSharedPathSubstreamEvent).new(records.size)
  previous = 0_u64
  records.each_with_index do |record, index|
    fields = w193_object(record, "#{label} event #{index}")
    w193_exact_keys!(fields, ["name", "relative_offset", "data_mark"], "#{label} event #{index}")
    name = w193_string(fields, "name", "#{label} event #{index}")
    w193_require(name == W193_EVENT_NAMES[index], "#{label}: event order/name differs at index #{index}")
    relative_offset = w193_int(fields, "relative_offset", "#{label} event #{index}", data_size.to_i64).to_u64
    w193_require(index == 0 ? relative_offset == 0_u64 : relative_offset >= previous,
      "#{label}: event offsets move backward or do not begin at zero")
    mark = w193_array(w193_field(fields, "data_mark", "#{label} event #{index}"), "#{label} event mark")
    w193_require(mark.size == 2, "#{label} event #{index}: Data mark is not a pair")
    mark.each { |part| w193_require(part.as_i64 >= 0, "#{label} event #{index}: Data mark is negative") }
    events << CrystalClick::ObjectSharedPathSubstreamEvent.new(name, relative_offset)
    previous = relative_offset
  end
  events
end

private def w193_validate_prefix_expectations!(path : Hash(String, JSON::Any), data : Bytes, events : Array(CrystalClick::ObjectSharedPathSubstreamEvent), label : String) : Nil
  physical = w193_object(w193_field(path, "physical", label), "#{label}.physical")
  w193_exact_keys!(physical, [
    "dynamic_structure_prefix_hex", "dynamic_version", "ordinary_type_count", "statistics_mode",
    "variant_mode_prefix_hex", "variant_discriminator_mode", "granule_format", "discriminators",
    "shared_variant_sizes", "decoded_values_hex",
  ], "#{label}.physical")
  structure_size = events[1].relative_offset.to_i
  structure = data[0, structure_size]
  w193_require(w193_hex(structure) == w193_string(physical, "dynamic_structure_prefix_hex", label),
    "#{label}: manifest Dynamic prefix differs from path Data")
  w193_require(w193_int(physical, "dynamic_version", label) == 4_i64 &&
               w193_int(physical, "ordinary_type_count", label) == 0_i64 &&
               w193_string(physical, "statistics_mode", label) == "NONE",
    "#{label}: retained Dynamic prefix metadata differs")
  mode_start = events[1].relative_offset.to_i
  mode_end = events[2].relative_offset.to_i
  w193_require(mode_end - mode_start == 8, "#{label}: Variant mode prefix extent differs")
  mode = data[mode_start, mode_end - mode_start]
  w193_require(w193_hex(mode) == w193_string(physical, "variant_mode_prefix_hex", label) &&
               mode == Bytes[1, 0, 0, 0, 0, 0, 0, 0] &&
               w193_string(physical, "variant_discriminator_mode", label) == "COMPACT",
    "#{label}: retained Variant mode prefix differs")
  w193_require(w193_string(physical, "granule_format", label) == "PLAIN" ||
               w193_string(physical, "granule_format", label) == "COMPACT",
    "#{label}: unsupported granule format in retained String profile")
end

private def w193_validate_structure_types!(structures : Hash(String, CrystalClick::DynamicStructure), expected : Hash(String, JSON::Any), label : String) : Hash(String, JSON::Any)
  expected.keys.sort.each do |site|
    expected_value = expected[site]? || raise ArgumentError.new("#{label}.structure_types_by_site lacks #{site}")
    expected_types = w193_array(expected_value, "#{label}.structure_types_by_site.#{site}")
    w193_require(expected_types.empty?, "#{label}: fixture expects an empty Dynamic ordinary roster")
  end
  actual = Hash(String, JSON::Any).new
  structures.each do |site, structure|
    actual[site] = JSON::Any.new(structure.types.map { |type| JSON::Any.new(type.name) })
  end
  w193_require(actual.keys.sort == expected.keys.sort, "#{label}: decoded Dynamic site paths differ from manifest")
  expected.each do |site, value|
    expected_types = w193_array(value, "#{label}.structure_types_by_site.#{site}").map(&.as_s)
    actual_value = actual[site]? || raise ArgumentError.new("#{label} decoded structure types lack #{site}")
    actual_types = w193_array(actual_value, "#{label} decoded structure types").map(&.as_s)
    w193_require(actual_types == expected_types, "#{label}: decoded Dynamic type roster differs at #{site}")
  end
  actual
end

private def w193_budget_snapshot(budget : CrystalClick::BinaryCodecBudget) : JSON::Any
  JSON::Any.new({
    "node_count"      => JSON::Any.new(budget.node_count),
    "element_count"   => JSON::Any.new(budget.element_count),
    "wire_byte_count" => JSON::Any.new(budget.wire_byte_count),
  })
end

private def w193_run : Int32
  unless ARGV.size == 1
    raise ArgumentError.new("usage: crystal scripts/validate_object_shared_path_w193.cr MANIFEST.json")
  end
  path = ARGV[0]
  w193_require(File.file?(path) && !File.symlink?(path), "manifest is not a plain file")
  size = File.size(path)
  w193_require(size <= W193_MAX_MANIFEST_BYTES, "manifest exceeds #{W193_MAX_MANIFEST_BYTES} bytes")
  bytes = Bytes.new(size.to_i)
  File.open(path) { |file| file.read_fully(bytes) }
  w193_require(File.size(path) == size, "manifest changed while being read")
  manifest = JSON.parse(String.new(bytes))
  root = w193_object(manifest, "manifest")
  w193_exact_keys!(root, ["format", "capture_root", "source_revision", "runtime_pin", "stream_inventory_sha256", "profile_ids", "profiles", "source_checks"], "manifest")
  w193_require(w193_string(root, "format", "manifest") == "object_shared_path_w193_manifest_v1", "manifest format differs")
  w193_require(w193_string(root, "source_revision", "manifest") == W193_SOURCE_REVISION, "manifest ClickHouse source revision differs")
  w193_require(!w193_string(root, "capture_root", "manifest").empty?, "manifest capture root is empty")
  inventory_hash = w193_string(root, "stream_inventory_sha256", "manifest")
  w193_require(inventory_hash.bytesize == 64 && inventory_hash.each_byte.all? { |byte| (48_u8..57_u8).includes?(byte) || (97_u8..102_u8).includes?(byte) },
    "manifest stream inventory digest is malformed")
  w193_require(inventory_hash == W193_STREAM_INVENTORY_SHA256, "manifest stream inventory identity differs")
  runtime = w193_object(w193_field(root, "runtime_pin", "manifest"), "manifest.runtime_pin")
  w193_exact_keys!(runtime, ["version", "build", "sha256"], "manifest.runtime_pin")
  w193_require(w193_string(runtime, "version", "manifest.runtime_pin") == W193_RUNTIME_VERSION &&
               w193_string(runtime, "build", "manifest.runtime_pin") == W193_RUNTIME_BUILD &&
               w193_string(runtime, "sha256", "manifest.runtime_pin") == W193_RUNTIME_SHA256,
    "manifest ClickHouse runtime pin differs")
  ids = w193_array(w193_field(root, "profile_ids", "manifest"), "manifest.profile_ids").map(&.as_s)
  w193_require(ids == W193_PROFILE_IDS, "manifest profile roster/order differs")
  profiles = w193_array(w193_field(root, "profiles", "manifest"), "manifest.profiles")
  w193_require(profiles.size == W193_PROFILE_IDS.size, "manifest profile count differs")

  source_checks = w193_object(w193_field(root, "source_checks", "manifest"), "manifest.source_checks")
  w193_exact_keys!(source_checks, [
    "w191_raw_part_streams_authenticated", "w192_copy_slices_bound_to_authored_sql_and_literals",
    "path_values_independently_decoded_from_raw_data", "string_null_plain_and_compact_capture_coverage",
    "shared_variant_actual_type", "structure_chunk_count", "path_record_count",
    "physical_data_byte_count", "invocation_count",
  ], "manifest.source_checks")
  w193_require(source_checks["w191_raw_part_streams_authenticated"]?.try(&.as_bool) == true &&
               source_checks["w192_copy_slices_bound_to_authored_sql_and_literals"]?.try(&.as_bool) == true &&
               source_checks["path_values_independently_decoded_from_raw_data"]?.try(&.as_bool) == true &&
               source_checks["string_null_plain_and_compact_capture_coverage"]?.try(&.as_bool) == true &&
               source_checks["shared_variant_actual_type"]?.try(&.as_s) == "String" &&
               source_checks["structure_chunk_count"]?.try(&.as_i64) == 42_i64 &&
               source_checks["path_record_count"]?.try(&.as_i64) == W193_EXPECTED_PATH_RECORDS.to_i64 &&
               source_checks["physical_data_byte_count"]?.try(&.as_i64) == W193_EXPECTED_PHYSICAL_DATA_BYTES.to_i64 &&
               source_checks["invocation_count"]?.try(&.as_i64) == 100_i64,
    "manifest source checks do not describe the captured String frontier")

  limits = CrystalClick::BinaryCodecLimits.default
  read_budget = CrystalClick::BinaryCodecBudget.new(limits)
  write_budget = CrystalClick::BinaryCodecBudget.new(limits, true)
  dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
  path_records = [] of JSON::Any
  chunk_count = 0
  physical_data_byte_count = 0_i64
  seen_path_records = 0

  profiles.each_with_index do |profile_any, profile_index|
    profile = w193_object(profile_any, "profile #{profile_index}")
    w193_exact_keys!(profile, ["profile_id", "kind", "bucket_count", "chunks"], "profile #{profile_index}")
    profile_id = w193_string(profile, "profile_id", "profile #{profile_index}")
    w193_require(profile_id == W193_PROFILE_IDS[profile_index], "manifest profile order differs")
    expected_profile = W193_EXPECTED_PROFILES.fetch(profile_id) { raise ArgumentError.new("unsupported profile #{profile_id}") }
    w193_require(w193_string(profile, "kind", profile_id) == expected_profile[0], "#{profile_id}: kind differs")
    bucket_count = w193_int(profile, "bucket_count", profile_id, 256_i64).to_i32
    w193_require(bucket_count == expected_profile[1], "#{profile_id}: bucket count differs")
    chunks = w193_array(w193_field(profile, "chunks", profile_id), "#{profile_id}.chunks")
    row_schedule = expected_profile[2]
    w193_require(chunks.size == row_schedule.size, "#{profile_id}: chunk count differs")
    bucket_path_ordinals = Array(Int32).new(bucket_count, 0)
    profile_path_count = 0

    chunks.each_with_index do |chunk_any, chunk_index|
      chunk = w193_object(chunk_any, "#{profile_id} chunk #{chunk_index}")
      w193_exact_keys!(chunk, ["chunk_index", "row_count", "buckets"], "#{profile_id} chunk #{chunk_index}")
      declared_index = w193_int(chunk, "chunk_index", "#{profile_id} chunk", Int32::MAX.to_i64).to_i32
      row_count = w193_int(chunk, "row_count", "#{profile_id} chunk", W193_MAX_ROWS.to_i64).to_i32
      w193_require(declared_index == chunk_index && row_count == row_schedule[chunk_index],
        "#{profile_id} chunk #{chunk_index}: identity or row schedule differs")
      buckets = w193_array(w193_field(chunk, "buckets", "#{profile_id} chunk #{chunk_index}"), "#{profile_id} buckets")
      w193_require(buckets.size == bucket_count, "#{profile_id} chunk #{chunk_index}: bucket record count differs")
      chunk_path_set = Set(String).new

      buckets.each_with_index do |bucket_any, bucket_index|
        bucket_label = "#{profile_id} chunk #{chunk_index} bucket #{bucket_index}"
        bucket = w193_object(bucket_any, bucket_label)
        w193_exact_keys!(bucket, ["bucket_id", "paths", "structure_record_hex", "data_mark", "data_offset", "paths_marks_mark", "paths_marks_offset", "metadata_mark", "metadata_offset"], bucket_label)
        bucket_id = w193_int(bucket, "bucket_id", bucket_label, 255_i64).to_i32
        w193_require(bucket_id == bucket_index, "#{bucket_label}: bucket order differs")
        structure_record = w193_decode_hex(w193_field(bucket, "structure_record_hex", bucket_label), "#{bucket_label} structure record", 1_048_576)
        w193_require(structure_record.size >= 48, "#{bucket_label}: structure record is truncated")
        {"data_mark", "paths_marks_mark", "metadata_mark"}.each do |key|
          mark = w193_array(w193_field(bucket, key, bucket_label), "#{bucket_label}.#{key}")
          w193_require(mark.size == 2 && mark.all? { |part| part.as_i64 >= 0 }, "#{bucket_label}: #{key} is malformed")
        end
        {"data_offset", "paths_marks_offset", "metadata_offset"}.each do |key|
          w193_int(bucket, key, bucket_label, W193_MAX_DATA_BYTES.to_i64)
        end

        paths = w193_array(w193_field(bucket, "paths", bucket_label), "#{bucket_label}.paths")
        w193_require(paths.size <= 65_536, "#{bucket_label}: path count exceeds bound")
        previous_path_hex = ""
        paths.each_with_index do |path_any, path_index|
          path_label = "#{bucket_label} path #{path_index}"
          path_fields = w193_object(path_any, path_label)
          w193_exact_keys!(path_fields, [
            "path", "path_hex", "chunk_index", "row_count", "type", "structure_types_by_site",
            "expected_values_hex", "data_mark", "data_offset", "names_mark", "names_offset",
            "substreams_marks_mark", "substreams_marks_offset", "events", "data_hex", "data_bytes",
            "path_ordinal", "physical",
          ], path_label)
          path_text = w193_string(path_fields, "path", path_label)
          path_hex = w193_string(path_fields, "path_hex", path_label)
          w193_require(path_text.valid_encoding? && w193_hex(path_text.to_slice) == path_hex,
            "#{path_label}: raw path bytes differ from path_hex")
          w193_require(path_index == 0 || previous_path_hex < path_hex,
            "#{bucket_label}: paths are duplicate or not byte sorted")
          previous_path_hex = path_hex
          w193_require(chunk_path_set.add?(path_hex), "#{profile_id} chunk #{chunk_index}: path occurs in multiple buckets")
          profile_path_count += 1
          w193_require(w193_int(path_fields, "chunk_index", path_label, Int32::MAX.to_i64).to_i32 == chunk_index &&
                       w193_int(path_fields, "row_count", path_label, W193_MAX_ROWS.to_i64).to_i32 == row_count &&
                       w193_string(path_fields, "type", path_label) == "Dynamic(max_types=0)",
            "#{path_label}: path identity, row count, or Dynamic type differs")

          structures_expected = w193_object(w193_field(path_fields, "structure_types_by_site", path_label), "#{path_label}.structure_types_by_site")
          w193_exact_keys!(structures_expected, ["root"], "#{path_label}.structure_types_by_site")
          expected_by_row = w193_expected_values(path_fields, row_count, path_label)
          data = w193_decode_hex(w193_field(path_fields, "data_hex", path_label), "#{path_label} Data")
          data_bytes = w193_int(path_fields, "data_bytes", path_label, W193_MAX_DATA_BYTES.to_i64).to_i32
          w193_require(data.size == data_bytes, "#{path_label}: declared Data extent differs")
          data_offset = w193_int(path_fields, "data_offset", path_label, W193_MAX_DATA_BYTES.to_i64)
          w193_require(data_offset < W193_MAX_DATA_BYTES, "#{path_label}: Data pointer exceeds bound")
          {"data_mark", "names_mark", "substreams_marks_mark"}.each do |key|
            mark = w193_array(w193_field(path_fields, key, path_label), "#{path_label}.#{key}")
            w193_require(mark.size == 2 && mark.all? { |part| part.as_i64 >= 0 }, "#{path_label}: #{key} is malformed")
          end
          {"names_offset", "substreams_marks_offset"}.each do |key|
            w193_int(path_fields, key, path_label, W193_MAX_DATA_BYTES.to_i64)
          end
          events = w193_parse_events(path_fields, data.size, path_label)
          w193_validate_prefix_expectations!(path_fields, data, events, path_label)

          decoded = CrystalClick::ObjectSharedPathCodec.decode_with_structures_with_budget(
            data,
            events,
            row_count,
            dynamic,
            read_budget,
          )
          w193_require(decoded.rows.size == row_count, "#{path_label}: decoded row count differs")
          structures_output = w193_validate_structure_types!(decoded.structures, structures_expected, path_label)
          values_json = Array(JSON::Any).new(row_count)
          decoded.rows.each_with_index do |row, row_index|
            w193_require(row.type == dynamic, "#{path_label} row #{row_index}: nominal Dynamic type differs")
            expected_value = expected_by_row[row_index]
            if row.is_null?
              w193_require(expected_value.nil?, "#{path_label} row #{row_index}: unexpected Dynamic NULL")
              values_json << JSON::Any.new(nil)
            else
              w193_require(!expected_value.nil? && row.child_count == 1,
                "#{path_label} row #{row_index}: Dynamic child presence differs")
              child = row.child_at(0)
              w193_require(child.type.tag == CrystalClick::BinaryDataType::TAG_STRING,
                "#{path_label} row #{row_index}: retained actual value type is not String")
              value_hex = w193_hex(child.as_string.to_slice)
              w193_require(value_hex == expected_value,
                "#{path_label} row #{row_index}: decoded String differs from W192/authored value")
              values_json << JSON::Any.new(value_hex)
            end
          end

          decoded_read_snapshot = w193_budget_snapshot(read_budget)
          encoded = CrystalClick::ObjectSharedPathCodec.encode_with_budget(
            dynamic,
            decoded.structures,
            decoded.rows,
            write_budget,
          )
          encoded_data = encoded.data
          encoded_events = encoded.events
          encoded_event_json = encoded_events.map do |event|
            JSON::Any.new({
              "name"            => JSON::Any.new(event.name),
              "relative_offset" => JSON::Any.new(event.relative_offset),
            })
          end
          expected_event_json = events.map do |event|
            JSON::Any.new({
              "name"            => JSON::Any.new(event.name),
              "relative_offset" => JSON::Any.new(event.relative_offset),
            })
          end
          w193_require(encoded_data == data && encoded_event_json == expected_event_json,
            "#{path_label}: exact Data/event re-encode differs")
          decoded_values_expected = w193_array(w193_field(w193_object(w193_field(path_fields, "physical", path_label), "#{path_label}.physical"), "decoded_values_hex", path_label), "#{path_label}.physical.decoded_values_hex")
          w193_require(decoded_values_expected.size == row_count && decoded_values_expected == values_json,
            "#{path_label}: independent physical String/NULL parse differs")

          write_snapshot = w193_budget_snapshot(write_budget)
          path_ordinal = w193_int(path_fields, "path_ordinal", path_label, Int32::MAX.to_i64).to_i32
          w193_require(path_ordinal == bucket_path_ordinals[bucket_id], "#{path_label}: bucket path ordinal differs")
          bucket_path_ordinals[bucket_id] += 1
          path_records << JSON::Any.new({
            "profile_id"              => JSON::Any.new(profile_id),
            "bucket_id"               => JSON::Any.new(bucket_id),
            "chunk_index"             => JSON::Any.new(chunk_index),
            "path"                    => JSON::Any.new(path_text),
            "path_hex"                => JSON::Any.new(path_hex),
            "row_count"               => JSON::Any.new(row_count),
            "type"                    => JSON::Any.new("Dynamic(max_types=0)"),
            "structure_types_by_site" => JSON::Any.new(structures_output),
            "events"                  => JSON::Any.new(encoded_event_json),
            "data_hex"                => JSON::Any.new(w193_hex(data)),
            "reencoded_data_hex"      => JSON::Any.new(w193_hex(encoded_data)),
            "decoded_values_hex"      => JSON::Any.new(values_json),
            "physical_data_bytes"     => JSON::Any.new(data.size),
            "read_budget_after"       => decoded_read_snapshot,
            "write_budget_after"      => write_snapshot,
          })
          physical_data_byte_count += data.size.to_i64
          seen_path_records += 1
          w193_require(seen_path_records <= W193_MAX_PATH_RECORDS, "path record count exceeds bound")
        end
      end
      chunk_count += 1
    end
    expected_path_count = W193_EXPECTED_PATH_COUNTS[profile_id]? || raise ArgumentError.new("unsupported profile #{profile_id}")
    w193_require(profile_path_count == expected_path_count,
      "#{profile_id}: path record count differs from pinned capture")
  end

  w193_require(chunk_count == 42, "manifest has #{chunk_count} chunks; expected 42")

  w193_require(seen_path_records > 0, "manifest contains no per-path Data records")
  w193_require(seen_path_records == W193_EXPECTED_PATH_RECORDS,
    "manifest path record count differs from pinned capture")
  w193_require(physical_data_byte_count == W193_EXPECTED_PHYSICAL_DATA_BYTES,
    "manifest physical Data byte count differs from pinned capture")
  w193_require(w193_int(source_checks, "path_record_count", "manifest.source_checks", W193_MAX_PATH_RECORDS.to_i64).to_i32 == seen_path_records,
    "manifest path record count differs")
  w193_require(w193_int(source_checks, "physical_data_byte_count", "manifest.source_checks", Int64::MAX) == physical_data_byte_count,
    "manifest physical Data byte total differs")
  read_snapshot = w193_budget_snapshot(read_budget)
  write_snapshot = w193_budget_snapshot(write_budget)
  output = JSON::Any.new({
    "format"                   => JSON::Any.new("object_shared_path_w193_helper_v1"),
    "profile_ids"              => JSON::Any.new(W193_PROFILE_IDS.map { |id| JSON::Any.new(id) }),
    "chunk_count"              => JSON::Any.new(chunk_count),
    "path_record_count"        => JSON::Any.new(seen_path_records),
    "physical_data_byte_count" => JSON::Any.new(physical_data_byte_count),
    "budget_scope"             => JSON::Any.new("one read and one write budget shared across all path records"),
    "read_budget"              => read_snapshot,
    "write_budget"             => write_snapshot,
    "path_records"             => JSON::Any.new(path_records),
  })
  puts output.to_json
  0
end

w193_run
