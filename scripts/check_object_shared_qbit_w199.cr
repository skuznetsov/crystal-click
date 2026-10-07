require "../src/crystal_click"
require "json"
require "set"

module CheckObjectSharedQBitW199
  extend self

  FORMAT                 = "object_shared_qbit_w199_input_v1"
  EXPECTED_PROFILE_COUNT = 48
  ROW_COUNT              =  4
  EXPECTED_ROWS          = [2_u64, 2_u64]
  CARRIERS               = ["Int8", "BFloat16", "Float32", "Float64"]
  SHAPES                 = [{"dim3", 3_i64, 3_i64, false}, {"dim9", 9_i64, 9_i64, false}, {"stride16_8", 16_i64, 8_i64, true}]
  COLUMN                 = "j"
  PATH                   = "q"

  private struct RowWitness
    getter status : String
    getter type_name : String?
    getter raw_hex : String?

    def initialize(@status : String, @type_name : String?, @raw_hex : String?)
    end
  end

  def run(args : Array(String)) : Nil
    unless args.size == 1
      STDERR.puts "usage: check_object_shared_qbit_w199 INPUT.json"
      exit 64
    end

    input_path = File.expand_path(args[0])
    raise ArgumentError.new("W199 input manifest must be a regular non-symlink file") unless File.file?(input_path) && !File.symlink?(input_path)
    input = JSON.parse(File.read(input_path))
    raise ArgumentError.new("W199 input manifest has an unexpected top-level shape") unless input.as_h.keys.sort == ["capture_root", "format", "profiles"]
    raise ArgumentError.new("W199 input manifest format mismatch") unless input["format"].as_s == FORMAT

    capture_root = canonical_root(input["capture_root"].as_s)
    profiles = input["profiles"].as_a
    raise ArgumentError.new("W199 manifest must contain exactly 48 profiles") unless profiles.size == EXPECTED_PROFILE_COUNT
    ids = Set(String).new
    output_profiles = profiles.map_with_index do |profile, index|
      inspect_profile(profile, capture_root, ids, index)
    end
    raise ArgumentError.new("W199 profile identifiers are duplicated") unless ids.size == EXPECTED_PROFILE_COUNT

    puts json_object({
      "format"        => json_string("object_shared_qbit_w199_helper_v1"),
      "capture_root"  => json_string(capture_root),
      "profile_count" => JSON::Any.new(output_profiles.size.to_i64),
      "profiles"      => JSON::Any.new(output_profiles),
    }).to_json
  rescue ex : Exception
    STDERR.puts "W199 QBit source part inspection failed: #{ex.class}: #{ex.message}"
    exit 1
  end

  private def inspect_profile(profile : JSON::Any, capture_root : String, ids : Set(String), profile_index : Int32) : JSON::Any
    expected_keys = ["bucket_count", "carrier", "dimension", "expected_rows", "explicit_stride", "id", "part", "shared_version", "stride", "string_profile", "type_name"]
    values = profile.as_h
    raise ArgumentError.new("W199 profile fields differ from the fixed schema") unless values.keys.sort == expected_keys
    expected = expected_profile(profile_index)
    id = values["id"].as_s
    raise ArgumentError.new("W199 profile roster/order differs from fixed 48-profile matrix") unless id == expected[:id]
    raise ArgumentError.new("W199 profile identifier is duplicated") unless ids.add?(id)
    part = canonical_part(values["part"].as_s, capture_root)
    carrier = values["carrier"].as_s
    dimension = positive_int(values["dimension"].as_i64, "dimension")
    stride = positive_int(values["stride"].as_i64, "stride")
    explicit_stride = values["explicit_stride"].as_bool
    shared_version = values["shared_version"].as_i64
    string_profile = values["string_profile"].as_i64
    bucket_count = values["bucket_count"].as_i64
    unless carrier == expected[:carrier] && dimension == expected[:dimension] && stride == expected[:stride] &&
           explicit_stride == expected[:explicit_stride] && shared_version == expected[:shared_version] &&
           string_profile == expected[:string_profile] && bucket_count == 2
      raise ArgumentError.new("W199 profile fields do not match the fixed 48-profile matrix")
    end

    qbit_type = if explicit_stride
                  CrystalClick::QBitType.new(carrier, dimension.to_u64, stride.to_u64)
                else
                  CrystalClick::QBitType.new(carrier, dimension.to_u64)
                end
    raise ArgumentError.new("W199 type name does not match the fixed nominal identity") unless qbit_type.type_name == expected[:type_name] && values["type_name"].as_s == expected[:type_name]
    expected_rows = parse_expected_rows(values["expected_rows"], qbit_type, id)

    metadata = CrystalClick::ObjectColumnPartMetadata.open(part, COLUMN)
    expected_profile = bulk_profile(string_profile)
    unless metadata.source_declaration == "JSON(max_dynamic_types=1, max_dynamic_paths=0)" && metadata.ordinary_profile == expected_profile
      raise CrystalClick::CorruptPartError.new("W199 #{id} source declaration or ordinary String profile differs from its manifest")
    end
    descriptor = CrystalClick::ObjectDocumentFileReader.inspect(
      part,
      COLUMN,
      {} of String => CrystalClick::BinaryDataType,
      metadata.ordinary_profile,
      CrystalClick::BinaryBulkProfile.single_stream,
      true,
    )
    object = descriptor.plan.structures.object
    unless descriptor.row_count == ROW_COUNT.to_u64 && descriptor.mark_row_counts == EXPECTED_ROWS &&
           object.shared_data_version == shared_version.to_u64 && object.bucket_count == bucket_count.to_u64
      raise CrystalClick::CorruptPartError.new("W199 #{id} source dimensions, mark grid, or persisted Object metadata differ")
    end

    physical = CrystalClick::ObjectDocumentPhysicalPlan.new(
      COLUMN,
      descriptor.plan,
      metadata.ordinary_profile,
      CrystalClick::BinaryBulkProfile.single_stream,
    )
    source = CrystalClick::PartStreamSource.new(part)
    codec_read_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::ObjectDocumentCodec::DEFAULT_LIMITS)
    codec_write_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::ObjectDocumentCodec::DEFAULT_LIMITS, true)
    transport_budget = CrystalClick::CompressedStreamBudget.new
    touched = Array(Bool).new(ROW_COUNT, false)
    witnesses = Array(RowWitness?).new(ROW_COUNT, nil)
    schedules = Array(JSON::Any).new
    path_records = Array(JSON::Any).new
    target_bucket = CrystalClick::ObjectSharedBucketLayout.bucket_for(PATH, bucket_count)
    canonical_schedule = nil.as(Array(Array(UInt64))?)

    bucket_count.times do |bucket_index|
      lane_inputs = lane_inputs_for(source, physical, bucket_index)
      parents = CrystalClick::ObjectSharedPhysicalBucketCodec.decode(
        shared_version.to_i,
        lane_inputs,
        descriptor.mark_row_counts,
        codec_read_budget,
        transport_budget,
        metadata.ordinary_profile,
      )
      raise CrystalClick::CorruptPartError.new("W199 #{id} bucket parent count differs from mark grid") unless parents.size == EXPECTED_ROWS.size
      schedule = Array(Array(UInt64)).new(parents.size)
      row_start = 0
      parents.each_with_index do |parent, parent_index|
        unless parent.physical_rows == EXPECTED_ROWS[parent_index]
          raise CrystalClick::CorruptPartError.new("W199 #{id} parent row count differs from the physical mark grid")
        end
        chunk_rows = [] of UInt64
        chunk_start = row_start
        parent.chunk_count.times do |chunk_index|
          chunk = parent.chunk_at(chunk_index)
          chunk_rows << chunk.row_count
          raise CrystalClick::CorruptPartError.new("W199 #{id} chunk crosses its physical parent") if chunk_start + chunk.row_count.to_i > row_start + parent.physical_rows.to_i
          names = chunk.path_count.times.map { |path_index| chunk.path_at(path_index).name }.to_a
          schedules << json_object({
            "bucket_index"     => JSON::Any.new(bucket_index.to_i64),
            "parent_index"     => JSON::Any.new(parent_index.to_i64),
            "parent_row_count" => JSON::Any.new(parent.physical_rows.to_i64),
            "chunk_index"      => JSON::Any.new(chunk_index.to_i64),
            "row_start"        => JSON::Any.new(chunk_start.to_i64),
            "row_count"        => JSON::Any.new(chunk.row_count.to_i64),
            "path_names"       => JSON::Any.new(names.map { |name| json_string(name) }),
          })

          chunk.path_count.times do |path_index|
            path = chunk.path_at(path_index)
            unless bucket_index == target_bucket && path.name == PATH
              raise CrystalClick::CorruptPartError.new("W199 #{id} contains an unexpected shared Dynamic path")
            end
            decoded = CrystalClick::ObjectSharedPathCodec.decode_with_structures_with_budget(
              path.streams.data,
              path.streams.events,
              chunk.row_count.to_i,
              CrystalClick::BinaryDataType.dynamic(max_types: 1),
              codec_read_budget,
              metadata.ordinary_profile,
            )
            structure = decoded.structures["root"]? || raise CrystalClick::CorruptPartError.new("W199 #{id} path root structure is absent")
            unless decoded.structures.size == 1 && structure.type_count == 1 && structure.type_at(0) == CrystalClick::BinaryDataType.qbit(qbit_type)
              raise CrystalClick::CorruptPartError.new("W199 #{id} path has a different persisted Dynamic roster")
            end
            unless decoded.rows.size == chunk.row_count.to_i
              raise CrystalClick::CorruptPartError.new("W199 #{id} decoded path rows differ from chunk row count")
            end

            reencoded = CrystalClick::ObjectSharedPathCodec.encode_with_budget(
              CrystalClick::BinaryDataType.dynamic(max_types: 1),
              decoded.structures,
              decoded.rows,
              codec_write_budget,
              metadata.ordinary_profile,
            )
            unless reencoded.data == path.streams.data && same_events?(reencoded.events, path.streams.events)
              raise CrystalClick::CorruptPartError.new("W199 #{id} path tape does not round-trip byte-for-byte")
            end

            decoded.rows.each_with_index do |row, offset|
              logical_index = chunk_start + offset
              raise CrystalClick::CorruptPartError.new("W199 #{id} decoded path rows overlap or escape root grid") if logical_index < 0 || logical_index >= touched.size || touched[logical_index]
              touched[logical_index] = true
              witnesses[logical_index] = decode_qbit_row(row, qbit_type, expected_rows[logical_index], id, logical_index)
            end

            path_records << json_object({
              "bucket_index"  => JSON::Any.new(bucket_index.to_i64),
              "parent_index"  => JSON::Any.new(parent_index.to_i64),
              "chunk_index"   => JSON::Any.new(chunk_index.to_i64),
              "row_start"     => JSON::Any.new(chunk_start.to_i64),
              "row_count"     => JSON::Any.new(chunk.row_count.to_i64),
              "path"          => json_string(path.name),
              "dynamic_types" => JSON::Any.new(structure.types.map { |type| json_string(type.name) }),
              "data_hex"      => json_string(path.streams.data.hexstring.downcase),
              "events"        => events_json(path.streams.events),
              "values"        => JSON::Any.new(decoded.rows.map_with_index do |row, offset|
                witness = witnesses[chunk_start + offset]? || raise CrystalClick::CorruptPartError.new("W199 #{id} row witness missing")
                row_witness_json(chunk_start + offset, witness)
              end),
            })
          end

          chunk_start += chunk.row_count.to_i
        end
        unless chunk_start == row_start + parent.physical_rows.to_i
          raise CrystalClick::CorruptPartError.new("W199 #{id} chunk schedule does not fill physical parent")
        end
        schedule << chunk_rows
        row_start += parent.physical_rows.to_i
      end
      raise CrystalClick::CorruptPartError.new("W199 #{id} parent schedule does not cover four rows") unless row_start == ROW_COUNT
      if existing = canonical_schedule
        raise CrystalClick::CorruptPartError.new("W199 #{id} bucket chunk schedules differ") unless existing == schedule
      else
        canonical_schedule = schedule
      end
    end

    expected_rows.each_with_index do |expected, index|
      if raw_hex = expected
        raise CrystalClick::CorruptPartError.new("W199 #{id} populated expected row lacks a path value") unless touched[index]
        witness = witnesses[index]? || raise CrystalClick::CorruptPartError.new("W199 #{id} populated QBit witness is absent")
        raise CrystalClick::CorruptPartError.new("W199 #{id} QBit bytes differ from independent literal row #{index + 1}") unless witness.raw_hex == raw_hex
      else
        raise CrystalClick::CorruptPartError.new("W199 #{id} pathless row materialized an unexpected value") if witnesses[index].try(&.raw_hex)
      end
    end

    json_object({
      "id"                 => json_string(id),
      "part"               => json_string(part),
      "type_name"          => json_string(qbit_type.type_name),
      "source_declaration" => json_string(metadata.source_declaration),
      "shared_version"     => JSON::Any.new(shared_version),
      "string_profile"     => JSON::Any.new(string_profile),
      "bucket_count"       => JSON::Any.new(bucket_count),
      "row_count"          => JSON::Any.new(descriptor.row_count.to_i64),
      "mark_row_counts"    => JSON::Any.new(descriptor.mark_row_counts.map { |count| JSON::Any.new(count.to_i64) }),
      "chunk_schedule"     => JSON::Any.new(schedules),
      "path_records"       => JSON::Any.new(path_records),
      "row_values"         => JSON::Any.new(witnesses.map_with_index { |witness, index| row_witness_json(index, witness) }),
      "read_work"          => codec_work_json(codec_read_budget),
      "write_work"         => codec_work_json(codec_write_budget),
      "transport_work"     => transport_work_json(transport_budget),
    })
  end

  private def expected_profile(index : Int32)
    raise ArgumentError.new("W199 profile index is outside fixed matrix") unless index >= 0 && index < EXPECTED_PROFILE_COUNT
    carrier = CARRIERS[index // 12]
    shape_name, dimension, stride, explicit_stride = SHAPES[(index // 4) % 3]
    shared_version = 2_i64 + ((index // 2) % 2)
    string_profile = (index % 2).to_i64
    type_name = if explicit_stride
                  "QBit(#{carrier}, #{dimension}, #{stride})"
                else
                  "QBit(#{carrier}, #{dimension})"
                end
    {
      id:              "#{carrier.downcase}_#{shape_name}_v#{shared_version}_s#{string_profile}",
      carrier:         carrier,
      dimension:       dimension,
      stride:          stride,
      explicit_stride: explicit_stride,
      shared_version:  shared_version,
      string_profile:  string_profile,
      type_name:       type_name,
    }
  end

  private def parse_expected_rows(rows : JSON::Any, type : CrystalClick::QBitType, id : String) : Array(String?)
    values = rows.as_a
    raise ArgumentError.new("W199 #{id} must contain four expected row values") unless values.size == 4
    values.map do |value|
      next nil if value.raw.nil?
      hex = value.as_s
      raise ArgumentError.new("W199 #{id} expected raw hex is malformed") unless hex.size == type.raw_row_bytes * 2 && hex.matches?(/\A[0-9a-f]+\z/)
      hex
    end
  end

  private def decode_qbit_row(
    row : CrystalClick::BinaryValue,
    qbit_type : CrystalClick::QBitType,
    expected_hex : String?,
    id : String,
    logical_index : Int,
  ) : RowWitness
    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    raise CrystalClick::CorruptPartError.new("W199 #{id} lost its Dynamic descriptor") unless row.type == dynamic_type
    if row.is_null?
      raise CrystalClick::CorruptPartError.new("W199 #{id} Dynamic NULL is only legal for pathless row 2") unless expected_hex.nil? && logical_index == 1
      return RowWitness.new("null", nil, nil)
    end
    raise CrystalClick::CorruptPartError.new("W199 #{id} non-NULL Dynamic must select exactly one actual") unless row.child_count == 1
    actual = row.child_at(0)
    expected_type = CrystalClick::BinaryDataType.qbit(qbit_type)
    raise CrystalClick::CorruptPartError.new("W199 #{id} actual type differs from QBit roster") unless actual.type == expected_type
    raw_hex = actual.qbit_value.raw_bytes.hexstring.downcase
    RowWitness.new("qbit", actual.type.name, raw_hex)
  end

  private def lane_inputs_for(
    source : CrystalClick::PartStreamSource,
    physical : CrystalClick::ObjectDocumentPhysicalPlan,
    bucket_index : Int,
  ) : CrystalClick::ObjectSharedPhysicalBucketLaneInputs
    lanes = Hash(String, CrystalClick::ObjectSharedPhysicalLaneInput).new
    CrystalClick::ObjectSharedPhysicalBucketLaneInputs::LANE_NAMES.each do |lane|
      logical_name = physical.advanced_bucket_stream_name(bucket_index, lane)
      lanes[lane] = source.physical_lane_input(
        "#{CrystalClick::StreamName.hash(logical_name)}.bin",
        "#{CrystalClick::StreamName.hash(logical_name)}.mrk2",
      )
    end
    CrystalClick::ObjectSharedPhysicalBucketLaneInputs.new(lanes)
  end

  private def same_events?(left : Array(CrystalClick::ObjectSharedPathSubstreamEvent), right : Array(CrystalClick::ObjectSharedPathSubstreamEvent)) : Bool
    return false unless left.size == right.size
    left.each_with_index do |event, index|
      return false unless event.name == right[index].name && event.relative_offset == right[index].relative_offset
    end
    true
  end

  private def events_json(events : Array(CrystalClick::ObjectSharedPathSubstreamEvent)) : JSON::Any
    JSON::Any.new(events.map do |event|
      json_object({"name" => json_string(event.name), "offset" => JSON::Any.new(event.relative_offset.to_i64)})
    end)
  end

  private def row_witness_json(index : Int, witness : RowWitness?) : JSON::Any
    if value = witness
      json_object({
        "row"       => JSON::Any.new((index + 1).to_i64),
        "status"    => json_string(value.status),
        "type_name" => value.type_name ? json_string(value.type_name.not_nil!) : JSON::Any.new(nil),
        "raw_hex"   => value.raw_hex ? json_string(value.raw_hex.not_nil!) : JSON::Any.new(nil),
      })
    else
      json_object({
        "row"       => JSON::Any.new((index + 1).to_i64),
        "status"    => json_string("pathless"),
        "type_name" => JSON::Any.new(nil),
        "raw_hex"   => JSON::Any.new(nil),
      })
    end
  end

  private def codec_work_json(budget : CrystalClick::BinaryCodecBudget) : JSON::Any
    json_object({"nodes" => JSON::Any.new(budget.node_count), "elements" => JSON::Any.new(budget.element_count), "wire_bytes" => JSON::Any.new(budget.wire_byte_count)})
  end

  private def transport_work_json(budget : CrystalClick::CompressedStreamBudget) : JSON::Any
    json_object({
      "file_bytes"    => JSON::Any.new(budget.file_byte_count),
      "records"       => JSON::Any.new(budget.record_count),
      "decoded_bytes" => JSON::Any.new(budget.decoded_byte_count),
      "result_bytes"  => JSON::Any.new(budget.result_byte_count),
    })
  end

  private def bulk_profile(version : Int64) : CrystalClick::BinaryBulkProfile
    case version
    when 0 then CrystalClick::BinaryBulkProfile.single_stream
    when 1 then CrystalClick::BinaryBulkProfile.with_size_stream
    else        raise ArgumentError.new("W199 String profile must be 0 or 1")
    end
  end

  private def canonical_root(path : String) : String
    expanded = File.expand_path(path)
    unless Dir.exists?(expanded) && !File.symlink?(expanded) && File.realpath(expanded) == expanded && expanded.starts_with?("/private/tmp/")
      raise ArgumentError.new("W199 capture root must be a canonical /private/tmp directory")
    end
    expanded
  end

  private def canonical_part(path : String, root : String) : String
    expanded = File.expand_path(path)
    unless Dir.exists?(expanded) && !File.symlink?(expanded) && File.realpath(expanded) == expanded && expanded.starts_with?(root + File::SEPARATOR)
      raise ArgumentError.new("W199 source part must be a canonical directory below capture root")
    end
    expanded
  end

  private def positive_int(value : Int64, label : String) : Int32
    raise ArgumentError.new("W199 #{label} must be a positive Int32") unless value > 0 && value <= Int32::MAX
    value.to_i32
  end

  private def json_string(value : String) : JSON::Any
    JSON::Any.new(value)
  end

  private def json_object(value : Hash(String, JSON::Any)) : JSON::Any
    JSON::Any.new(value)
  end
end

CheckObjectSharedQBitW199.run(ARGV)
