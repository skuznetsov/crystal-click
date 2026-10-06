require "digest/sha256"
require "json"
require "../src/crystal_click"

module ValidateObjectSharedPhysicalW194
  extend self

  FORMAT          = "object_shared_physical_w194_manifest_v1"
  OUTPUT_FORMAT   = "object_shared_physical_w194_helper_v1"
  SOURCE_REVISION = "ef037e60fc7f5654c8c80eefb8be82e3c56f9a67"
  RUNTIME_VERSION = "26.10.1.1201"
  RUNTIME_BUILD   = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
  RUNTIME_SHA256  = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
  PROFILE_IDS     = [
    "root_advanced_v2",
    "root_advanced_chunked_v3",
    "array_advanced_v2",
    "array_advanced_chunked_v3",
    "empty_root_advanced_v2",
    "empty_root_advanced_chunked_v3",
    "empty_array_advanced_v2",
    "empty_array_advanced_chunked_v3",
  ]
  LANE_NAMES = [
    "structure", "data", "paths_marks", "substreams", "substreams_marks", "paths_substreams_metadata",
  ]
  FRAME_BYTES          = [17, 37]
  HELPER_OUTPUT_NAME   = "object_shared_physical_w194_helper_v1.json"
  MAX_TOTAL_BUCKETS    = 12
  PARENT_ROWS          = [2_u64, 2_u64, 2_u64, 2_u64]
  MARK_ROWS            = [2_u64, 2_u64, 2_u64, 2_u64, 0_u64]
  MAX_MANIFEST_BYTES   = 16 * 1024 * 1024
  MAX_COMPRESSED_BYTES =    65_536
  MAX_DECODED_BYTES    = 1_048_576

  private struct ProfileExpectation
    getter kind : String
    getter version : Int32
    getter buckets : Int32
    getter chunk_rows : Array(Int32)

    def initialize(@kind : String, @version : Int32, @buckets : Int32, @chunk_rows : Array(Int32))
    end
  end

  EXPECTATIONS = {
    "root_advanced_v2"                => ProfileExpectation.new("root", 2, 2, [2, 2, 2, 2]),
    "root_advanced_chunked_v3"        => ProfileExpectation.new("root", 3, 2, [1, 1, 1, 1, 1, 1, 1, 1]),
    "array_advanced_v2"               => ProfileExpectation.new("array", 2, 2, [0, 1, 3, 0]),
    "array_advanced_chunked_v3"       => ProfileExpectation.new("array", 3, 2, [0, 1, 1, 1, 1, 0]),
    "empty_root_advanced_v2"          => ProfileExpectation.new("root", 2, 1, [2, 2, 2, 2]),
    "empty_root_advanced_chunked_v3"  => ProfileExpectation.new("root", 3, 1, [1, 1, 1, 1, 1, 1, 1, 1]),
    "empty_array_advanced_v2"         => ProfileExpectation.new("array", 2, 1, [0, 0, 0, 0]),
    "empty_array_advanced_chunked_v3" => ProfileExpectation.new("array", 3, 1, [0, 0, 0, 0]),
  }

  private def require!(condition : Bool, message : String) : Nil
    raise ArgumentError.new("W194: #{message}") unless condition
  end

  private def object(value : JSON::Any, label : String) : Hash(String, JSON::Any)
    value.as_h
  rescue TypeCastError
    raise ArgumentError.new("W194: #{label} must be an object")
  end

  private def array(value : JSON::Any, label : String) : Array(JSON::Any)
    value.as_a
  rescue TypeCastError
    raise ArgumentError.new("W194: #{label} must be an array")
  end

  private def field(fields : Hash(String, JSON::Any), name : String, label : String) : JSON::Any
    fields[name]? || raise ArgumentError.new("W194: #{label} lacks #{name}")
  end

  private def exact_keys!(fields : Hash(String, JSON::Any), expected : Array(String), label : String) : Nil
    require!(fields.keys.sort == expected.sort, "#{label} keys differ")
  end

  private def string(value : JSON::Any, label : String) : String
    value.as_s
  rescue TypeCastError
    raise ArgumentError.new("W194: #{label} must be a string")
  end

  private def unsigned(value : JSON::Any, label : String, maximum : Int64 = Int64::MAX) : Int64
    parsed = value.as_i64
    require!(parsed >= 0 && parsed <= maximum, "#{label} is outside its bounded integer domain")
    parsed
  rescue TypeCastError
    raise ArgumentError.new("W194: #{label} must be a bounded integer")
  end

  private def sha256(bytes : Bytes) : String
    Digest::SHA256.hexdigest(bytes)
  end

  private def hex_bytes(value : JSON::Any, label : String, maximum : Int32 = MAX_DECODED_BYTES) : Bytes
    text = string(value, label)
    require!(text.bytesize.even? && text.bytesize // 2 <= maximum, "#{label} hex is outside its bound")
    bytes = Bytes.new(text.bytesize // 2)
    bytes.size.times do |index|
      high = hex_nibble(text.byte_at(index * 2), label)
      low = hex_nibble(text.byte_at(index * 2 + 1), label)
      bytes[index] = ((high << 4) | low).to_u8
    end
    bytes
  end

  private def hex_nibble(byte : UInt8, label : String) : UInt8
    case byte
    when 48_u8..57_u8  then byte - 48_u8
    when 97_u8..102_u8 then byte - 87_u8
    else
      raise ArgumentError.new("W194: #{label} contains noncanonical lowercase hex")
    end
  end

  private def json(value : String) : JSON::Any
    JSON::Any.new(value)
  end

  private def json(value : Int32) : JSON::Any
    JSON::Any.new(value.to_i64)
  end

  private def json(value : Int64) : JSON::Any
    JSON::Any.new(value)
  end

  private def json(value : UInt64) : JSON::Any
    require!(value <= Int64::MAX.to_u64, "JSON integer exceeds Int64")
    JSON::Any.new(value.to_i64)
  end

  private def json(value : Bool) : JSON::Any
    JSON::Any.new(value)
  end

  private def json(value : Array(JSON::Any)) : JSON::Any
    JSON::Any.new(value)
  end

  private def json(value : Hash(String, JSON::Any)) : JSON::Any
    JSON::Any.new(value)
  end

  private def load_bounded_file(path : String, maximum : Int64, label : String) : Bytes
    require!(File.file?(path) && !File.symlink?(path), "#{label} is absent or symlinked")
    size = File.size(path)
    require!(size >= 0 && size <= maximum, "#{label} exceeds its byte bound")
    bytes = File.read(path).to_slice.dup
    require!(bytes.size.to_i64 == size, "#{label} changed while being read")
    bytes
  end

  private def checked_directory(path : String, label : String) : String
    require!(Dir.exists?(path) && !File.symlink?(path), "#{label} is absent or symlinked")
    real = File.realpath(path)
    require!(real == path, "#{label} is not a canonical path")
    real
  end

  private def contained_input_file(root : String, path : String, label : String) : String
    require!(File.file?(path) && !File.symlink?(path), "#{label} is absent or symlinked")
    real = File.realpath(path)
    require!(real == path && real.starts_with?(root + "/"), "#{label} escapes or aliases the capture root")
    real
  end

  private def mark_triples(bytes : Bytes, label : String) : Array(Array(UInt64))
    require!(bytes.size == 5 * 24, "#{label} must contain exactly five plain mark triples")
    input = IO::Memory.new(bytes)
    triples = [] of Array(UInt64)
    5.times do
      triples << [
        input.read_bytes(UInt64, IO::ByteFormat::LittleEndian),
        input.read_bytes(UInt64, IO::ByteFormat::LittleEndian),
        input.read_bytes(UInt64, IO::ByteFormat::LittleEndian),
      ]
    end
    require!(triples.map(&.[2]) == MARK_ROWS, "#{label} physical parent grid differs")
    triples
  end

  private def validate_runtime_and_manifest!(manifest : Hash(String, JSON::Any)) : String
    exact_keys!(manifest, %w[format capture_root source_revision runtime_pin profile_ids frame_bytes source_inventory_sha256 source_invocation_count limits profiles claims], "manifest")
    require!(string(field(manifest, "format", "manifest"), "manifest.format") == FORMAT, "manifest format differs")
    require!(string(field(manifest, "source_revision", "manifest"), "manifest.source_revision") == SOURCE_REVISION, "source revision differs")
    runtime = object(field(manifest, "runtime_pin", "manifest"), "manifest.runtime_pin")
    exact_keys!(runtime, %w[version build sha256], "manifest runtime pin")
    require!(string(field(runtime, "version", "runtime pin"), "runtime version") == RUNTIME_VERSION &&
             string(field(runtime, "build", "runtime pin"), "runtime build") == RUNTIME_BUILD &&
             string(field(runtime, "sha256", "runtime pin"), "runtime SHA") == RUNTIME_SHA256,
      "runtime pin differs from W191")
    ids = array(field(manifest, "profile_ids", "manifest"), "manifest.profile_ids").map_with_index do |value, index|
      string(value, "profile_ids[#{index}]")
    end
    require!(ids == PROFILE_IDS, "profile ID roster/order differs")
    frames = array(field(manifest, "frame_bytes", "manifest"), "manifest.frame_bytes").map do |value|
      unsigned(value, "frame byte size", Int32::MAX.to_i64).to_i32
    end
    require!(frames == FRAME_BYTES, "frame-size schedule differs")
    inventory_hash = string(field(manifest, "source_inventory_sha256", "manifest"), "inventory SHA")
    require!(inventory_hash.matches?(/\A[0-9a-f]{64}\z/), "source inventory SHA is malformed")
    invocations = unsigned(field(manifest, "source_invocation_count", "manifest"), "source invocation count", 10_000_i64)
    require!(invocations > 0, "source invocation count is empty")

    limits = object(field(manifest, "limits", "manifest"), "manifest.limits")
    exact_keys!(limits, %w[max_compressed_lane_bytes max_decoded_lane_bytes max_profiles max_parent_marks_per_profile max_buckets_total], "manifest limits")
    require!(unsigned(field(limits, "max_compressed_lane_bytes", "limits"), "compressed lane cap") == MAX_COMPRESSED_BYTES &&
             unsigned(field(limits, "max_decoded_lane_bytes", "limits"), "decoded lane cap") == MAX_DECODED_BYTES &&
             unsigned(field(limits, "max_profiles", "limits"), "profile cap") == PROFILE_IDS.size &&
             unsigned(field(limits, "max_parent_marks_per_profile", "limits"), "parent cap") == PARENT_ROWS.size &&
             unsigned(field(limits, "max_buckets_total", "limits"), "total bucket cap") == MAX_TOTAL_BUCKETS,
      "manifest limits differ from the helper contract")
    claims = object(field(manifest, "claims", "manifest"), "manifest.claims")
    exact_keys!(claims, %w[source_lanes_rederived_from_w191_w193 chunks_bound_to_each_bucket_structure_mark_intervals physical_parent_rows_are_not_logical_chunk_rows actual_path_value_decode_scope persisted_part_admission], "manifest claims")
    require!(field(claims, "source_lanes_rederived_from_w191_w193", "claims").as_bool &&
             field(claims, "chunks_bound_to_each_bucket_structure_mark_intervals", "claims").as_bool &&
             field(claims, "physical_parent_rows_are_not_logical_chunk_rows", "claims").as_bool &&
             string(field(claims, "actual_path_value_decode_scope", "claims"), "claims.actual_path_value_decode_scope") == "W193 captured String shared paths only" &&
             !field(claims, "persisted_part_admission", "claims").as_bool,
      "manifest claim boundary differs")
    root_value = string(field(manifest, "capture_root", "manifest"), "manifest.capture_root")
    root = checked_directory(root_value, "capture root")
    require!(root.starts_with?("/private/tmp/") && File.dirname(root) == File.realpath("/private/tmp"),
      "capture root must be a direct child of /private/tmp")
    root
  rescue TypeCastError
    raise ArgumentError.new("W194: manifest contains a field with the wrong JSON type")
  end

  private def expectation(profile_id : String) : ProfileExpectation
    EXPECTATIONS[profile_id]? || raise ArgumentError.new("W194: unknown profile ID #{profile_id.inspect}")
  end

  private def validate_profile!(profile : Hash(String, JSON::Any), profile_id : String) : ProfileExpectation
    label = "profile #{profile_id}"
    exact_keys!(profile, %w[profile_id kind version bucket_count parent_rows buckets], label)
    expected = expectation(profile_id)
    require!(string(field(profile, "profile_id", label), "#{label}.profile_id") == profile_id &&
             string(field(profile, "kind", label), "#{label}.kind") == expected.kind &&
             unsigned(field(profile, "version", label), "#{label}.version", 3_i64) == expected.version &&
             unsigned(field(profile, "bucket_count", label), "#{label}.bucket_count", 2_i64) == expected.buckets,
      "#{label} profile identity differs")
    rows = array(field(profile, "parent_rows", label), "#{label}.parent_rows").map do |value|
      unsigned(value, "#{label}.parent_rows", Int32::MAX.to_i64).to_u64
    end
    require!(rows == PARENT_ROWS, "#{label} physical parent rows differ")
    buckets = array(field(profile, "buckets", label), "#{label}.buckets")
    require!(buckets.size == expected.buckets, "#{label} bucket roster size differs")
    buckets.each_with_index do |bucket_any, bucket_index|
      bucket = object(bucket_any, "#{label} bucket #{bucket_index}")
      exact_keys!(bucket, %w[bucket_id lanes parent_rows parents structure_record_count], "#{label} bucket #{bucket_index}")
      require!(unsigned(field(bucket, "bucket_id", "#{label} bucket"), "bucket_id", 255_i64) == bucket_index,
        "#{label} bucket order differs")
      bucket_rows = array(field(bucket, "parent_rows", "#{label} bucket"), "bucket parent rows").map do |value|
        unsigned(value, "bucket parent row", Int32::MAX.to_i64).to_u64
      end
      require!(bucket_rows == PARENT_ROWS, "#{label} bucket physical parent grid differs")
      parents = array(field(bucket, "parents", "#{label} bucket"), "bucket parents")
      require!(parents.size == PARENT_ROWS.size, "#{label} physical parent count differs")
      observed_chunk_rows = [] of Int32
      parents.each_with_index do |parent_any, parent_index|
        parent = object(parent_any, "#{label} parent #{parent_index}")
        exact_keys!(parent, %w[physical_rows chunks], "#{label} parent #{parent_index}")
        require!(unsigned(field(parent, "physical_rows", "parent"), "physical_rows", Int32::MAX.to_i64) == PARENT_ROWS[parent_index],
          "#{label} parent physical row count differs")
        chunks = array(field(parent, "chunks", "parent"), "parent chunks")
        require!(!chunks.empty? && (expected.version != 2 || chunks.size == 1),
          "#{label} parent chunk count differs for its version")
        chunks.each_with_index do |chunk_any, chunk_index|
          chunk = object(chunk_any, "#{label} chunk #{chunk_index}")
          exact_keys!(chunk, %w[row_count structure_record_hex structure_prefix_hex transport_offsets paths], "#{label} chunk #{chunk_index}")
          row_count = unsigned(field(chunk, "row_count", "chunk"), "chunk row_count", Int32::MAX.to_i64).to_i32
          require!(row_count > 0 || expected.kind == "array", "#{label}: zero-row chunks are only expected for Array fixtures")
          record = hex_bytes(field(chunk, "structure_record_hex", "chunk"), "structure record", MAX_DECODED_BYTES)
          require!(record.size >= 48, "#{label}: structure record lacks six-lane suffix")
          prefix = hex_bytes(field(chunk, "structure_prefix_hex", "chunk"), "structure prefix", MAX_DECODED_BYTES)
          require!(record.size == prefix.size + 48 && record[0, prefix.size] == prefix,
            "#{label}: structure prefix does not match the retained structure record")
          offsets = object(field(chunk, "transport_offsets", "chunk"), "chunk transport offsets")
          exact_keys!(offsets, %w[data paths_marks paths_substreams_metadata], "#{label} transport offsets")
          offsets.each do |lane_name, value|
            unsigned(value, "#{label} #{lane_name} decoded transport offset", MAX_DECODED_BYTES.to_i64)
          end
          paths = array(field(chunk, "paths", "chunk"), "chunk paths")
          names = paths.map_with_index do |path_any, path_index|
            path = object(path_any, "#{label} chunk path #{path_index}")
            exact_keys!(path, %w[name data_hex events], "#{label} chunk path #{path_index}")
            path_name = string(field(path, "name", "path"), "path.name")
            require!(path_name.valid_encoding? && !path_name.empty?, "#{label}: invalid or empty path name")
            data = hex_bytes(field(path, "data_hex", "path"), "#{label} path Data")
            events = array(field(path, "events", "path"), "path events")
            previous = 0_i64
            events.each_with_index do |event_any, event_index|
              event = object(event_any, "#{label} event #{event_index}")
              exact_keys!(event, %w[name relative_offset], "#{label} event #{event_index}")
              string(field(event, "name", "event"), "event.name")
              offset = unsigned(field(event, "relative_offset", "event"), "event.relative_offset", data.size.to_i64)
              require!(offset >= previous && (event_index != 0 || offset == 0), "#{label}: event offsets are not canonical")
              previous = offset
            end
            require!(data.empty? || !events.empty?, "#{label}: nonempty path Data requires its getter tape")
            path_name
          end
          require!(names == names.sort_by(&.to_slice.to_a) && names.uniq == names,
            "#{label}: path names are not strictly byte-sorted")
          require!(row_count != 0 || paths.empty?, "#{label}: zero-row chunk must be pathless")
          observed_chunk_rows << row_count
        end
      end
      require!(observed_chunk_rows == expected.chunk_rows, "#{label}: bucket chunk row schedule differs")
      structure_count = unsigned(field(bucket, "structure_record_count", "bucket"), "structure record count", MAX_DECODED_BYTES.to_i64)
      require!(structure_count == observed_chunk_rows.size, "#{label}: structure record count differs")
      lanes = array(field(bucket, "lanes", "bucket"), "bucket lanes")
      require!(lanes.size == LANE_NAMES.size, "#{label}: physical lane count differs")
      lane_decoded_ends = {} of String => Int64
      lane_names = lanes.map_with_index do |lane_any, lane_index|
        lane = object(lane_any, "#{label} lane #{lane_index}")
        exact_keys!(lane, %w[name logical_stream data_path marks_path expected_data_size expected_marks_size data_sha256 marks_sha256 mark_triples decoded_mark_offsets], "#{label} lane #{lane_index}")
        name = string(field(lane, "name", "lane"), "lane.name")
        require!(name == LANE_NAMES[lane_index], "#{label}: physical lane order differs")
        logical = string(field(lane, "logical_stream", "lane"), "lane.logical_stream")
        require!(logical.valid_encoding? && !logical.empty?, "#{label}: invalid logical stream name")
        ["data_path", "marks_path"].each do |key|
          string(field(lane, key, "lane"), "lane.#{key}")
        end
        data_size = unsigned(field(lane, "expected_data_size", "lane"), "expected_data_size", MAX_COMPRESSED_BYTES.to_i64)
        mark_size = unsigned(field(lane, "expected_marks_size", "lane"), "expected_marks_size", 5_i64 * 24_i64)
        require!(mark_size == 5_i64 * 24_i64, "#{label}: mark file size differs")
        %w[data_sha256 marks_sha256].each do |key|
          digest = string(field(lane, key, "lane"), "lane.#{key}")
          require!(digest.matches?(/\A[0-9a-f]{64}\z/), "#{label}: malformed lane SHA")
        end
        triples = array(field(lane, "mark_triples", "lane"), "lane mark triples")
        require!(triples.size == 5, "#{label}: lane triple count differs")
        triples.each { |triple| require!(array(triple, "mark triple").size == 3, "#{label}: malformed mark triple") }
        offsets = array(field(lane, "decoded_mark_offsets", "lane"), "lane decoded mark offsets").map do |value|
          unsigned(value, "decoded mark offset", MAX_DECODED_BYTES.to_i64)
        end
        require!(offsets.size == 5 && offsets.first == 0 && offsets == offsets.sort,
          "#{label}: decoded mark offsets are incomplete or nonmonotone")
        lane_decoded_ends[name] = offsets.last
        name
      end
      require!(lane_names == LANE_NAMES, "#{label}: physical lane names differ")
      parents.each do |parent_any|
        parent = object(parent_any, "#{label} parent")
        array(field(parent, "chunks", "parent"), "parent chunks").each do |chunk_any|
          chunk = object(chunk_any, "#{label} chunk")
          offsets = object(field(chunk, "transport_offsets", "chunk"), "chunk transport offsets")
          offsets.each do |lane_name, value|
            require!(unsigned(value, "#{label} #{lane_name} decoded transport offset", MAX_DECODED_BYTES.to_i64) <= lane_decoded_ends[lane_name],
              "#{label}: #{lane_name} transport offset exceeds its source decoded lane")
          end
        end
      end
    end
    expected
  rescue TypeCastError
    raise ArgumentError.new("W194: #{label} contains a field with the wrong JSON type")
  end

  private def authenticate_lane!(root : String, lane : Hash(String, JSON::Any), profile_id : String, bucket_id : Int32) : CrystalClick::ObjectSharedPhysicalLaneInput
    label = "#{profile_id} bucket #{bucket_id} #{string(field(lane, "name", "lane"), "lane.name")}"
    data_path = contained_input_file(root, string(field(lane, "data_path", label), "data_path"), "#{label} .bin")
    marks_path = contained_input_file(root, string(field(lane, "marks_path", label), "marks_path"), "#{label} .mrk2")
    data = load_bounded_file(data_path, MAX_COMPRESSED_BYTES.to_i64, "#{label} .bin")
    marks = load_bounded_file(marks_path, (5 * 24).to_i64, "#{label} .mrk2")
    require!(data.size.to_i64 == unsigned(field(lane, "expected_data_size", label), "expected_data_size", MAX_COMPRESSED_BYTES.to_i64), "#{label} .bin size differs")
    require!(marks.size.to_i64 == unsigned(field(lane, "expected_marks_size", label), "expected_marks_size", 5_i64 * 24_i64), "#{label} .mrk2 size differs")
    require!(sha256(data) == string(field(lane, "data_sha256", label), "data_sha256"), "#{label} .bin SHA differs")
    require!(sha256(marks) == string(field(lane, "marks_sha256", label), "marks_sha256"), "#{label} .mrk2 SHA differs")
    triples = mark_triples(marks, "#{label} .mrk2")
    expected_triples = array(field(lane, "mark_triples", label), "lane mark triples").map do |triple_any|
      array(triple_any, "mark triple").map { |part| unsigned(part, "mark coordinate") }.map(&.to_u64)
    end
    require!(triples == expected_triples, "#{label} raw mark triples differ from the manifest")
    decoded_offsets = array(field(lane, "decoded_mark_offsets", label), "decoded mark offsets").map do |value|
      unsigned(value, "decoded mark offset", MAX_DECODED_BYTES.to_i64)
    end
    require!(decoded_offsets.size == 5 && decoded_offsets.last <= MAX_DECODED_BYTES,
      "#{label} decoded coordinate roster differs")
    CrystalClick::ObjectSharedPhysicalLaneInput.new(
      data_path,
      marks_path,
      data.size.to_i64,
      marks.size.to_i64,
    )
  end

  private def path_from_manifest(path_any : JSON::Any, label : String) : CrystalClick::ObjectSharedPhysicalPath
    path = object(path_any, label)
    data = hex_bytes(field(path, "data_hex", label), "#{label}.data_hex")
    events = [] of CrystalClick::ObjectSharedPathSubstreamEvent
    array(field(path, "events", label), "#{label}.events").each_with_index do |event_any, index|
      event = object(event_any, "#{label} event #{index}")
      events << CrystalClick::ObjectSharedPathSubstreamEvent.new(
        string(field(event, "name", "event"), "event.name"),
        unsigned(field(event, "relative_offset", "event"), "event.relative_offset", data.size.to_i64).to_u64,
      )
    end
    CrystalClick::ObjectSharedPhysicalPath.new(
      string(field(path, "name", label), "path.name"),
      CrystalClick::ObjectSharedPathStreams.new(data, events),
    )
  end

  private def parents_from_manifest(bucket : Hash(String, JSON::Any), label : String) : Array(CrystalClick::ObjectSharedPhysicalParentMark)
    parents = [] of CrystalClick::ObjectSharedPhysicalParentMark
    array(field(bucket, "parents", label), "#{label}.parents").each_with_index do |parent_any, parent_index|
      parent = object(parent_any, "#{label} parent #{parent_index}")
      chunks = [] of CrystalClick::ObjectSharedPhysicalChunk
      array(field(parent, "chunks", "parent"), "parent chunks").each_with_index do |chunk_any, chunk_index|
        chunk = object(chunk_any, "#{label} chunk #{chunk_index}")
        paths = array(field(chunk, "paths", "chunk"), "chunk paths").map_with_index do |path_any, path_index|
          path_from_manifest(path_any, "#{label} chunk #{chunk_index} path #{path_index}")
        end
        chunks << CrystalClick::ObjectSharedPhysicalChunk.new(
          unsigned(field(chunk, "row_count", "chunk"), "chunk row count", Int32::MAX.to_i64).to_u64,
          paths,
        )
      end
      parents << CrystalClick::ObjectSharedPhysicalParentMark.new(
        unsigned(field(parent, "physical_rows", "parent"), "physical parent rows", Int32::MAX.to_i64).to_u64,
        chunks,
      )
    end
    parents
  end

  private def compare_decoded!(actual : Array(CrystalClick::ObjectSharedPhysicalParentMark), expected : Array(CrystalClick::ObjectSharedPhysicalParentMark), label : String) : Nil
    require!(actual.size == expected.size, "#{label}: decoded parent count differs")
    actual.each_with_index do |parent, parent_index|
      want_parent = expected[parent_index]
      require!(parent.physical_rows == want_parent.physical_rows && parent.chunk_count == want_parent.chunk_count,
        "#{label} parent #{parent_index}: physical rows/chunk count differs")
      parent.chunk_count.times do |chunk_index|
        chunk = parent.chunk_at(chunk_index)
        want_chunk = want_parent.chunk_at(chunk_index)
        require!(chunk.row_count == want_chunk.row_count && chunk.path_count == want_chunk.path_count,
          "#{label} parent #{parent_index} chunk #{chunk_index}: row/path count differs")
        chunk.path_count.times do |path_index|
          path = chunk.path_at(path_index)
          want_path = want_chunk.path_at(path_index)
          require!(path.name == want_path.name && path.streams.data == want_path.streams.data &&
                   path.streams.event_count == want_path.streams.event_count,
            "#{label} parent #{parent_index} chunk #{chunk_index} path #{path_index}: name/Data/tape size differs")
          path.streams.event_count.times do |event_index|
            event = path.streams.event_at(event_index)
            want_event = want_path.streams.event_at(event_index)
            require!(event.name == want_event.name && event.relative_offset == want_event.relative_offset,
              "#{label} parent #{parent_index} chunk #{chunk_index} path #{path_index} event #{event_index} differs")
          end
        end
      end
    end
  end

  private def make_output_directory(root : String, relative : String) : String
    path = File.join(root, relative)
    require!(!File.exists?(path) && !File.symlink?(path), "output directory already exists")
    Dir.mkdir(path, 0o700)
    require!(!File.symlink?(path) && File.realpath(path) == path, "output directory is symlinked or noncanonical")
    path
  end

  private def write_output_file(root : String, relative : String, bytes : Bytes) : String
    path = File.join(root, relative)
    require!(!File.exists?(path) && !File.symlink?(path), "output file already exists")
    File.open(path, "wb") { |io| io.write(bytes) }
    require!(File.file?(path) && !File.symlink?(path) && File.realpath(path).starts_with?(root + "/"),
      "output file escaped or was replaced")
    path
  end

  private def json_budget(codec : CrystalClick::BinaryCodecBudget) : JSON::Any
    values = Hash(String, JSON::Any).new
    values["node_count"] = json(codec.node_count)
    values["element_count"] = json(codec.element_count)
    values["wire_byte_count"] = json(codec.wire_byte_count)
    json(values)
  end

  private def json_budget(transport : CrystalClick::CompressedStreamBudget) : JSON::Any
    values = Hash(String, JSON::Any).new
    values["file_byte_count"] = json(transport.file_byte_count)
    values["record_count"] = json(transport.record_count)
    values["decoded_byte_count"] = json(transport.decoded_byte_count)
    values["result_byte_count"] = json(transport.result_byte_count)
    json(values)
  end

  private def snapshot_budgets(
    codec_read : CrystalClick::BinaryCodecBudget,
    codec_write : CrystalClick::BinaryCodecBudget,
    transport_read : CrystalClick::CompressedStreamBudget,
    transport_write : CrystalClick::CompressedStreamBudget,
  ) : JSON::Any
    values = Hash(String, JSON::Any).new
    values["codec_read"] = json_budget(codec_read)
    values["codec_write"] = json_budget(codec_write)
    values["transport_read"] = json_budget(transport_read)
    values["transport_write"] = json_budget(transport_write)
    json(values)
  end

  private def write_encoded_bucket(
    output_root : String,
    profile_id : String,
    bucket_id : Int32,
    parents : Array(CrystalClick::ObjectSharedPhysicalParentMark),
    codec_budget : CrystalClick::BinaryCodecBudget,
    transport_budget : CrystalClick::CompressedStreamBudget,
    read_codec_budget : CrystalClick::BinaryCodecBudget,
    read_transport_budget : CrystalClick::CompressedStreamBudget,
  ) : Array(JSON::Any)
    sets = [] of JSON::Any
    FRAME_BYTES.each do |frame_bytes|
      files = CrystalClick::ObjectSharedPhysicalBucketCodec.encode(
        expectation(profile_id).version,
        parents,
        codec_budget,
        transport_budget,
        frame_bytes,
      )
      frame_root = File.join(output_root, "frame_#{frame_bytes}")
      unless Dir.exists?(frame_root)
        make_output_directory(output_root, "frame_#{frame_bytes}")
      end
      require!(!File.symlink?(frame_root) && File.directory?(frame_root), "frame output directory is absent or symlinked")
      profile_root = File.join(output_root, "frame_#{frame_bytes}", profile_id)
      unless Dir.exists?(profile_root)
        require!(!File.symlink?(File.join(output_root, "frame_#{frame_bytes}")), "frame directory is symlinked")
        Dir.mkdir(profile_root, 0o700)
      end
      bucket_root = File.join(profile_root, "bucket_#{bucket_id}")
      require!(!File.exists?(bucket_root) && !File.symlink?(bucket_root), "bucket output directory already exists")
      Dir.mkdir(bucket_root, 0o700)
      lanes = [] of JSON::Any
      LANE_NAMES.each do |name|
        lane_files = files.lane(name)
        data = lane_files.data
        marks = lane_files.marks
        relative = "frame_#{frame_bytes}/#{profile_id}/bucket_#{bucket_id}"
        data_relative = "#{relative}/#{name}.bin"
        marks_relative = "#{relative}/#{name}.mrk2"
        write_output_file(output_root, data_relative, data)
        write_output_file(output_root, marks_relative, marks)
        triples = mark_triples(marks, "generated #{profile_id} #{name}")
        lane = Hash(String, JSON::Any).new
        lane["name"] = json(name)
        lane["data_file"] = json(data_relative)
        lane["marks_file"] = json(marks_relative)
        lane["data_bytes"] = json(data.size.to_i64)
        lane["marks_bytes"] = json(marks.size.to_i64)
        lane["data_sha256"] = json(sha256(data))
        lane["marks_sha256"] = json(sha256(marks))
        lane["mark_triples"] = json(triples.map do |triple|
          JSON::Any.new(triple.map { |part| JSON::Any.new(part.to_i64) })
        end)
        lanes << json(lane)
      end
      lane_inputs = Hash(String, CrystalClick::ObjectSharedPhysicalLaneInput).new
      LANE_NAMES.each do |name|
        lane_path = File.join(bucket_root, "#{name}.bin")
        marks_path = File.join(bucket_root, "#{name}.mrk2")
        lane_inputs[name] = CrystalClick::ObjectSharedPhysicalLaneInput.new(
          lane_path,
          marks_path,
          File.size(lane_path),
          File.size(marks_path),
        )
      end
      redecoded = CrystalClick::ObjectSharedPhysicalBucketCodec.decode(
        expectation(profile_id).version,
        CrystalClick::ObjectSharedPhysicalBucketLaneInputs.new(lane_inputs),
        PARENT_ROWS,
        read_codec_budget,
        read_transport_budget,
      )
      compare_decoded!(redecoded, parents, "generated frame_#{frame_bytes} #{profile_id} bucket #{bucket_id}")
      set = Hash(String, JSON::Any).new
      set["frame_bytes"] = json(frame_bytes)
      set["lanes"] = json(lanes)
      sets << json(set)
    end
    sets
  end

  private def run!(manifest_path : String, output_root_path : String) : JSON::Any
    manifest_path = File.realpath(manifest_path)
    manifest_bytes = load_bounded_file(manifest_path, MAX_MANIFEST_BYTES.to_i64, "manifest")
    manifest = object(JSON.parse(String.new(manifest_bytes)), "manifest")
    capture_root = validate_runtime_and_manifest!(manifest)
    output_root = checked_directory(output_root_path, "output root")
    require!(output_root.starts_with?("/private/tmp/") && File.dirname(output_root) == File.realpath("/private/tmp"),
      "output root must be a direct child of /private/tmp")
    require!(Dir.children(output_root).empty?, "output root must be empty")

    profiles = array(field(manifest, "profiles", "manifest"), "manifest.profiles")
    require!(profiles.size == PROFILE_IDS.size, "manifest profile count differs")
    observed_profile_ids = profiles.map_with_index do |profile_any, profile_index|
      profile = object(profile_any, "manifest profile #{profile_index}")
      string(field(profile, "profile_id", "profile"), "profile_id")
    end
    require!(observed_profile_ids == PROFILE_IDS, "manifest profile ID sequence differs")
    read_codec = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
    write_codec = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true)
    read_transport = CrystalClick::CompressedStreamBudget.read_default
    write_transport = CrystalClick::CompressedStreamBudget.write_default
    output_profiles = [] of JSON::Any
    profiles.each_with_index do |profile_any, profile_index|
      profile = object(profile_any, "manifest profile #{profile_index}")
      profile_id = string(field(profile, "profile_id", "profile"), "profile_id")
      expected = validate_profile!(profile, profile_id)
      bucket_output = [] of JSON::Any
      buckets = array(field(profile, "buckets", "profile"), "profile buckets")
      buckets.each_with_index do |bucket_any, bucket_index|
        bucket = object(bucket_any, "#{profile_id} bucket #{bucket_index}")
        lane_records = array(field(bucket, "lanes", "bucket"), "bucket lanes")
        lane_inputs = Hash(String, CrystalClick::ObjectSharedPhysicalLaneInput).new
        lane_records.each do |lane_any|
          lane = object(lane_any, "lane")
          name = string(field(lane, "name", "lane"), "lane.name")
          lane_inputs[name] = authenticate_lane!(capture_root, lane, profile_id, bucket_index.to_i32)
        end
        input_owner = CrystalClick::ObjectSharedPhysicalBucketLaneInputs.new(lane_inputs)
        decoded = CrystalClick::ObjectSharedPhysicalBucketCodec.decode(
          expected.version,
          input_owner,
          PARENT_ROWS,
          read_codec,
          read_transport,
        )
        expected_parents = parents_from_manifest(bucket, "#{profile_id} bucket #{bucket_index}")
        compare_decoded!(decoded, expected_parents, "#{profile_id} bucket #{bucket_index}")
        generated_sets = write_encoded_bucket(
          output_root,
          profile_id,
          bucket_index.to_i32,
          decoded,
          write_codec,
          write_transport,
          read_codec,
          read_transport,
        )
        result_bucket = Hash(String, JSON::Any).new
        result_bucket["bucket_id"] = json(bucket_index.to_i32)
        result_bucket["parent_rows"] = json(PARENT_ROWS.map { |row| JSON::Any.new(row.to_i64) })
        result_bucket["generated_sets"] = json(generated_sets)
        bucket_output << json(result_bucket)
      end
      result_profile = Hash(String, JSON::Any).new
      result_profile["profile_id"] = json(profile_id)
      result_profile["bucket_count"] = json(expected.buckets)
      result_profile["buckets"] = json(bucket_output)
      output_profiles << json(result_profile)
    end
    result = Hash(String, JSON::Any).new
    result["format"] = json(OUTPUT_FORMAT)
    result["profile_ids"] = json(PROFILE_IDS.map { |profile_id| JSON::Any.new(profile_id) })
    result["frame_bytes"] = json(FRAME_BYTES.map { |value| JSON::Any.new(value.to_i64) })
    result["source_decode_checked"] = json(true)
    result["generated_redecode_checked"] = json(true)
    result["profiles"] = json(output_profiles)
    result["budgets"] = snapshot_budgets(read_codec, write_codec, read_transport, write_transport)
    helper_output = json(result)
    write_output_file(output_root, HELPER_OUTPUT_NAME, helper_output.to_json.to_slice)
    helper_output
  end

  def main(args : Array(String)) : Int32
    unless args.size == 2
      STDERR.puts "usage: validate_object_shared_physical_w194.cr MANIFEST.json EMPTY_OUTPUT_ROOT"
      return 64
    end
    puts run!(args[0], args[1]).to_json
    0
  rescue ex : Exception
    STDERR.puts "W194 helper failed: #{ex.class}: #{ex.message}"
    1
  end
end

exit ValidateObjectSharedPhysicalW194.main(ARGV)
