require "json"
require "../src/crystal_click"

module ValidateObjectSharedChunkStructureW191
  extend self

  MAX_INPUT_BYTES = 1_048_576
  MAX_RECORDS     = 65_536
  HEX_DIGITS      = "0123456789abcdef".to_slice

  alias MarkPair = Tuple(UInt64, UInt64)
  alias ChunkManifest = NamedTuple(
    rows: UInt64,
    paths: Array(String),
    data_marks: MarkPair,
    paths_marks: MarkPair,
    paths_substreams_metadata_marks: MarkPair,
    record_bytes_hex: String,
    prefix_bytes_hex: String,
    suffix_bytes_hex: String?,
  )
  alias BucketManifest = NamedTuple(id: String, chunks: Array(ChunkManifest))
  alias ProfileManifest = NamedTuple(id: String, status: String, buckets: Array(BucketManifest))
  alias SummaryManifest = NamedTuple(status: String?, profiles: Array(ProfileManifest))

  alias Entry = NamedTuple(
    profile_id: String,
    bucket_id: String,
    chunk_index: Int32,
    manifest: ChunkManifest,
    bytes: Bytes,
    prefix: Bytes,
  )

  def require!(condition : Bool, message : String) : Nil
    raise ArgumentError.new("W191 shared chunk helper: #{message}") unless condition
  end

  def nibble(byte : UInt8) : UInt8
    case byte
    when 48_u8..57_u8  then (byte - 48_u8).to_u8
    when 65_u8..70_u8  then (byte - 55_u8).to_u8
    when 97_u8..102_u8 then (byte - 87_u8).to_u8
    else                    raise ArgumentError.new("W191 shared chunk helper: malformed hex")
    end
  end

  def bytes_from_hex(hex : String) : Bytes
    source = hex.to_slice
    require!(source.size.even?, "hex field has odd length")
    bytes = Bytes.new(source.size // 2, 0_u8)
    bytes.size.times do |index|
      bytes[index] = (nibble(source[index * 2]) << 4) | nibble(source[index * 2 + 1])
    end
    bytes
  end

  def hex(bytes : Bytes) : String
    String.build do |io|
      bytes.each do |byte|
        io.write_byte(HEX_DIGITS[((byte >> 4) & 0x0f_u8).to_i])
        io.write_byte(HEX_DIGITS[(byte & 0x0f_u8).to_i])
      end
    end
  end

  def concatenate(parts : Array(Bytes)) : Bytes
    size = parts.sum(&.size)
    result = Bytes.new(size, 0_u8)
    offset = 0
    parts.each do |part|
      part.each do |byte|
        result[offset] = byte
        offset += 1
      end
    end
    result
  end

  def read_string(pull : JSON::PullParser, label : String) : String
    pull.read?(String) || raise ArgumentError.new("W191 shared chunk helper: #{label} is not a JSON string")
  end

  def read_uint64(pull : JSON::PullParser, label : String) : UInt64
    pull.read?(UInt64) || raise ArgumentError.new("W191 shared chunk helper: #{label} is not a UInt64 JSON integer")
  end

  def read_mark_pair(pull : JSON::PullParser, label : String) : MarkPair
    values = [] of UInt64
    pull.read_array do
      require!(values.size < 2, "#{label} has more than two coordinates")
      values << read_uint64(pull, "#{label}[#{values.size}]")
    end
    require!(values.size == 2, "#{label} is not a two-coordinate pair")
    {values[0], values[1]}
  end

  def read_strings(pull : JSON::PullParser, label : String) : Array(String)
    values = [] of String
    pull.read_array do
      require!(values.size < MAX_RECORDS, "#{label} exceeds #{MAX_RECORDS} entries")
      values << read_string(pull, "#{label}[#{values.size}]")
    end
    values
  end

  def read_transport_pairs(pull : JSON::PullParser) : Tuple(MarkPair, MarkPair, MarkPair)
    data_marks = nil.as(MarkPair?)
    paths_marks = nil.as(MarkPair?)
    paths_substreams_metadata_marks = nil.as(MarkPair?)
    pull.read_object do |key, _|
      case key
      when "data"
        require!(data_marks.nil?, "transport_pairs repeats data")
        data_marks = read_mark_pair(pull, "data transport marks")
      when "paths_marks"
        require!(paths_marks.nil?, "transport_pairs repeats paths_marks")
        paths_marks = read_mark_pair(pull, "paths transport marks")
      when "paths_substreams_metadata"
        require!(paths_substreams_metadata_marks.nil?, "transport_pairs repeats paths_substreams_metadata")
        paths_substreams_metadata_marks = read_mark_pair(pull, "path metadata transport marks")
      else
        pull.skip
      end
    end
    {
      data_marks || raise(ArgumentError.new("W191 shared chunk helper: transport_pairs lacks data")),
      paths_marks || raise(ArgumentError.new("W191 shared chunk helper: transport_pairs lacks paths_marks")),
      paths_substreams_metadata_marks || raise(ArgumentError.new("W191 shared chunk helper: transport_pairs lacks paths_substreams_metadata")),
    }
  end

  def read_chunk(pull : JSON::PullParser) : ChunkManifest
    rows = nil.as(UInt64?)
    paths = nil.as(Array(String)?)
    data_marks = nil.as(MarkPair?)
    paths_marks = nil.as(MarkPair?)
    paths_substreams_metadata_marks = nil.as(MarkPair?)
    record_bytes_hex = nil.as(String?)
    prefix_bytes_hex = nil.as(String?)
    suffix_bytes_hex = nil.as(String?)
    suffix_seen = false
    pull.read_object do |key, _|
      case key
      when "rows"
        require!(rows.nil?, "chunk repeats rows")
        rows = read_uint64(pull, "rows")
      when "paths"
        require!(paths.nil?, "chunk repeats paths")
        paths = read_strings(pull, "paths")
      when "transport_pairs"
        require!(data_marks.nil? && paths_marks.nil? && paths_substreams_metadata_marks.nil?, "chunk repeats transport_pairs")
        data_marks, paths_marks, paths_substreams_metadata_marks = read_transport_pairs(pull)
      when "record_bytes_hex"
        require!(record_bytes_hex.nil?, "chunk repeats record_bytes_hex")
        record_bytes_hex = read_string(pull, "record_bytes_hex")
      when "prefix_bytes_hex"
        require!(prefix_bytes_hex.nil?, "chunk repeats prefix_bytes_hex")
        prefix_bytes_hex = read_string(pull, "prefix_bytes_hex")
      when "suffix_bytes_hex"
        require!(!suffix_seen, "chunk repeats suffix_bytes_hex")
        suffix_seen = true
        suffix_bytes_hex = if pull.kind.null?
                             pull.read_null
                             nil
                           else
                             read_string(pull, "suffix_bytes_hex")
                           end
      else
        pull.skip
      end
    end
    {
      rows: rows || raise(ArgumentError.new("W191 shared chunk helper: chunk lacks rows")),
      paths: paths || raise(ArgumentError.new("W191 shared chunk helper: chunk lacks paths")),
      data_marks: data_marks || raise(ArgumentError.new("W191 shared chunk helper: chunk lacks transport_pairs.data")),
      paths_marks: paths_marks || raise(ArgumentError.new("W191 shared chunk helper: chunk lacks transport_pairs.paths_marks")),
      paths_substreams_metadata_marks: paths_substreams_metadata_marks || raise(ArgumentError.new("W191 shared chunk helper: chunk lacks path metadata transport marks")),
      record_bytes_hex: record_bytes_hex || raise(ArgumentError.new("W191 shared chunk helper: chunk lacks record_bytes_hex")),
      prefix_bytes_hex: prefix_bytes_hex || raise(ArgumentError.new("W191 shared chunk helper: chunk lacks prefix_bytes_hex")),
      suffix_bytes_hex: suffix_bytes_hex,
    }
  end

  def read_bucket(pull : JSON::PullParser, bucket_id : String) : BucketManifest
    chunks = nil.as(Array(ChunkManifest)?)
    pull.read_object do |key, _|
      if key == "chunks"
        require!(chunks.nil?, "bucket #{bucket_id} repeats chunks")
        chunks = [] of ChunkManifest
        pull.read_array do
          require!(chunks.not_nil!.size < MAX_RECORDS, "bucket #{bucket_id} exceeds #{MAX_RECORDS} chunks")
          chunks.not_nil! << read_chunk(pull)
        end
      else
        pull.skip
      end
    end
    {id: bucket_id, chunks: chunks || raise(ArgumentError.new("W191 shared chunk helper: bucket #{bucket_id} lacks chunks"))}
  end

  def read_buckets(pull : JSON::PullParser) : Array(BucketManifest)
    buckets = [] of BucketManifest
    pull.read_object do |bucket_id, _|
      require!(buckets.size < MAX_RECORDS, "bucket count exceeds #{MAX_RECORDS}")
      buckets << read_bucket(pull, bucket_id)
    end
    buckets
  end

  def read_chunk_layout(pull : JSON::PullParser) : Array(BucketManifest)
    buckets = nil.as(Array(BucketManifest)?)
    pull.read_object do |key, _|
      if key == "buckets"
        require!(buckets.nil?, "chunk_layout repeats buckets")
        buckets = read_buckets(pull)
      else
        pull.skip
      end
    end
    buckets || [] of BucketManifest
  end

  def read_physical_layout(pull : JSON::PullParser) : Array(BucketManifest)
    buckets = [] of BucketManifest
    chunk_layout_seen = false
    pull.read_object do |key, _|
      if key == "chunk_layout"
        require!(!chunk_layout_seen, "physical_layout repeats chunk_layout")
        chunk_layout_seen = true
        buckets = read_chunk_layout(pull)
      else
        pull.skip
      end
    end
    buckets
  end

  def read_profile(pull : JSON::PullParser) : ProfileManifest
    id = nil.as(String?)
    status = nil.as(String?)
    buckets = nil.as(Array(BucketManifest)?)
    pull.read_object do |key, _|
      case key
      when "id"
        require!(id.nil?, "profile repeats id")
        id = read_string(pull, "profile id")
      when "status"
        require!(status.nil?, "profile repeats status")
        status = read_string(pull, "profile status")
      when "physical_layout"
        require!(buckets.nil?, "profile repeats physical_layout")
        buckets = read_physical_layout(pull)
      else
        pull.skip
      end
    end
    {
      id: id || raise(ArgumentError.new("W191 shared chunk helper: profile lacks id")),
      status: status || raise(ArgumentError.new("W191 shared chunk helper: profile lacks status")),
      buckets: buckets || raise(ArgumentError.new("W191 shared chunk helper: profile lacks physical_layout")),
    }
  end

  def read_summary(pull : JSON::PullParser) : SummaryManifest
    status = nil.as(String?)
    profiles = nil.as(Array(ProfileManifest)?)
    pull.read_object do |key, _|
      case key
      when "status"
        require!(status.nil?, "summary repeats status")
        status = read_string(pull, "summary status")
      when "profiles"
        require!(profiles.nil?, "summary repeats profiles")
        profiles = [] of ProfileManifest
        pull.read_array do
          require!(profiles.not_nil!.size < MAX_RECORDS, "profile count exceeds #{MAX_RECORDS}")
          profiles.not_nil! << read_profile(pull)
        end
      else
        pull.skip
      end
    end
    {status: status, profiles: profiles || raise(ArgumentError.new("W191 shared chunk helper: summary lacks profiles"))}
  end

  def parse_summary(input : String) : SummaryManifest
    pull = JSON::PullParser.new(input)
    summary = read_summary(pull)
    require!(pull.kind.eof?, "summary has trailing data")
    summary
  end

  def equal_bytes?(left : Bytes, right : Bytes) : Bool
    return false unless left.size == right.size
    left.size.times.all? { |index| left[index] == right[index] }
  end

  def entries_for(profile : ProfileManifest) : Array(Entry)
    profile_id = profile[:id]
    buckets = profile[:buckets].dup
    buckets.sort_by! do |item|
      bucket = item[:id]
      require!(!bucket.empty? && bucket.each_byte.all? { |byte| byte.in?(48_u8..57_u8) },
        "#{profile_id} has a nonnumeric bucket id")
      bucket.to_u64
    end

    result = [] of Entry
    buckets.each do |bucket|
      bucket_id = bucket[:id]
      bucket[:chunks].each_with_index do |chunk, chunk_index|
        record_bytes = bytes_from_hex(chunk[:record_bytes_hex])
        prefix_bytes = bytes_from_hex(chunk[:prefix_bytes_hex])
        require!(record_bytes.size >= 48, "#{profile_id} bucket #{bucket_id} record lacks its fixed suffix")
        prefix_size = record_bytes.size - 48
        require!(prefix_size == prefix_bytes.size, "#{profile_id} bucket #{bucket_id} prefix extent differs")
        require!(equal_bytes?(record_bytes[0, prefix_size], prefix_bytes),
          "#{profile_id} bucket #{bucket_id} prefix bytes differ from record bytes")
        if suffix_hex = chunk[:suffix_bytes_hex]
          suffix_bytes = bytes_from_hex(suffix_hex)
          require!(suffix_bytes.size == 48 && equal_bytes?(record_bytes[prefix_size, 48], suffix_bytes),
            "#{profile_id} bucket #{bucket_id} suffix bytes differ from record bytes")
        end
        result << {
          profile_id: profile_id,
          bucket_id: bucket_id,
          chunk_index: chunk_index.to_i32,
          manifest: chunk,
          bytes: record_bytes,
          prefix: prefix_bytes,
        }
        require!(result.size <= MAX_RECORDS, "record count exceeds #{MAX_RECORDS}")
      end
    end
    result
  end

  def validate_manifest_fields!(entry : Entry, record : CrystalClick::ObjectSharedChunkStructure) : Nil
    chunk = entry[:manifest]
    require!(record.row_count == chunk[:rows],
      "#{entry[:profile_id]} bucket #{entry[:bucket_id]} chunk #{entry[:chunk_index]} row count differs")
    require!(record.paths == chunk[:paths],
      "#{entry[:profile_id]} bucket #{entry[:bucket_id]} chunk #{entry[:chunk_index]} ordered paths differ")

    require!(record.data_marks == chunk[:data_marks], "data mark pair differs")
    require!(record.paths_marks == chunk[:paths_marks], "paths mark pair differs")
    require!(record.paths_substreams_metadata_marks == chunk[:paths_substreams_metadata_marks], "path metadata mark pair differs")
  end

  def emit(
    profile_ids : Array(String),
    empty_profile_ids : Array(String),
    entries : Array(Entry),
    records : Array(CrystalClick::ObjectSharedChunkStructure),
    encoded : Bytes,
    encoded_ranges : Array(Tuple(Int32, Int32)),
  ) : String
    JSON.build do |json|
      json.object do
        json.field "profile_ids" do
          json.array do
            profile_ids.each { |profile_id| json.string(profile_id) }
          end
        end
        json.field "profiles_without_records" do
          json.array do
            empty_profile_ids.each { |profile_id| json.string(profile_id) }
          end
        end
        json.field "record_count", entries.size
        json.field "records" do
          json.array do
            entries.each_with_index do |entry, index|
              record = records[index]
              start, size = encoded_ranges[index]
              encoded_record = encoded[start, size]
              json.object do
                json.field "profile_id", entry[:profile_id]
                json.field "bucket_id", entry[:bucket_id]
                json.field "chunk_index", entry[:chunk_index]
                # Decimal strings preserve all UInt64 values in JSON clients.
                json.field "row_count", record.row_count.to_s
                json.field "paths" do
                  json.array { record.paths.each { |path| json.string(path) } }
                end
                json.field "transport_pairs" do
                  json.object do
                    json.field "data" do
                      json.array do
                        record.data_marks.each { |coordinate| json.string(coordinate.to_s) }
                      end
                    end
                    json.field "paths_marks" do
                      json.array do
                        record.paths_marks.each { |coordinate| json.string(coordinate.to_s) }
                      end
                    end
                    json.field "paths_substreams_metadata" do
                      json.array do
                        record.paths_substreams_metadata_marks.each { |coordinate| json.string(coordinate.to_s) }
                      end
                    end
                  end
                end
                json.field "record_bytes_hex", hex(entry[:bytes])
                json.field "reencoded_hex", hex(encoded_record)
              end
            end
          end
        end
      end
    end
  end

  def run(argv : Array(String)) : Nil
    require!(argv.size.in?(1..2), "usage: crystal scripts/validate_object_shared_chunk_structure_w191.cr SUMMARY.json [PROFILE_ID]")
    path = File.expand_path(argv[0])
    require!(File.file?(path) && !File.symlink?(path), "summary must be a plain file")
    input_size = File.size(path)
    require!(input_size <= MAX_INPUT_BYTES, "summary exceeds #{MAX_INPUT_BYTES} bytes")
    summary = parse_summary(File.read(path))
    all_profiles = summary[:profiles]
    selected_id = argv[1]?
    profiles = if selected_id
                 selected = all_profiles.find { |item| item[:id] == selected_id } ||
                   raise ArgumentError.new("W191 shared chunk helper: requested profile is absent")
                 [selected]
               else
                 require!(summary[:status] == "all_stock_profiles_observed",
                   "all-profile mode requires a complete stock capture")
                 all_profiles
               end
    require!(!profiles.empty?, "capture has no profiles")

    entries = [] of Entry
    profile_ids = [] of String
    empty_profile_ids = [] of String
    profiles.each do |profile|
      profile_id = profile[:id]
      require!(profile[:status] == "stock_profile_observed", "#{profile_id} is not a successful profile")
      current = entries_for(profile)
      profile_ids << profile_id
      if current.empty?
        require!(selected_id.nil?, "#{profile_id} has no actual structure records")
        empty_profile_ids << profile_id
        next
      end
      entries.concat(current)
      require!(entries.size <= MAX_RECORDS, "record count exceeds #{MAX_RECORDS}")
    end
    require!(!entries.empty?, "no structure records were selected")

    wire_parts = entries.map(&.[:bytes])
    input = concatenate(wire_parts)
    require!(input.size <= MAX_INPUT_BYTES, "concatenated records exceed #{MAX_INPUT_BYTES} bytes")
    limits = CrystalClick::BinaryCodecLimits.new(64, 100_000, 1_000_000, MAX_INPUT_BYTES)
    read_budget = CrystalClick::BinaryCodecBudget.new(limits)
    reader = CrystalClick::BinaryCodecContext.new(limits, input, false, read_budget)
    records = [] of CrystalClick::ObjectSharedChunkStructure
    entries.each do |entry|
      start = reader.input_offset
      record = CrystalClick::ObjectSharedChunkStructureCodec.read_from(reader)
      consumed = reader.input_offset - start
      require!(consumed == entry[:bytes].size, "record extent differs from captured structure bytes")
      validate_manifest_fields!(entry, record)
      records << record
    end
    reader.ensure_consumed

    write_budget = CrystalClick::BinaryCodecBudget.new(limits, true)
    writer = CrystalClick::BinaryCodecContext.new(limits, nil, true, write_budget)
    encoded_ranges = [] of Tuple(Int32, Int32)
    entries.zip(records).each do |entry, record|
      start = writer.output_size
      CrystalClick::ObjectSharedChunkStructureCodec.write_to(record, writer)
      size = writer.output_size - start
      encoded_ranges << {start, size}
    end
    encoded = writer.finish_bytes
    entries.zip(encoded_ranges).each do |entry, range|
      start, size = range
      reencoded_record = encoded[start, size]
      require!(equal_bytes?(entry[:bytes], reencoded_record),
        "#{entry[:profile_id]} bucket #{entry[:bucket_id]} chunk #{entry[:chunk_index]} is not canonically re-encoded")
    end

    puts emit(profile_ids, empty_profile_ids, entries, records, encoded, encoded_ranges)
  end
end

begin
  ValidateObjectSharedChunkStructureW191.run(ARGV)
rescue ex : Exception
  STDERR.puts ex.message || ex.class.name
  exit 1
end
