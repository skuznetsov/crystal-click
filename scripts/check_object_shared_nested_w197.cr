require "../src/crystal_click"
require "json"

module CheckObjectSharedNestedW197
  extend self

  FORMAT         = "object_shared_nested_w197_data_oracle_v1"
  EVIDENCE_ROOT  = "/private/tmp/crystal-click-w197.AS5KKc/evidence"
  COLUMN         = "j"
  SHARED_VERSION = 3
  BUCKET_COUNT   = 2
  MARK_ROWS      = [2_u64, 1_u64] of UInt64
  STRING_PROFILE = CrystalClick::BinaryBulkProfile.with_size_stream
  DYNAMIC_TYPE   = CrystalClick::BinaryDataType.dynamic(max_types: 1)

  private struct DecodedRowWitness
    getter status : String
    getter type_name : String?
    getter body : JSON::Any

    def initialize(@status : String, @type_name : String?, @body : JSON::Any)
    end
  end

  def run(args : Array(String)) : Nil
    unless args.size == 2
      STDERR.puts "usage: check_object_shared_nested_w197 NESTED_PART_DIRECTORY ARRAY_TUPLE_PART_DIRECTORY"
      exit 64
    end

    validate_evidence_root!
    nested_part = validate_part_argument!(args[0])
    array_tuple_part = validate_part_argument!(args[1])
    if nested_part == array_tuple_part
      raise ArgumentError.new("W197 oracle requires two distinct stock parts")
    end

    output = [
      inspect_part("nested", nested_part, nested_type),
      inspect_part("array_tuple", array_tuple_part, array_tuple_type),
    ] of JSON::Any

    puts json_object({
      "format"        => json_string(FORMAT),
      "evidence_root" => json_string(EVIDENCE_ROOT),
      "cases"         => JSON::Any.new(output),
    }).to_json
  rescue ex : Exception
    STDERR.puts "W197 Nested path Data oracle failed: #{ex.class}: #{ex.message}"
    exit 1
  end

  private def inspect_part(label : String, part : String, expected_type : CrystalClick::BinaryDataType) : JSON::Any
    metadata = CrystalClick::ObjectColumnPartMetadata.open(part, COLUMN)
    unless metadata.source_declaration == "JSON(max_dynamic_types=1, max_dynamic_paths=0)"
      raise CrystalClick::UnsupportedFormatError.new("W197 #{label} part has a different Object declaration")
    end
    unless metadata.ordinary_profile == STRING_PROFILE
      raise CrystalClick::UnsupportedFormatError.new("W197 #{label} part is not the String1 profile")
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
    unless descriptor.row_count == 3_u64 && descriptor.mark_row_counts == MARK_ROWS &&
           object.shared_data_version == SHARED_VERSION.to_u64 && object.bucket_count == BUCKET_COUNT.to_u64
      raise CrystalClick::CorruptPartError.new("W197 #{label} part metadata differs from the stock three-row CHUNKED witness")
    end

    physical = CrystalClick::ObjectDocumentPhysicalPlan.new(
      COLUMN,
      descriptor.plan,
      metadata.ordinary_profile,
      CrystalClick::BinaryBulkProfile.single_stream,
    )
    unless physical.shared_bucket_count == BUCKET_COUNT
      raise CrystalClick::CorruptPartError.new("W197 #{label} physical bucket count differs from metadata")
    end

    source = CrystalClick::PartStreamSource.new(part)
    codec_read_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::ObjectDocumentCodec::DEFAULT_LIMITS)
    codec_write_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::ObjectDocumentCodec::DEFAULT_LIMITS, true)
    transport_budget = CrystalClick::CompressedStreamBudget.new

    data_touched = Array(Bool).new(descriptor.row_count.to_i, false)
    row_witnesses = Array(DecodedRowWitness?).new(descriptor.row_count.to_i, nil)
    scheduled_rows = Array(Bool).new(descriptor.row_count.to_i, false)
    path_bucket_missing_rows = Array(Bool).new(descriptor.row_count.to_i, false)
    target_bucket = CrystalClick::ObjectSharedBucketLayout.bucket_for("n", BUCKET_COUNT)
    canonical_schedule = nil.as(Array(Array(UInt64))?)
    path_records = [] of JSON::Any
    schedule_records = [] of JSON::Any

    BUCKET_COUNT.times do |bucket_index|
      lane_inputs = lane_inputs_for(source, physical, bucket_index)
      parents = CrystalClick::ObjectSharedPhysicalBucketCodec.decode(
        SHARED_VERSION,
        lane_inputs,
        descriptor.mark_row_counts,
        codec_read_budget,
        transport_budget,
        metadata.ordinary_profile,
      )
      unless parents.size == MARK_ROWS.size
        raise CrystalClick::CorruptPartError.new("W197 #{label} bucket parent count differs from the physical mark grid")
      end

      bucket_schedule = Array(Array(UInt64)).new(parents.size)
      physical_row_start = 0
      parents.each_with_index do |parent, parent_index|
        expected_parent_rows = MARK_ROWS[parent_index]
        unless parent.physical_rows == expected_parent_rows
          raise CrystalClick::CorruptPartError.new("W197 #{label} physical parent rows differ from the mark grid")
        end

        chunk_rows = [] of UInt64
        chunk_row_start = physical_row_start
        parent.chunk_count.times do |chunk_index|
          chunk = parent.chunk_at(chunk_index)
          chunk_rows << chunk.row_count
          if chunk.row_count > parent.physical_rows ||
             chunk_row_start > physical_row_start + parent.physical_rows.to_i
            raise CrystalClick::CorruptPartError.new("W197 #{label} logical chunk exceeds its physical parent")
          end
          chunk_end = chunk_row_start + chunk.row_count.to_i
          if chunk_end > physical_row_start + parent.physical_rows.to_i
            raise CrystalClick::CorruptPartError.new("W197 #{label} chunk schedule crosses its physical parent boundary")
          end

          path_names = Array(JSON::Any).new(chunk.path_count)
          chunk.path_count.times do |path_index|
            path_names << json_string(chunk.path_at(path_index).name)
          end
          schedule_records << json_object({
            "bucket_index"     => JSON::Any.new(bucket_index.to_i64),
            "parent_index"     => JSON::Any.new(parent_index.to_i64),
            "parent_row_count" => JSON::Any.new(parent.physical_rows.to_i64),
            "chunk_index"      => JSON::Any.new(chunk_index.to_i64),
            "row_start"        => JSON::Any.new(chunk_row_start.to_i64),
            "row_count"        => JSON::Any.new(chunk.row_count.to_i64),
            "path_names"       => JSON::Any.new(path_names),
          })

          if bucket_index == 0
            chunk.row_count.to_i.times do |offset|
              row_index = chunk_row_start + offset
              if row_index < 0 || row_index >= scheduled_rows.size || scheduled_rows[row_index]
                raise CrystalClick::CorruptPartError.new("W197 #{label} chunk schedule overlaps or escapes the row grid")
              end
              scheduled_rows[row_index] = true
            end
          end
          if bucket_index == target_bucket && chunk.path_count == 0
            chunk.row_count.to_i.times do |offset|
              row_index = chunk_row_start + offset
              if row_index >= 0 && row_index < path_bucket_missing_rows.size
                path_bucket_missing_rows[row_index] = true
              end
            end
          end

          chunk.path_count.times do |path_index|
            path = chunk.path_at(path_index)
            unless path.name == "n" && bucket_index == target_bucket
              raise CrystalClick::CorruptPartError.new("W197 #{label} bucket contains an unexpected Dynamic path")
            end

            streams = path.streams
            raw_data = streams.data
            raw_events = streams.events
            decoded = CrystalClick::ObjectSharedPathCodec.decode_with_structures_with_budget(
              raw_data,
              raw_events,
              chunk.row_count.to_i,
              DYNAMIC_TYPE,
              codec_read_budget,
              metadata.ordinary_profile,
            )
            decoded_structures = decoded.structures
            decoded_rows = decoded.rows
            root_structure = decoded_structures["root"]? ||
                             raise CrystalClick::CorruptPartError.new("W197 #{label} Dynamic path root structure is missing")
            unless decoded_structures.size == 1 && root_structure.type_count == 1 && root_structure.type_at(0) == expected_type
              raise CrystalClick::CorruptPartError.new("W197 #{label} stored Dynamic actual roster is not the exact nominal witness type")
            end
            unless decoded_rows.size == chunk.row_count.to_i
              raise CrystalClick::CorruptPartError.new("W197 #{label} decoded path rows differ from the logical chunk row count")
            end

            reencoded = CrystalClick::ObjectSharedPathCodec.encode_with_budget(
              DYNAMIC_TYPE,
              decoded_structures,
              decoded_rows,
              codec_write_budget,
              metadata.ordinary_profile,
            )
            data_equal = reencoded.data == raw_data
            events_equal = same_events?(reencoded.events, raw_events)
            unless data_equal && events_equal
              raise CrystalClick::CorruptPartError.new("W197 #{label} per-path Data does not re-encode byte-for-byte")
            end

            decoded_rows.each_with_index do |row, offset|
              row_index = chunk_row_start + offset
              if row_index < 0 || row_index >= data_touched.size || data_touched[row_index]
                raise CrystalClick::CorruptPartError.new("W197 #{label} Dynamic path rows overlap or escape the logical row grid")
              end
              data_touched[row_index] = true
              row_witnesses[row_index] = decode_row_witness(row, expected_type, row_index, label)
            end

            path_records << json_object({
              "bucket_index"           => JSON::Any.new(bucket_index.to_i64),
              "parent_index"           => JSON::Any.new(parent_index.to_i64),
              "chunk_index"            => JSON::Any.new(chunk_index.to_i64),
              "row_start"              => JSON::Any.new(chunk_row_start.to_i64),
              "row_count"              => JSON::Any.new(chunk.row_count.to_i64),
              "path"                   => json_string(path.name),
              "dynamic_types"          => JSON::Any.new(root_structure.types.map { |type| json_string(type.name) }),
              "data_hex"               => json_string(raw_data.hexstring.downcase),
              "events"                 => events_json(raw_events),
              "roundtrip_data_equal"   => JSON::Any.new(data_equal),
              "roundtrip_events_equal" => JSON::Any.new(events_equal),
              "rows"                   => JSON::Any.new(Array(JSON::Any).new(decoded_rows.size) do |offset|
                witness = row_witnesses[chunk_row_start + offset]? ||
                          raise CrystalClick::CorruptPartError.new("W197 row witness disappeared during output construction")
                row_witness_json(chunk_row_start + offset, witness)
              end),
            })
          end

          chunk_row_start = chunk_end
        end
        unless chunk_row_start == physical_row_start + parent.physical_rows.to_i
          raise CrystalClick::CorruptPartError.new("W197 #{label} logical chunk rows do not fill the physical parent")
        end
        bucket_schedule << chunk_rows
        physical_row_start += parent.physical_rows.to_i
      end
      unless physical_row_start == descriptor.row_count.to_i
        raise CrystalClick::CorruptPartError.new("W197 #{label} physical parent grid does not cover all rows")
      end

      if reference = canonical_schedule
        unless bucket_schedule == reference
          raise CrystalClick::CorruptPartError.new("W197 #{label} bucket chunk schedules disagree")
        end
      else
        canonical_schedule = bucket_schedule
      end
    end

    unless scheduled_rows.all? && data_touched[0] && !data_touched[1] && data_touched[2] && path_bucket_missing_rows[1]
      raise CrystalClick::CorruptPartError.new("W197 #{label} source does not preserve populated, missing-chunk, and empty-value rows")
    end
    unless row_witnesses[0].try(&.status) == "populated" &&
           row_witnesses[1].nil? && row_witnesses[2].try(&.status) == "empty"
      raise CrystalClick::CorruptPartError.new("W197 #{label} per-row Nested/Array(Tuple) bodies differ from the native literals")
    end

    row_bodies = Array(JSON::Any).new(row_witnesses.size) do |index|
      if witness = row_witnesses[index]?
        row_witness_json(index, witness)
      else
        json_object({
          "row"    => JSON::Any.new(index.to_i64),
          "status" => json_string("missing_path_chunk"),
          "type"   => JSON::Any.new(nil),
          "body"   => JSON::Any.new(nil),
        })
      end
    end

    json_object({
      "fixture"            => json_string(label),
      "part"               => json_string(part),
      "source_declaration" => json_string(metadata.source_declaration),
      "row_count"          => JSON::Any.new(descriptor.row_count.to_i64),
      "mark_row_counts"    => JSON::Any.new(descriptor.mark_row_counts.map { |count| JSON::Any.new(count.to_i64) }),
      "shared_version"     => JSON::Any.new(object.shared_data_version.to_i64),
      "bucket_count"       => JSON::Any.new(physical.shared_bucket_count.to_i64),
      "string_profile"     => json_string("with_size_stream"),
      "chunk_schedule"     => JSON::Any.new(schedule_records),
      "path_records"       => JSON::Any.new(path_records),
      "row_bodies"         => JSON::Any.new(row_bodies),
      "read_work"          => codec_work_json(codec_read_budget),
      "write_work"         => codec_work_json(codec_write_budget),
      "transport_work"     => transport_work_json(transport_budget),
    })
  end

  private def lane_inputs_for(
    source : CrystalClick::PartStreamSource,
    physical : CrystalClick::ObjectDocumentPhysicalPlan,
    bucket_index : Int,
  ) : CrystalClick::ObjectSharedPhysicalBucketLaneInputs
    lanes = Hash(String, CrystalClick::ObjectSharedPhysicalLaneInput).new
    CrystalClick::ObjectSharedPhysicalBucketLaneInputs::LANE_NAMES.each do |lane|
      logical_name = physical.advanced_bucket_stream_name(bucket_index, lane)
      data_name = "#{CrystalClick::StreamName.hash(logical_name)}.bin"
      marks_name = "#{CrystalClick::StreamName.hash(logical_name)}.mrk2"
      lanes[lane] = source.physical_lane_input(data_name, marks_name)
    end
    CrystalClick::ObjectSharedPhysicalBucketLaneInputs.new(lanes)
  end

  private def decode_row_witness(
    row : CrystalClick::BinaryValue,
    expected_type : CrystalClick::BinaryDataType,
    row_index : Int,
    label : String,
  ) : DecodedRowWitness
    unless row.type == DYNAMIC_TYPE
      raise CrystalClick::CorruptPartError.new("W197 #{label} decoded row lost its Dynamic descriptor")
    end
    if row.is_null?
      unless row_index == 1
        raise CrystalClick::CorruptPartError.new("W197 #{label} has an unexpected NULL Dynamic row")
      end
      return DecodedRowWitness.new("null", nil, JSON::Any.new(nil))
    end
    unless row.child_count == 1
      raise CrystalClick::CorruptPartError.new("W197 #{label} non-NULL Dynamic row does not select exactly one actual type")
    end

    actual = row.child_at(0)
    unless actual.type == expected_type
      raise CrystalClick::CorruptPartError.new("W197 #{label} value actual type differs from its nominal roster")
    end
    expected_elements = row_index == 0 ? 1 : row_index == 2 ? 0 : -1
    unless expected_elements >= 0 && actual.element_count == expected_elements
      raise CrystalClick::CorruptPartError.new("W197 #{label} actual value is neither the authored record nor the empty container")
    end

    body = if expected_elements == 0
             JSON::Any.new([] of JSON::Any)
           else
             record = actual.element_at(0)
             unless record.type == expected_type.child_at(0) && record.child_count == 2
               raise CrystalClick::CorruptPartError.new("W197 #{label} tuple record differs from its nominal fields")
             end
             number = record.child_at(0)
             text = record.child_at(1)
             unless number.type.tag == CrystalClick::BinaryDataType::TAG_UINT8 &&
                    number.byte_size == 1 && number.byte_at(0) == 7_u8 &&
                    text.type.tag == CrystalClick::BinaryDataType::TAG_STRING && text.as_string == "one"
               raise CrystalClick::CorruptPartError.new("W197 #{label} populated row is not the native literal (7, 'one')")
             end
             if expected_type.tag == CrystalClick::BinaryDataType::TAG_NESTED
               JSON::Any.new([json_object({"n" => JSON::Any.new(7_i64), "s" => json_string("one")})] of JSON::Any)
             else
               JSON::Any.new([JSON::Any.new([JSON::Any.new(7_i64), json_string("one")])] of JSON::Any)
             end
           end
    status = expected_elements == 0 ? "empty" : "populated"
    DecodedRowWitness.new(status, actual.type.name, body)
  end

  private def row_witness_json(row_index : Int, witness : DecodedRowWitness) : JSON::Any
    json_object({
      "row"    => JSON::Any.new(row_index.to_i64),
      "status" => json_string(witness.status),
      "type"   => witness.type_name ? json_string(witness.type_name.not_nil!) : JSON::Any.new(nil),
      "body"   => witness.body,
    })
  end

  private def events_json(events : Array(CrystalClick::ObjectSharedPathSubstreamEvent)) : JSON::Any
    JSON::Any.new(events.map do |event|
      json_object({
        "name"   => json_string(event.name),
        "offset" => JSON::Any.new(event.relative_offset.to_i64),
      })
    end)
  end

  private def same_events?(
    left : Array(CrystalClick::ObjectSharedPathSubstreamEvent),
    right : Array(CrystalClick::ObjectSharedPathSubstreamEvent),
  ) : Bool
    return false unless left.size == right.size
    left.each_with_index do |event, index|
      other = right[index]
      return false unless event.relative_offset == other.relative_offset && event.name == other.name
    end
    true
  end

  private def codec_work_json(budget : CrystalClick::BinaryCodecBudget) : JSON::Any
    json_object({
      "nodes"      => JSON::Any.new(budget.node_count),
      "elements"   => JSON::Any.new(budget.element_count),
      "wire_bytes" => JSON::Any.new(budget.wire_byte_count),
    })
  end

  private def transport_work_json(budget : CrystalClick::CompressedStreamBudget) : JSON::Any
    json_object({
      "file_bytes"    => JSON::Any.new(budget.file_byte_count),
      "records"       => JSON::Any.new(budget.record_count),
      "decoded_bytes" => JSON::Any.new(budget.decoded_byte_count),
      "result_bytes"  => JSON::Any.new(budget.result_byte_count),
    })
  end

  private def nested_type : CrystalClick::BinaryDataType
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    string = CrystalClick::BinaryDataType.primitive("String")
    CrystalClick::BinaryDataType.nested([uint8, string] of CrystalClick::BinaryDataType, ["n", "s"] of String)
  end

  private def array_tuple_type : CrystalClick::BinaryDataType
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    string = CrystalClick::BinaryDataType.primitive("String")
    tuple = CrystalClick::BinaryDataType.tuple([uint8, string] of CrystalClick::BinaryDataType, ["n", "s"] of String)
    CrystalClick::BinaryDataType.array(tuple)
  end

  private def validate_evidence_root! : Nil
    unless Dir.exists?(EVIDENCE_ROOT) && !File.symlink?(EVIDENCE_ROOT) && File.realpath(EVIDENCE_ROOT) == EVIDENCE_ROOT
      raise ArgumentError.new("W197 evidence root is absent, noncanonical, or symlinked")
    end
  end

  private def validate_part_argument!(argument : String) : String
    part = File.expand_path(argument)
    unless argument.starts_with?(File::SEPARATOR) && Dir.exists?(part) && !File.symlink?(part) && File.realpath(part) == part &&
           part.starts_with?(EVIDENCE_ROOT + File::SEPARATOR)
      raise ArgumentError.new("W197 source part must be an absolute directory below the retained evidence root")
    end
    part
  end

  private def json_string(value : String) : JSON::Any
    JSON::Any.new(value)
  end

  private def json_object(value : Hash(String, JSON::Any)) : JSON::Any
    JSON::Any.new(value)
  end
end

CheckObjectSharedNestedW197.run(ARGV)
