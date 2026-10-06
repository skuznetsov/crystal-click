require "../src/crystal_click"
require "json"
require "set"

module CheckObjectSharedLowCardinalityW196
  extend self

  FORMAT              = "object_shared_low_cardinality_w196_inspection_v1"
  PARTS_FORMAT        = "object_shared_low_cardinality_w196_parts_helper_v1"
  PARTS_INPUT_FORMAT  = "object_shared_low_cardinality_w196_parts_input_v1"
  COLUMN              = "j"
  DYNAMIC_TYPE        = CrystalClick::BinaryDataType.dynamic(max_types: 1)
  UINT8_TYPE          = CrystalClick::BinaryDataType.primitive("UInt8")
  STRING_TYPE         = CrystalClick::BinaryDataType.primitive("String")
  LC_STRING_TYPE      = CrystalClick::BinaryDataType.low_cardinality(STRING_TYPE)
  LC_UINT8_TYPE       = CrystalClick::BinaryDataType.low_cardinality(UINT8_TYPE)
  ARRAY_LC_UINT8_TYPE = CrystalClick::BinaryDataType.array(LC_UINT8_TYPE)
  PROFILE_IDS         = [
    "v2_string0", "v2_string1", "v3_string0", "v3_string1",
  ] of String
  MARK_ROWS    = [2_u64, 2_u64, 2_u64, 2_u64] of UInt64
  OUTPUT_LIMIT = 64_i64 * 1024 * 1024

  def usage : NoReturn
    STDERR.puts "usage: check_object_shared_low_cardinality_w196 PART_DIRECTORY | INPUT.json OUTPUT_ROOT"
    exit 64
  end

  def run(args : Array(String)) : Nil
    case args.size
    when 1
      run_inspection(args[0])
    when 2
      run_paired_parts(args[0], args[1])
    else
      usage
    end
  end

  private def run_inspection(part_argument : String) : Nil
    part = File.expand_path(part_argument)
    metadata = CrystalClick::ObjectColumnPartMetadata.open(part, COLUMN)
    descriptor = CrystalClick::ObjectDocumentFileReader.inspect(
      part,
      COLUMN,
      {} of String => CrystalClick::BinaryDataType,
      metadata.ordinary_profile,
      CrystalClick::BinaryBulkProfile.single_stream,
      true,
    )

    object = descriptor.plan.structures.object
    unless object.shared_data_version >= 2_u64 && object.shared_data_version <= 3_u64
      raise CrystalClick::UnsupportedFormatError.new("inspection requires ADVANCED or CHUNKED Object shared data")
    end
    unless descriptor.row_count == 4_u64 && descriptor.mark_row_counts == [2_u64, 2_u64]
      raise CrystalClick::UnsupportedFormatError.new("inspection is limited to the retained four-row, two-mark witness")
    end

    physical = CrystalClick::ObjectDocumentPhysicalPlan.new(
      COLUMN,
      descriptor.plan,
      metadata.ordinary_profile,
      CrystalClick::BinaryBulkProfile.single_stream,
    )
    source = CrystalClick::PartStreamSource.new(part)
    codec_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
    transport_budget = CrystalClick::CompressedStreamBudget.new

    paths = [] of JSON::Any
    physical.shared_bucket_count.times do |bucket_index|
      lane_inputs = CrystalClick::ObjectSharedPhysicalBucketLaneInputs.new(
        CrystalClick::ObjectSharedPhysicalBucketLaneInputs::LANE_NAMES.each_with_object(
          Hash(String, CrystalClick::ObjectSharedPhysicalLaneInput).new
        ) do |lane, lanes|
          logical_name = physical.advanced_bucket_stream_name(bucket_index, lane)
          data_name = "#{CrystalClick::StreamName.hash(logical_name)}.bin"
          marks_name = "#{CrystalClick::StreamName.hash(logical_name)}.mrk2"
          lanes[lane] = source.physical_lane_input(data_name, marks_name)
        end,
      )
      parents = CrystalClick::ObjectSharedPhysicalBucketCodec.decode(
        object.shared_data_version.to_i,
        lane_inputs,
        descriptor.mark_row_counts,
        codec_budget,
        transport_budget,
        metadata.ordinary_profile,
      )

      parents.each_with_index do |parent, parent_index|
        parent.chunk_count.times do |chunk_index|
          chunk = parent.chunk_at(chunk_index)
          chunk.path_count.times do |path_index|
            path = chunk.path_at(path_index)
            streams = path.streams
            decoded = CrystalClick::ObjectSharedPathCodec.decode_with_structures_with_budget(
              streams.data,
              streams.events,
              chunk.row_count.to_i,
              DYNAMIC_TYPE,
              codec_budget,
              metadata.ordinary_profile,
            )
            root_structure = decoded.structures["root"]? ||
                             raise CrystalClick::CorruptPartError.new("Dynamic path root structure is missing")
            unless root_structure.type_count == 1
              raise CrystalClick::UnsupportedFormatError.new("inspection expects one ordinary LowCardinality Dynamic arm")
            end

            event_values = [] of JSON::Any
            streams.event_count.times do |event_index|
              event = streams.event_at(event_index)
              event_values << json_object({
                "name"   => json_string(event.name),
                "offset" => JSON::Any.new(event.relative_offset.to_i64),
              })
            end

            row_values = [] of JSON::Any
            decoded.rows.each do |row|
              row_values << dynamic_actual_json(row)
            end

            paths << json_object({
              "bucket_index"  => JSON::Any.new(bucket_index.to_i64),
              "parent_index"  => JSON::Any.new(parent_index.to_i64),
              "chunk_index"   => JSON::Any.new(chunk_index.to_i64),
              "row_count"     => JSON::Any.new(chunk.row_count.to_i64),
              "name"          => json_string(path.name),
              "dynamic_types" => JSON::Any.new(root_structure.types.map { |type| json_string(type.name) }),
              "events"        => JSON::Any.new(event_values),
              "data_hex"      => json_string(streams.data.hexstring.downcase),
              "values"        => JSON::Any.new(row_values),
            })
          end
        end
      end
    end

    puts json_object({
      "format"                  => json_string(FORMAT),
      "status"                  => json_string("observed"),
      "row_count"               => JSON::Any.new(descriptor.row_count.to_i64),
      "mark_row_counts"         => JSON::Any.new(descriptor.mark_row_counts.map { |rows| JSON::Any.new(rows.to_i64) }),
      "shared_data_version"     => JSON::Any.new(object.shared_data_version.to_i64),
      "bucket_count"            => JSON::Any.new(physical.shared_bucket_count.to_i64),
      "ordinary_string_profile" => json_string(metadata.ordinary_profile.with_size_stream? ? "with_size" : "single_stream"),
      "codec_work"              => json_object({
        "nodes"      => JSON::Any.new(codec_budget.node_count),
        "elements"   => JSON::Any.new(codec_budget.element_count),
        "wire_bytes" => JSON::Any.new(codec_budget.wire_byte_count),
      }),
      "transport_work" => json_object({
        "file_bytes"    => JSON::Any.new(transport_budget.file_byte_count),
        "records"       => JSON::Any.new(transport_budget.record_count),
        "decoded_bytes" => JSON::Any.new(transport_budget.decoded_byte_count),
        "result_bytes"  => JSON::Any.new(transport_budget.result_byte_count),
      }),
      "paths" => JSON::Any.new(paths),
    }).to_json
  rescue ex : Exception
    STDERR.puts "W196 Object shared LowCardinality inspector failed: #{ex.class}: #{ex.message}"
    exit 1
  end

  private def run_paired_parts(input_argument : String, output_argument : String) : Nil
    input_path = File.expand_path(input_argument)
    output_root = File.expand_path(output_argument)
    unless Dir.exists?(output_root) && !File.symlink?(output_root) && File.realpath(output_root) == output_root
      raise ArgumentError.new("W196 output root must be a canonical existing directory")
    end
    unless File.file?(input_path) && !File.symlink?(input_path) && input_path.starts_with?(output_root + File::SEPARATOR)
      raise ArgumentError.new("W196 helper input must be a plain file below output root")
    end
    input_size = File.size(input_path)
    if input_size > 1_i64 * 1024 * 1024
      raise ArgumentError.new("W196 helper input exceeds its bounded size")
    end

    input = JSON.parse(File.read(input_path))
    unless input.as_h.keys.sort == ["capture_root", "format", "profiles"] &&
           input["format"].as_s == PARTS_INPUT_FORMAT
      raise ArgumentError.new("W196 paired input format or fields differ")
    end
    capture_root = input["capture_root"].as_s
    unless Dir.exists?(capture_root) && !File.symlink?(capture_root) && File.realpath(capture_root) == capture_root
      raise ArgumentError.new("W196 capture root must be a canonical existing directory")
    end
    profiles = input["profiles"].as_a
    unless profiles.size == PROFILE_IDS.size && profiles.map { |profile| profile["id"].as_s } == PROFILE_IDS
      raise ArgumentError.new("W196 paired input profile roster differs from the four fixed witnesses")
    end

    destinations = Set(String).new
    profiles.each_with_index do |profile, index|
      unless profile.as_h.keys.sort == ["id", "library_part", "shared_version", "source_part", "string_version"]
        raise ArgumentError.new("W196 profile input fields differ")
      end
      id = PROFILE_IDS[index]
      version = id.starts_with?("v2_") ? 2 : 3
      string_version = id.ends_with?("string0") ? 0 : 1
      unless profile["shared_version"].as_i == version && profile["string_version"].as_i == string_version
        raise ArgumentError.new("W196 profile selector differs from its fixed id")
      end
      validate_source_part!(profile["source_part"].as_s, capture_root)
      library_part = File.expand_path(profile["library_part"].as_s)
      validate_library_destination!(library_part, output_root)
      if destinations.includes?(library_part)
        raise ArgumentError.new("W196 library destinations must be distinct")
      end
      destinations.add(library_part)
    end

    output_profiles = profiles.map do |profile|
      process_paired_profile(
        profile["id"].as_s,
        profile["source_part"].as_s,
        profile["library_part"].as_s,
        profile["shared_version"].as_i,
        profile["string_version"].as_i,
        output_root,
        capture_root,
      )
    end
    puts json_object({
      "format"   => json_string(PARTS_FORMAT),
      "profiles" => JSON::Any.new(output_profiles),
    }).to_json
  rescue ex : Exception
    STDERR.puts "W196 paired LowCardinality helper failed: #{ex.class}: #{ex.message}"
    exit 1
  end

  private def validate_source_part!(part_argument : String, capture_root : String) : Nil
    part = File.expand_path(part_argument)
    unless Dir.exists?(part) && !File.symlink?(part) && File.realpath(part) == part &&
           part.starts_with?(capture_root + File::SEPARATOR)
      raise ArgumentError.new("W196 source part is absent, noncanonical, symlinked, or outside capture root")
    end
  end

  private def validate_library_destination!(part : String, output_root : String) : Nil
    unless part.starts_with?(output_root + File::SEPARATOR) && !File.exists?(part) && !File.symlink?(part)
      raise ArgumentError.new("W196 library part destination must be a fresh descendant of output root")
    end
    parent = File.realpath(File.dirname(part))
    unless parent.starts_with?(output_root + File::SEPARATOR) || parent == output_root
      raise ArgumentError.new("W196 library part parent escapes output root")
    end
  end

  private def process_paired_profile(
    id : String,
    source_part_argument : String,
    library_part_argument : String,
    shared_version : Int32,
    string_version : Int32,
    output_root : String,
    capture_root : String,
  ) : JSON::Any
    source_part = File.expand_path(source_part_argument)
    library_part = File.expand_path(library_part_argument)
    validate_source_part!(source_part, capture_root)
    validate_library_destination!(library_part, output_root)

    source_reader = reader_record(source_part)
    source_table = table_record(source_part)
    source_path_observation = path_records(source_part, shared_version, string_version)
    codec_budget, transport_budget = write_library_advanced_part!(
      library_part,
      shared_version,
      string_version,
    )
    library_reader = reader_record(library_part)
    library_table = table_record(library_part)
    library_path_observation = path_records(library_part, shared_version, string_version)

    json_object({
      "id"              => json_string(id),
      "shared_version"  => JSON::Any.new(shared_version.to_i64),
      "string_version"  => JSON::Any.new(string_version.to_i64),
      "bucket_count"    => JSON::Any.new(2_i64),
      "row_count"       => JSON::Any.new(8_i64),
      "mark_row_counts" => JSON::Any.new(MARK_ROWS.map { |rows| JSON::Any.new(rows.to_i64) }),
      "source_part"     => json_string(source_part),
      "library_part"    => json_string(library_part),
      "source"          => json_object({
        "reader"         => json_object(source_reader),
        "table"          => json_object(source_table),
        "paths"          => JSON::Any.new(source_path_observation[0]),
        "chunk_schedule" => JSON::Any.new(source_path_observation[1]),
      }),
      "library" => json_object({
        "reader"         => json_object(library_reader),
        "table"          => json_object(library_table),
        "paths"          => JSON::Any.new(library_path_observation[0]),
        "chunk_schedule" => JSON::Any.new(library_path_observation[1]),
      }),
      "library_generation" => json_object({
        "codec_work" => json_object({
          "nodes"      => JSON::Any.new(codec_budget.node_count),
          "elements"   => JSON::Any.new(codec_budget.element_count),
          "wire_bytes" => JSON::Any.new(codec_budget.wire_byte_count),
        }),
        "transport_work" => json_object({
          "file_bytes"    => JSON::Any.new(transport_budget.file_byte_count),
          "records"       => JSON::Any.new(transport_budget.record_count),
          "decoded_bytes" => JSON::Any.new(transport_budget.decoded_byte_count),
          "result_bytes"  => JSON::Any.new(transport_budget.result_byte_count),
        }),
      }),
    })
  end

  private def object_schema : CrystalClick::ObjectDocumentSchema
    CrystalClick::ObjectDocumentSchema.new(
      {} of String => CrystalClick::BinaryDataType,
      max_dynamic_paths: 0,
      max_dynamic_types: 1,
    )
  end

  private def reader_record(part : String) : Hash(String, JSON::Any)
    reader = CrystalClick::ObjectColumnReader.open(part, COLUMN, object_schema)
    unless reader.row_count == 8_u64 && reader.mark_row_counts == MARK_ROWS
      raise CrystalClick::CorruptPartError.new("W196 Object reader grid differs from the fixed eight-row witness")
    end
    full = reader.read_marks(0, 4).flat_map { |mark| render_documents(mark) }
    middle = reader.read_marks(1, 2).flat_map { |mark| render_documents(mark) }
    zero = reader.read_marks(4, 0).flat_map { |mark| render_documents(mark) }
    {
      "full_rows"   => JSON::Any.new(full),
      "middle_rows" => JSON::Any.new(middle),
      "zero_rows"   => JSON::Any.new(zero),
    } of String => JSON::Any
  end

  private def table_record(part : String) : Hash(String, JSON::Any)
    {
      "full_rows"   => JSON::Any.new(table_rows(part, nil, 8)),
      "middle_rows" => JSON::Any.new(table_rows(part, 2_u64, 4)),
      "zero_rows"   => JSON::Any.new(table_rows(part, 8_u64, 2)),
    } of String => JSON::Any
  end

  private def table_rows(part : String, start : UInt64?, max_rows : Int) : Array(JSON::Any)
    table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", COLUMN])
    rows = [] of JSON::Any
    consume = ->(batch : CrystalClick::WidePartTableBatch) {
      batch.object_documents_for(COLUMN).each { |document| rows << render_document(document) }
      nil
    }
    if first = start
      table.scan_typed_window(first, max_rows: max_rows, &consume)
    else
      table.scan_typed(batch_rows: 2, &consume)
    end
    rows
  end

  private def render_documents(documents : Array(CrystalClick::ObjectDocument)) : Array(JSON::Any)
    documents.map { |document| render_document(document) }
  end

  private def render_document(document : CrystalClick::ObjectDocument) : JSON::Any
    fields = Hash(String, JSON::Any).new
    document.paths.each do |path|
      fields[path] = actual_payload_json(document.value_for(path))
    end
    json_object(fields)
  end

  private def write_library_advanced_part!(
    library_part : String,
    shared_version : Int32,
    string_version : Int32,
  ) : Tuple(CrystalClick::BinaryCodecBudget, CrystalClick::CompressedStreamBudget)
    schema = object_schema
    object = CrystalClick::ObjectStructure.new(
      [] of String,
      shared_data_version: shared_version.to_u64,
      bucket_count: 2_u64,
    )
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      object,
      {} of String => CrystalClick::DynamicStructure,
    )
    plan = CrystalClick::ObjectDocumentPlan.new(structures, {} of String => CrystalClick::BinaryDataType)
    profile = string_version == 0 ? CrystalClick::BinaryBulkProfile.single_stream : CrystalClick::BinaryBulkProfile.with_size_stream
    empty_documents = Array(Array(CrystalClick::ObjectDocument)).new(4) do
      [CrystalClick::ObjectDocument.new({} of String => CrystalClick::BinaryValue),
       CrystalClick::ObjectDocument.new({} of String => CrystalClick::BinaryValue)] of CrystalClick::ObjectDocument
    end
    keys = Slice(UInt64).new(8) { |index| (index + 1).to_u64 }
    CrystalClick::WidePartWriter.write_uint64_object_pair(
      library_part,
      "pk",
      keys,
      COLUMN,
      schema,
      plan,
      empty_documents,
      rows_per_mark: 2,
      profile: profile,
      shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
      frame_bytes: 4096,
    )

    codec_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::ObjectDocumentCodec::DEFAULT_LIMITS, true)
    transport_budget = CrystalClick::CompressedStreamBudget.write_default
    chunks_by_parent = encode_chunks_by_parent(shared_version, profile, codec_budget)
    physical_rows = MARK_ROWS
    copy_lanes = CrystalClick::ObjectSharedAdvancedCopyLayout.encode(
      chunks_by_parent,
      physical_rows,
      codec_budget,
      transport_budget,
      4096,
    )
    bucket_parents = Array(Array(CrystalClick::ObjectSharedPhysicalParentMark)).new(2) do
      [] of CrystalClick::ObjectSharedPhysicalParentMark
    end
    chunks_by_parent.each do |parent_chunks|
      2.times do |bucket_index|
        bucket_chunks = parent_chunks.map { |chunk| chunk.bucket_at(bucket_index) }
        bucket_parents[bucket_index] << CrystalClick::ObjectSharedPhysicalParentMark.new(2_u64, bucket_chunks)
      end
    end
    bucket_files = Array(CrystalClick::ObjectSharedPhysicalBucketFiles).new(2)
    2.times do |bucket_index|
      bucket_files << CrystalClick::ObjectSharedPhysicalBucketCodec.encode(
        shared_version,
        bucket_parents[bucket_index],
        codec_budget,
        transport_budget,
        4096,
        profile: profile,
      )
    end

    metadata = CrystalClick::ObjectColumnPartMetadata.open(library_part, COLUMN)
    unless metadata.ordinary_profile == profile
      raise CrystalClick::CorruptPartError.new("W196 base writer did not retain the selected ordinary String profile")
    end
    descriptor = CrystalClick::ObjectDocumentFileReader.inspect(
      library_part,
      COLUMN,
      schema.typed_paths,
      profile,
      CrystalClick::BinaryBulkProfile.single_stream,
      true,
    )
    unless descriptor.row_count == 8_u64 && descriptor.mark_row_counts == MARK_ROWS &&
           descriptor.plan.structures.object.shared_data_version == shared_version.to_u64 &&
           descriptor.plan.structures.object.bucket_count == 2_u64
      raise CrystalClick::CorruptPartError.new("W196 generated base part metadata differs from the fixed advanced profile")
    end
    physical = CrystalClick::ObjectDocumentPhysicalPlan.new(
      COLUMN,
      descriptor.plan,
      profile,
      CrystalClick::BinaryBulkProfile.single_stream,
    )
    pairs = Hash(String, CrystalClick::CompressedMarkFiles).new
    copy_lanes.each do |lane, files|
      pairs[physical.advanced_copy_stream_name(lane)] = files
    end
    bucket_files.each_with_index do |files, bucket_index|
      CrystalClick::ObjectSharedPhysicalBucketLaneInputs::LANE_NAMES.each do |lane|
        pairs[physical.advanced_bucket_stream_name(bucket_index, lane)] = files.lane(lane)
      end
    end
    unless pairs.size == 15
      raise CrystalClick::UnsupportedFormatError.new("W196 replacement roster is not exactly three Copy plus twelve bucket lanes")
    end
    replaced_names = write_advanced_pairs!(library_part, pairs)
    CrystalClick::WidePartWriter.w196_rebuild_checksums(library_part, replaced_names)
    {codec_budget, transport_budget}
  end

  private def encode_chunks_by_parent(
    version : Int32,
    profile : CrystalClick::BinaryBulkProfile,
    budget : CrystalClick::BinaryCodecBudget,
  ) : Array(Array(CrystalClick::ObjectSharedAdvancedChunk))
    rows = fixture_rows
    parents = Array(Array(CrystalClick::ObjectSharedAdvancedChunk)).new(4)
    4.times do |parent_index|
      parent_rows = Array(CrystalClick::ObjectSharedMapRow).new(2)
      2.times { |offset| parent_rows << rows[parent_index * 2 + offset] }
      chunks = Array(CrystalClick::ObjectSharedAdvancedChunk).new(version == 2 ? 1 : 2)
      if version == 2
        chunks << encode_one_chunk(parent_rows, profile, budget)
      else
        parent_rows.each do |row|
          chunks << encode_one_chunk([row] of CrystalClick::ObjectSharedMapRow, profile, budget)
        end
      end
      parents << chunks
    end
    parents
  end

  private def encode_one_chunk(
    rows : Array(CrystalClick::ObjectSharedMapRow),
    profile : CrystalClick::BinaryBulkProfile,
    budget : CrystalClick::BinaryCodecBudget,
  ) : CrystalClick::ObjectSharedAdvancedChunk
    grouped_names = Array(Array(String)).new(2) { [] of String }
    rows.each do |row|
      row.entry_count.times do |entry_index|
        entry = row.entry_at(entry_index)
        name = String.new(entry.path)
        bucket = CrystalClick::ObjectSharedBucketLayout.bucket_for(name, 2)
        names = grouped_names[bucket]
        names << name unless names.includes?(name)
      end
    end
    grouped_names.each do |names|
      names.sort! { |left, right| CrystalClick::ObjectSharedPhysicalPath.compare_names(left, right) }
    end

    structures = Array(CrystalClick::ObjectSharedChunkStructure).new(2)
    grouped_names.each do |names|
      structures << CrystalClick::ObjectSharedChunkStructure.new(
        rows.size.to_u64,
        names,
        {0_u64, 0_u64},
        {0_u64, 0_u64},
        {0_u64, 0_u64},
      )
    end
    copy = CrystalClick::ObjectSharedCopyCodec.encode_with_budget(rows, structures, budget)
    bucket_paths = Array(Array(CrystalClick::ObjectSharedPhysicalPath)).new(2) do
      [] of CrystalClick::ObjectSharedPhysicalPath
    end
    2.times do |bucket_index|
      grouped_names[bucket_index].each do |name|
        actual_type = actual_type_for_path(name)
        path_rows = Array(CrystalClick::BinaryValue).new(rows.size)
        rows.each do |row|
          if value = entry_value_for(row, name)
            path_rows << CrystalClick::BinaryValue.dynamic(DYNAMIC_TYPE, value)
          else
            path_rows << CrystalClick::BinaryValue.dynamic(DYNAMIC_TYPE)
          end
        end
        structures_by_site = {"root" => CrystalClick::DynamicStructure.new([actual_type] of CrystalClick::BinaryDataType)}
        streams = CrystalClick::ObjectSharedPathCodec.encode_with_budget(
          DYNAMIC_TYPE,
          structures_by_site,
          path_rows,
          budget,
          profile: profile,
        )
        bucket_paths[bucket_index] << CrystalClick::ObjectSharedPhysicalPath.new(name, streams)
      end
    end
    buckets = Array(CrystalClick::ObjectSharedPhysicalChunk).new(2)
    bucket_paths.each do |paths|
      buckets << CrystalClick::ObjectSharedPhysicalChunk.new(rows.size.to_u64, paths)
    end
    CrystalClick::ObjectSharedAdvancedChunk.new(rows.size.to_u64, copy, buckets)
  end

  private def fixture_rows : Array(CrystalClick::ObjectSharedMapRow)
    [
      map_row("red", [7_u8, 9_u8] of UInt8),
      map_row(nil, nil),
      map_row("", [] of UInt8),
      map_row("blue", [0_u8, 255_u8] of UInt8),
      map_row(nil, nil),
      map_row("red", [9_u8] of UInt8),
      map_row("blue", [] of UInt8),
      map_row("", [7_u8, 0_u8] of UInt8),
    ] of CrystalClick::ObjectSharedMapRow
  end

  private def map_row(path_value : String?, array_value : Array(UInt8)?) : CrystalClick::ObjectSharedMapRow
    values = Hash(String, CrystalClick::BinaryValue).new
    if value = path_value
      values["p"] = CrystalClick::BinaryValue.low_cardinality(
        LC_STRING_TYPE,
        CrystalClick::BinaryValue.string(value),
      )
    end
    if array = array_value
      children = array.map do |byte|
        CrystalClick::BinaryValue.low_cardinality(
          LC_UINT8_TYPE,
          CrystalClick::BinaryValue.fixed(UINT8_TYPE, Bytes[byte]),
        )
      end
      values["a"] = CrystalClick::BinaryValue.array(ARRAY_LC_UINT8_TYPE, children)
    end
    entries = values.keys.sort.map do |name|
      CrystalClick::ObjectSharedMapEntry.new(name.to_slice, values[name])
    end
    CrystalClick::ObjectSharedMapRow.new(entries)
  end

  private def entry_value_for(row : CrystalClick::ObjectSharedMapRow, name : String) : CrystalClick::BinaryValue?
    row.entry_count.times do |index|
      entry = row.entry_at(index)
      next unless entry.path_byte_size == name.bytesize
      matches = true
      name.bytesize.times do |byte_index|
        if entry.path_byte_at(byte_index) != name.to_slice[byte_index]
          matches = false
          break
        end
      end
      return entry.value if matches
    end
    nil
  end

  private def actual_type_for_path(name : String) : CrystalClick::BinaryDataType
    case name
    when "p" then LC_STRING_TYPE
    when "a" then ARRAY_LC_UINT8_TYPE
    else          raise CrystalClick::UnsupportedFormatError.new("W196 fixture contains an unexpected shared path")
    end
  end

  private def write_advanced_pairs!(part : String, pairs : Hash(String, CrystalClick::CompressedMarkFiles)) : Array(String)
    original = CrystalClick::PartChecksums.open(part)
    replaced = [] of String
    pairs.each do |logical_name, files|
      data_name = "#{CrystalClick::StreamName.hash(logical_name)}.bin"
      marks_name = "#{CrystalClick::StreamName.hash(logical_name)}.mrk2"
      unless original.entry(data_name) && original.entry(marks_name)
        raise CrystalClick::UnsupportedFormatError.new("W196 generated base part lacks an advanced replacement target")
      end
      [data_name, marks_name].each do |name|
        path = File.join(part, name)
        unless File.file?(path) && !File.symlink?(path)
          raise CrystalClick::UnsupportedFormatError.new("W196 advanced replacement target is missing or symlinked")
        end
        replaced << name
      end
      write_bytes(File.join(part, data_name), files.data)
      write_bytes(File.join(part, marks_name), files.marks)
    end
    replaced
  end

  private def write_bytes(path : String, bytes : Bytes) : Nil
    File.open(path, "wb") { |file| file.write(bytes) }
  end

  private def path_records(part : String, shared_version : Int32, string_version : Int32) : Tuple(Array(JSON::Any), Array(JSON::Any))
    metadata = CrystalClick::ObjectColumnPartMetadata.open(part, COLUMN)
    expected_profile = string_version == 0 ? CrystalClick::BinaryBulkProfile.single_stream : CrystalClick::BinaryBulkProfile.with_size_stream
    unless metadata.ordinary_profile == expected_profile
      raise CrystalClick::CorruptPartError.new("W196 part ordinary String profile differs from its fixed profile id")
    end
    descriptor = CrystalClick::ObjectDocumentFileReader.inspect(
      part,
      COLUMN,
      object_schema.typed_paths,
      metadata.ordinary_profile,
      CrystalClick::BinaryBulkProfile.single_stream,
      true,
    )
    object = descriptor.plan.structures.object
    unless descriptor.row_count == 8_u64 && descriptor.mark_row_counts == MARK_ROWS &&
           object.shared_data_version == shared_version.to_u64 && object.bucket_count == 2_u64
      raise CrystalClick::CorruptPartError.new("W196 path part profile differs from the requested witness")
    end
    physical = CrystalClick::ObjectDocumentPhysicalPlan.new(
      COLUMN,
      descriptor.plan,
      metadata.ordinary_profile,
      CrystalClick::BinaryBulkProfile.single_stream,
    )
    source = CrystalClick::PartStreamSource.new(part)
    codec_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::ObjectDocumentCodec::DEFAULT_LIMITS)
    transport_budget = CrystalClick::CompressedStreamBudget.new
    output = [] of JSON::Any
    chunk_schedule = [] of JSON::Any
    physical.shared_bucket_count.times do |bucket_index|
      lane_inputs = CrystalClick::ObjectSharedPhysicalBucketLaneInputs.new(
        CrystalClick::ObjectSharedPhysicalBucketLaneInputs::LANE_NAMES.each_with_object(
          Hash(String, CrystalClick::ObjectSharedPhysicalLaneInput).new
        ) do |lane, lanes|
          logical_name = physical.advanced_bucket_stream_name(bucket_index, lane)
          data_name = "#{CrystalClick::StreamName.hash(logical_name)}.bin"
          marks_name = "#{CrystalClick::StreamName.hash(logical_name)}.mrk2"
          lanes[lane] = source.physical_lane_input(data_name, marks_name)
        end,
      )
      parents = CrystalClick::ObjectSharedPhysicalBucketCodec.decode(
        shared_version,
        lane_inputs,
        descriptor.mark_row_counts,
        codec_budget,
        transport_budget,
        metadata.ordinary_profile,
      )
      parents.each_with_index do |parent, parent_index|
        parent.chunk_count.times do |chunk_index|
          chunk = parent.chunk_at(chunk_index)
          path_names = Array(JSON::Any).new(chunk.path_count)
          chunk.path_count.times do |path_index|
            path_names << json_string(chunk.path_at(path_index).name)
          end
          chunk_schedule << json_object({
            "bucket_index"     => JSON::Any.new(bucket_index.to_i64),
            "parent_index"     => JSON::Any.new(parent_index.to_i64),
            "parent_row_count" => JSON::Any.new(parent.physical_rows.to_i64),
            "chunk_index"      => JSON::Any.new(chunk_index.to_i64),
            "row_count"        => JSON::Any.new(chunk.row_count.to_i64),
            "path_names"       => JSON::Any.new(path_names),
          })
          chunk.path_count.times do |path_index|
            path = chunk.path_at(path_index)
            streams = path.streams
            decoded = CrystalClick::ObjectSharedPathCodec.decode_with_structures_with_budget(
              streams.data,
              streams.events,
              chunk.row_count.to_i,
              DYNAMIC_TYPE,
              codec_budget,
              metadata.ordinary_profile,
            )
            root_structure = decoded.structures["root"]? ||
                             raise CrystalClick::CorruptPartError.new("W196 Dynamic path root structure is missing")
            expected_type = actual_type_for_path(path.name)
            unless root_structure.type_count == 1 && root_structure.type_at(0) == expected_type
              raise CrystalClick::CorruptPartError.new("W196 path actual roster differs from its authored LowCardinality type")
            end
            events = [] of JSON::Any
            streams.event_count.times do |event_index|
              event = streams.event_at(event_index)
              events << json_object({
                "name"   => json_string(event.name),
                "offset" => JSON::Any.new(event.relative_offset.to_i64),
              })
            end
            values = decoded.rows.map { |row| dynamic_actual_json(row) }
            output << json_object({
              "bucket_index"  => JSON::Any.new(bucket_index.to_i64),
              "parent_index"  => JSON::Any.new(parent_index.to_i64),
              "chunk_index"   => JSON::Any.new(chunk_index.to_i64),
              "row_count"     => JSON::Any.new(chunk.row_count.to_i64),
              "name"          => json_string(path.name),
              "dynamic_types" => JSON::Any.new(root_structure.types.map { |type| json_string(type.name) }),
              "events"        => JSON::Any.new(events),
              "data_hex"      => json_string(streams.data.hexstring.downcase),
              "values"        => JSON::Any.new(values),
            })
          end
        end
      end
    end
    {output, chunk_schedule}
  end

  private def dynamic_actual_json(value : CrystalClick::BinaryValue) : JSON::Any
    unless value.type.tag == CrystalClick::BinaryDataType::TAG_DYNAMIC
      raise CrystalClick::CorruptPartError.new("per-path row is not a Dynamic value")
    end
    return JSON::Any.new(nil) if value.is_null?
    unless value.child_count == 1
      raise CrystalClick::CorruptPartError.new("non-NULL Dynamic row must have one selected actual")
    end
    actual = value.child_at(0)
    json_object({
      "type"  => json_string(actual.type.name),
      "value" => actual_payload_json(actual),
    })
  end

  private def actual_payload_json(value : CrystalClick::BinaryValue) : JSON::Any
    if value.type.tag == CrystalClick::BinaryDataType::TAG_LOW_CARDINALITY
      unless value.child_count == 1
        raise CrystalClick::CorruptPartError.new("LowCardinality row value must have one nested value")
      end
      return actual_payload_json(value.child_at(0))
    end
    if value.is_null?
      return JSON::Any.new(nil)
    end

    case value.type.tag
    when CrystalClick::BinaryDataType::TAG_ARRAY
      JSON::Any.new(value.elements.map { |child| actual_payload_json(child) })
    when CrystalClick::BinaryDataType::TAG_STRING
      json_string(value.as_string)
    when CrystalClick::BinaryDataType::TAG_UINT8
      JSON::Any.new(value.bytes[0].to_i64)
    else
      raise CrystalClick::UnsupportedFormatError.new("inspector does not render actual type #{value.type.name}")
    end
  end

  private def json_string(value : String) : JSON::Any
    JSON::Any.new(value)
  end

  private def json_object(value : Hash(String, JSON::Any)) : JSON::Any
    JSON::Any.new(value)
  end
end

module CrystalClick
  module WidePartWriter
    # This test-only bridge repairs checksums after replacing only the exact
    # advanced Copy and bucket lane pairs in a fresh scratch part. It keeps the
    # full ordinary part roster and recomputes hashes from the files on disk.
    def self.w196_rebuild_checksums(part : String, replaced_names : Array(String)) : Nil
      original = PartChecksums.open(part)
      records = [] of ChecksumRecord
      original.entries.keys.sort.each do |name|
        path = File.join(part, name)
        raise "W196 checksum input is missing or a symlink: #{name}" if File.symlink?(path) || !File.file?(path)
        physical_size = File.size(path)
        raise "W196 checksum input exceeds 64 MiB: #{name}" if physical_size > 64_i64 * 1024 * 1024
        physical_text = File.read(path)
        physical = Bytes.new(physical_text.bytesize) { |index| physical_text.to_slice[index] }
        entry = original.entry(name) || raise "W196 checksum entry disappeared: #{name}"
        if entry.compressed
          raw = if physical.empty?
                  unless name.ends_with?(".bin") &&
                         (entry.uncompressed_size == 0_u64 || replaced_names.includes?(name))
                    raise "W196 empty compressed input is not a declared empty .bin lane: #{name}"
                  end
                  Bytes.empty
                else
                  CompressedBlock.decode_all(
                    physical,
                    64_i64 * 1024 * 1024,
                    64_i64 * 1024 * 1024,
                    64_i64 * 1024 * 1024,
                  )
                end
          records << ChecksumRecord.new(
            name,
            physical.size.to_u64,
            CityHashV1.file_hash(physical),
            true,
            raw.size.to_u64,
            CityHashV1.file_hash(raw),
          )
        else
          records << ChecksumRecord.new(name, physical.size.to_u64, CityHashV1.file_hash(physical), false)
        end
      end
      PartChecksumsWriter.write(part, records)
      repaired = PartChecksums.open(part)
      unless repaired.entries.keys.sort == original.entries.keys.sort
        raise "W196 checksum repair changed the part file roster"
      end
      repaired.entries.each_key { |name| repaired.validate_selected_entries(part, name) }
      nil
    end
  end
end

CheckObjectSharedLowCardinalityW196.run(ARGV)
