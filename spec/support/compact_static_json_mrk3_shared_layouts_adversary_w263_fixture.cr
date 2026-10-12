require "file_utils"
require "../../scripts/support/compact_json_w263_fixture"
require "./compact_static_json_mrk3_shared_layouts_w263_fixture"
require "./compact_static_json_mrk3_null_w263_fixture"

module CompactStaticJsonMrk3SharedLayoutsAdversaryW263Fixture
  extend self

  ROOT_LABELS = [
    {"obj_v3_dyn_v3_map_with_buckets_mrk3_s0_variant_basic", 1_u64},
    {"obj_v3_dyn_v3_advanced_mrk3_s0_variant_basic", 2_u64},
    {"obj_v3_dyn_v3_advanced_chunked_mrk3_s0_variant_basic", 3_u64},
  ]
  ROWS                = [2_u64, 2_u64, 2_u64, 2_u64]
  OBJECT_PREFIX_SIZES = [40, 24, 24, 24]
  POISONED_STRING     = "overflow-7"

  def source_part(label : String) : NamedTuple(path: String, inventory: Array(Tuple(String, Int64, String)))
    source = CompactStaticJsonMrk3SharedLayoutsW263Fixture.source_part(
      CompactStaticJsonMrk3SharedLayoutsW263Fixture.evidence_root,
      label,
    )
    CompactStaticJsonMrk3SharedLayoutsW263Fixture.assert_native_inventory!(source)
    source
  end

  def copy_part(source_path : String) : Tuple(String, String)
    temporary_root = File.tempname("crystal-click-w263-mrk3-shared-adversary-")
    Dir.mkdir(temporary_root, 0o700)
    copied_part = File.join(temporary_root, File.basename(source_path))
    FileUtils.cp_r(source_path, copied_part)
    {temporary_root, copied_part}
  end

  # Change only the final mark's valid shared-data version. The new prefix is
  # still a complete Object V3 header; rejection must come from the reader's
  # cross-mark schedule check, not a fabricated invalid version byte.
  def poison_late_object_version!(part_path : String, expected_version : UInt64, replacement : UInt64) : Nil
    unless {1_u64, 2_u64, 3_u64}.includes?(expected_version) &&
           {1_u64, 2_u64, 3_u64}.includes?(replacement) &&
           expected_version != replacement
      raise ArgumentError.new("W263 Object-version mutation must select two distinct admitted shared versions")
    end
    physical = checked_physical(part_path)
    original = root_mark(physical, 3)
    structure, _statistics_offset = parse_object_prefix(original, 3)
    structure.shared_data_version.should eq(expected_version)
    structure.bucket_count.should eq(2_u64)
    structure.dynamic_paths.should eq(["note", "sample"])
    structure.statistics.should be_nil

    original.byte_at(21).should eq(expected_version.to_u8)
    original.byte_at(22).should eq(2_u8)
    original.byte_at(23).should eq(0_u8)
    logical_start, tape_size = mutate_root_byte!(part_path, 3, 21, expected_version.to_u8, replacement.to_u8)

    reopened = checked_physical(part_path)
    changed = root_mark(reopened, 3)
    changed.logical_start.should eq(logical_start)
    changed.bytes.size.should eq(tape_size)
    assert_same_interval!(original, changed)
    changed.byte_at(21).should eq(replacement.to_u8)
    changed.byte_at(22).should eq(2_u8)
    changed_structure, _offset = parse_object_prefix(changed, 3)
    changed_structure.shared_data_version.should eq(replacement)
    changed_structure.bucket_count.should eq(2_u64)
    changed_structure.dynamic_paths.should eq(["note", "sample"])
    nil
  end

  # Keep each Object prefix independently legal while changing every declared
  # bucket count from two to one. The authenticated source records two buckets;
  # changing only this roster leaves the captured body unchanged.
  def poison_bucket_count_to_one!(part_path : String, expected_version : UInt64) : Nil
    physical = checked_physical(part_path)
    originals = root_marks(physical)
    originals.each_with_index do |shard, mark_index|
      structure, _statistics_offset = parse_object_prefix(shard, mark_index)
      structure.shared_data_version.should eq(expected_version)
      structure.bucket_count.should eq(2_u64)
      structure.dynamic_paths.should eq(["note", "sample"])
      if mark_index == 0
        statistics = structure.statistics || raise CrystalClick::CorruptPartError.new("native first Object mark omitted statistics")
        statistics.counts.should eq([8_u64, 8_u64])
        statistics.shared.map { |entry| {entry.name, entry.count} }.should eq([{"zz_overflow", 8_u64}])
      else
        structure.statistics.should be_nil
      end
      shard.byte_at(22).should eq(2_u8)
      logical_start, tape_size = mutate_root_byte!(part_path, mark_index, 22, 2_u8, 1_u8)
      changed = root_mark(checked_physical(part_path), mark_index)
      changed.logical_start.should eq(logical_start)
      changed.bytes.size.should eq(tape_size)
      assert_same_interval!(shard, changed)
      changed.byte_at(22).should eq(1_u8)
      changed_structure, _offset = parse_object_prefix(changed, mark_index)
      changed_structure.shared_data_version.should eq(expected_version)
      changed_structure.bucket_count.should eq(1_u64)
      changed_structure.dynamic_paths.should eq(["note", "sample"])
    end

    reopened = checked_physical(part_path)
    changed = root_marks(reopened)
    changed.size.should eq(4)
    changed.each_with_index do |shard, mark_index|
      assert_same_interval!(originals[mark_index], shard)
      shard.byte_at(22).should eq(1_u8)
      structure, _statistics_offset = parse_object_prefix(shard, mark_index)
      structure.shared_data_version.should eq(expected_version)
      structure.bucket_count.should eq(1_u64)
      structure.dynamic_paths.should eq(["note", "sample"])
    end
    nil
  end

  # Poison the source's exact overflow-7 String envelope in the final root
  # mark. Its LZ4 literal is shared with the overflow-8 tag, so qualify that
  # exact two-tag alias set and poison both selected-mark descriptors together.
  # Both envelopes stay length-delimited; outer role boundaries and transport
  # geometry remain unchanged.
  def poison_late_string_envelope!(part_path : String, expected_version : UInt64) : Nil
    physical = checked_physical(part_path)
    original = root_mark(physical, 3)
    structure, _statistics_offset = parse_object_prefix(original, 3)
    structure.shared_data_version.should eq(expected_version)
    structure.bucket_count.should eq(2_u64)
    structure.dynamic_paths.should eq(["note", "sample"])
    structure.statistics.should be_nil

    value_bytes = POISONED_STRING.to_slice
    envelope = Bytes.new(value_bytes.size + 2) { 0_u8 }
    envelope[0] = CrystalClick::BinaryDataType::TAG_STRING
    envelope[1] = value_bytes.size.to_u8
    value_bytes.each_with_index { |byte, index| envelope[index + 2] = byte }
    matches = find_all(original.bytes, envelope)
    # The stock layout has one String BinaryValue for this exact path/value
    # pair in the selected root mark. Refuse to guess if the source changes.
    matches.size.should eq(1)
    envelope_start = matches[0]
    original.byte_at(envelope_start).should eq(CrystalClick::BinaryDataType::TAG_STRING)
    original.bytes[envelope_start + 1, envelope.size - 1].should eq(envelope[1, envelope.size - 1])
    sibling_value = "overflow-8".to_slice
    sibling_envelope = Bytes.new(sibling_value.size + 2) { 0_u8 }
    sibling_envelope[0] = CrystalClick::BinaryDataType::TAG_STRING
    sibling_envelope[1] = sibling_value.size.to_u8
    sibling_value.each_with_index { |byte, index| sibling_envelope[index + 2] = byte }
    sibling_matches = find_all(original.bytes, sibling_envelope)
    sibling_matches.size.should eq(1)
    sibling_start = sibling_matches[0]
    original.byte_at(sibling_start).should eq(CrystalClick::BinaryDataType::TAG_STRING)
    original.bytes[sibling_start + 1, sibling_envelope.size - 1]
      .should eq(sibling_envelope[1, sibling_envelope.size - 1])
    logical_start, tape_size = mutate_root_byte!(
      part_path,
      3,
      envelope_start,
      CrystalClick::BinaryDataType::TAG_STRING,
      0xff_u8,
      [envelope_start, sibling_start],
    )

    reopened = checked_physical(part_path)
    changed = root_mark(reopened, 3)
    changed.logical_start.should eq(logical_start)
    changed.bytes.size.should eq(tape_size)
    assert_same_interval!(original, changed)
    changed.byte_at(envelope_start).should eq(0xff_u8)
    changed.byte_at(sibling_start).should eq(0xff_u8)
    changed.bytes[envelope_start + 1, envelope.size - 1].should eq(envelope[1, envelope.size - 1])
    changed.bytes[sibling_start + 1, sibling_envelope.size - 1]
      .should eq(sibling_envelope[1, sibling_envelope.size - 1])
    changed_structure, _offset = parse_object_prefix(changed, 3)
    changed_structure.shared_data_version.should eq(expected_version)
    changed_structure.bucket_count.should eq(2_u64)
    nil
  end

  # Capture one source-authenticated native root mark through the complete
  # prefix/body schedule. Tests may deliberately give this root slot a
  # different canonical mark label to challenge prepared-site provenance.
  def prepared_root_capture(
    part_path : String,
    mark_index : Int32 = 0,
    site_identity : String? = nil,
    authenticated : Bool = true,
  )
    physical = checked_physical(part_path)
    granule = physical.read_window("root", mark_index, 1).granules.first? ||
              raise CrystalClick::CorruptPartError.new("native MRK3 root mark is missing")
    granule.mark.should eq(mark_index)
    type = CompactJsonW263Fixture.json_type
    profile = CrystalClick::CompactStaticJsonBulkColumnReader.open(part_path, "root", type).ordinary_profile
    limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
    budget = CrystalClick::BinaryCodecBudget.new(limits)
    framer = if authenticated
               CrystalClick::CompactJsonObjectSiteFramer.new(
                 physical.mode,
                 granule.shards,
                 budget,
                 physical,
                 site_identity || "root:mark=#{mark_index}",
               )
             else
               CrystalClick::CompactJsonObjectSiteFramer.new(physical.mode, granule.shards, budget)
             end

    manifest = CrystalClick::CompactStaticJsonSiteManifest.new("root", type)
    observed_dynamic_offsets = Hash(String, Int32).new
    statistics_offset_observer = ->(name : String, offset : Int32) do
      observed_dynamic_offsets[name] = offset
      nil
    end
    nested = CrystalClick::ObjectSharedNestedSerializationContext.for_read(0_u64, profile)
    prefix = CrystalClick::ObjectDocumentCallbackPrefixReader.read_static_json_prefix(
      framer,
      type,
      1_i32,
      manifest.physical_prefix,
      manifest.callback_prefix,
      0_u64,
      nested,
      budget,
      true,
      statistics_offset_observer,
    )
    physical_plan = CrystalClick::ObjectDocumentPhysicalPlan.from_escaped_prefix(
      manifest.physical_prefix,
      prefix.plan,
      profile,
      CrystalClick::BinaryBulkProfile.single_stream,
      limits,
      prefix.array_level,
      typed_descriptor_root_depth: prefix.typed_descriptor_root_depth,
      inferred_actual_root_depth: prefix.inferred_actual_root_depth,
      root_dynamic_json_budget: budget,
    )
    prefix.bind_physical_plan!(physical_plan)
    schedule = CrystalClick::CompactJsonObjectRoleSchedule.build(prefix, physical_plan, profile, budget)
    schedule.advanced.should be_true

    prefix.start_body_capture!
    CrystalClick::CompactJsonObjectMapTapeFramer.capture_body!(
      prefix,
      physical_plan,
      schedule,
      framer,
      granule.row_count,
      profile,
      limits,
      budget,
    )
    prefix.finish_body_capture!(schedule.body_pairs.size)
    framer.validate_expected_events!(schedule.event_names)
    framer.finish!

    statistics_offsets = Hash(String, Int32).new(initial_capacity: observed_dynamic_offsets.size + 1)
    observed_dynamic_offsets.each { |name, offset| statistics_offsets[name] = offset }
    object_callback = CrystalClick::PhysicalStreamName.append_literal(manifest.callback_prefix, ".object_structure")
    statistics_offsets[object_callback] = prefix.object_structure_statistics_offset
    grid = CrystalClick::StorageOccurrenceGrid.new(
      [granule.row_count] of UInt64,
      [granule.row_count] of UInt64,
      budget,
    )

    {
      physical:           physical,
      granule:            granule,
      budget:             budget,
      framer:             framer,
      prefix:             prefix,
      physical_plan:      physical_plan,
      schedule:           schedule,
      statistics_offsets: statistics_offsets,
      grid:               grid,
      profile:            profile,
    }
  end

  # Build a completed, physically authenticated diagnostic capture from a
  # different native MRK3 column while retaining a caller-supplied root site
  # label. The deliberately foreign event name is only a later discriminator;
  # a prepared-site provenance guard must reject the slot first.
  def diagnostic_column_framer(
    physical : CrystalClick::CompactPartPhysicalContext,
    column_name : String,
    mark_index : Int32,
    site_identity : String,
    budget : CrystalClick::BinaryCodecBudget,
  ) : CrystalClick::CompactJsonObjectSiteFramer
    granule = physical.read_window(column_name, mark_index, 1).granules.first? ||
              raise CrystalClick::CorruptPartError.new("native MRK3 diagnostic column mark is missing")
    granule.shards.size.should eq(1)
    framer = CrystalClick::CompactJsonObjectSiteFramer.new(
      physical.mode,
      granule.shards,
      budget,
      physical,
      site_identity,
    )
    _value, _bytes = framer.with_grammar_extent("diagnostic_only") do |remaining|
      {nil, remaining.size}
    end
    framer.validate_expected_events!(["diagnostic_only"])
    framer.finish!
    framer
  end

  private def checked_physical(part_path : String) : CrystalClick::CompactPartPhysicalContext
    physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
    physical.mode.should eq(CrystalClick::CompactMarkFormat::Mrk3)
    physical.row_count.should eq(8_u64)
    physical.mark_row_counts.should eq(ROWS)
    physical.granule_count.should eq(4)
    physical
  end

  private def root_marks(physical : CrystalClick::CompactPartPhysicalContext) : Array(CrystalClick::CompactPartPhysicalShard)
    window = physical.read_window("root", 0, 4)
    window.granules.size.should eq(4)
    window.granules.each_with_index.map do |granule, mark_index|
      granule.mark.should eq(mark_index)
      granule.row_count.should eq(2_u64)
      granule.shards.size.should eq(1)
      shard = granule.shards[0]
      parse_object_prefix(shard, mark_index)
      shard
    end.to_a
  end

  private def root_mark(physical : CrystalClick::CompactPartPhysicalContext, mark_index : Int32) : CrystalClick::CompactPartPhysicalShard
    window = physical.read_window("root", mark_index, 1)
    window.granules.size.should eq(1)
    window.granules[0].mark.should eq(mark_index)
    window.granules[0].row_count.should eq(2_u64)
    window.granules[0].shards.size.should eq(1)
    window.granules[0].shards[0]
  end

  private def parse_object_prefix(
    shard : CrystalClick::CompactPartPhysicalShard,
    mark_index : Int32,
  ) : Tuple(CrystalClick::ObjectStructure, Int32)
    prefix_size = OBJECT_PREFIX_SIZES[mark_index]?
    unless prefix_size && shard.bytes.size >= prefix_size
      raise CrystalClick::CorruptPartError.new("native MRK3 root mark lacks its authenticated Object structure prefix")
    end
    context = CrystalClick::BinaryCodecContext.new(
      CrystalClick::BinaryCodecLimits.default,
      shard.bytes[0, prefix_size],
    )
    structure, statistics_offset = CrystalClick::ObjectStructureCodec.read_with_statistics_offset(context)
    context.ensure_consumed
    structure.version.should eq(4_u64)
    structure.dynamic_paths.should eq(["note", "sample"])
    statistics_offset.should eq(23)
    {structure, statistics_offset}
  end

  private def assert_same_interval!(before : CrystalClick::CompactPartPhysicalShard, after : CrystalClick::CompactPartPhysicalShard) : Nil
    after.logical_start.should eq(before.logical_start)
    after.bytes.size.should eq(before.bytes.size)
    nil
  end

  private def mutate_root_byte!(
    part_path : String,
    mark_index : Int32,
    tape_offset : Int32,
    expected : UInt8,
    replacement : UInt8,
    expected_alias_offsets : Array(Int32)? = nil,
  ) : Tuple(Int64, Int32)
    raise ArgumentError.new("W263 poison mutation must change the selected byte") if expected == replacement
    original = root_mark(checked_physical(part_path), mark_index)
    original.byte_at(tape_offset).should eq(expected)
    logical_offset = original.logical_start + tape_offset

    data_path = File.join(part_path, "data.bin")
    data = File.read(data_path).to_slice.dup
    original_frame_layout = frame_layout(data)
    frame_index = original_frame_layout.index do |frame|
      logical_offset >= frame[2] && logical_offset < frame[3]
    end || raise CrystalClick::CorruptPartError.new("native root poison coordinate is outside data.bin")
    compressed_start, _compressed_end, logical_start, _logical_end, method = original_frame_layout[frame_index]
    unless method == CrystalClick::CompressedBlock::METHOD_LZ4
      raise CrystalClick::UnsupportedFormatError.new("W263 exact-byte poison requires an authenticated LZ4 frame")
    end
    local_offset = (logical_offset - logical_start).to_i
    allowed_logical_offsets = expected_alias_offsets || [tape_offset]
    allowed_frame_offsets = allowed_logical_offsets.map do |offset|
      original.logical_start + offset - logical_start
    end
    unless allowed_logical_offsets.includes?(tape_offset) && allowed_frame_offsets.all? { |offset| offset >= 0 }
      raise ArgumentError.new("W263 poison alias roster omits the selected coordinate or crosses its frame")
    end
    change_lz4_literal!(data, compressed_start, local_offset, expected, replacement, allowed_frame_offsets)
    File.write(data_path, data)
    CompactPhysicalContextW259Fixture.refresh_checksums(part_path)

    changed_data = File.read(data_path).to_slice
    frame_layout(changed_data).should eq(original_frame_layout)
    reopened = checked_physical(part_path)
    changed = root_mark(reopened, mark_index)
    changed.logical_start.should eq(original.logical_start)
    changed.bytes.size.should eq(original.bytes.size)
    changed.byte_at(tape_offset).should eq(replacement)
    assert_same_interval!(original, changed)
    {original.logical_start, original.bytes.size}
  end

  # Mutate a source literal without moving any compressed or logical frame
  # boundary. Literal aliases are admitted only when the caller names their
  # exact selected-mark positions; all other decoded bytes must stay equal.
  private def change_lz4_literal!(
    data : Bytes,
    compressed_start : Int32,
    local_offset : Int32,
    expected : UInt8,
    replacement : UInt8,
    allowed_output_offsets : Array(Int64),
  ) : Nil
    header = compressed_start + CrystalClick::CompressedBlock::CHECKSUM_SIZE
    compressed_size = read_u32(data, header + 1).to_i
    decompressed_size = read_u32(data, header + 5).to_i
    frame = CrystalClick::CompressedBlock.decode_frame(data, compressed_start.to_i64)
    frame.output[local_offset].should eq(expected)

    payload_start = compressed_start + CrystalClick::CompressedBlock::FRAME_HEADER_SIZE
    payload_size = compressed_size - CrystalClick::CompressedBlock::HEADER_SIZE
    payload = data[payload_start, payload_size]
    sources = lz4_output_source_offsets(payload, decompressed_size)
    literal_source = sources[local_offset]? ||
                     raise CrystalClick::UnsupportedFormatError.new("W263 poison coordinate is not backed by an LZ4 literal")
    if literal_source < 0
      raise CrystalClick::UnsupportedFormatError.new("W263 poison coordinate is not backed by an LZ4 literal")
    end
    actual_aliases = sources.each_index
      .select { |index| sources[index] == literal_source }
      .to_a
      .map(&.to_i64)
      .sort
    actual_aliases.should eq(allowed_output_offsets.map(&.to_i64).sort)

    if actual_aliases.empty? || !actual_aliases.includes?(local_offset.to_i64)
      raise CrystalClick::CorruptPartError.new("W263 selected poison is absent from its LZ4 alias roster")
    end

    physical_source = payload_start + literal_source
    data[physical_source].should eq(expected)
    data[physical_source] = replacement
    changed = CrystalClick::CompressedBlock.decode_frame(data, compressed_start.to_i64)
    changed.output.size.should eq(frame.output.size)
    changed.output.each_with_index do |byte, index|
      expected_byte = actual_aliases.includes?(index.to_i64) ? replacement : frame.output[index]
      byte.should eq(expected_byte)
    end

    checksum = CrystalClick::CityHashV1.hash128(data[header, compressed_size])
    write_u64(data, compressed_start, checksum[0])
    write_u64(data, compressed_start + 8, checksum[1])
    nil
  end

  private def lz4_output_source_offsets(payload : Bytes, expected_size : Int32) : Array(Int32)
    sources = Array(Int32).new(expected_size, -1)
    input = 0
    output = 0
    while input < payload.size
      token = payload[input]
      input += 1
      literal_length, input = lz4_length(payload, input, token >> 4)
      if input < 0 || literal_length < 0 || input > payload.size - literal_length ||
         output < 0 || literal_length < 0 || output > sources.size - literal_length
        raise CrystalClick::CorruptPartError.new("authenticated LZ4 literal run is outside its frame")
      end
      literal_length.times do |index|
        sources[output + index] = input + index
      end
      input += literal_length
      output += literal_length
      break if input == payload.size

      if input > payload.size - 2
        raise CrystalClick::CorruptPartError.new("authenticated LZ4 match distance is truncated")
      end
      distance = payload[input].to_i | (payload[input + 1].to_i << 8)
      input += 2
      if distance == 0 || distance > output
        raise CrystalClick::CorruptPartError.new("authenticated LZ4 match distance is invalid")
      end
      match_length, input = lz4_length(payload, input, token & 0x0f)
      match_length += 4
      if output > sources.size - match_length
        raise CrystalClick::CorruptPartError.new("authenticated LZ4 match exceeds its frame")
      end
      match_length.times do |index|
        sources[output + index] = sources[output + index - distance]
      end
      output += match_length
    end
    unless output == expected_size && sources.all? { |source| source >= 0 }
      raise CrystalClick::CorruptPartError.new("authenticated LZ4 source map disagrees with decoded frame")
    end
    sources
  end

  private def lz4_length(payload : Bytes, initial_index : Int32, nibble : UInt8) : Tuple(Int32, Int32)
    value = nibble.to_i
    return {value, initial_index} unless value == 15

    total = 15
    index = initial_index
    loop do
      if index >= payload.size
        raise CrystalClick::CorruptPartError.new("authenticated LZ4 length extension is truncated")
      end
      extension = payload[index].to_i
      index += 1
      total += extension
      break unless extension == 255
    end
    {total, index}
  end

  private def frame_layout(data : Bytes) : Array(Tuple(Int32, Int32, Int64, Int64, UInt8))
    frames = [] of Tuple(Int32, Int32, Int64, Int64, UInt8)
    compressed_start = 0
    logical_start = 0_i64
    while compressed_start < data.size
      header = compressed_start + CrystalClick::CompressedBlock::CHECKSUM_SIZE
      if header > data.size - CrystalClick::CompressedBlock::HEADER_SIZE
        raise CrystalClick::CorruptPartError.new("native data.bin frame header is truncated")
      end
      method = data[header]
      compressed_size = read_u32(data, header + 1).to_i
      decompressed_size = read_u32(data, header + 5).to_i
      compressed_end = compressed_start + CrystalClick::CompressedBlock::CHECKSUM_SIZE + compressed_size
      if compressed_size < CrystalClick::CompressedBlock::HEADER_SIZE || compressed_end > data.size || decompressed_size <= 0
        raise CrystalClick::CorruptPartError.new("native data.bin frame geometry is invalid")
      end
      # Decode every frame before trusting the geometry snapshot.
      decoded = CrystalClick::CompressedBlock.decode_frame(data, compressed_start.to_i64)
      decoded.output.size.should eq(decompressed_size)
      logical_end = logical_start + decompressed_size
      frames << {compressed_start, compressed_end, logical_start, logical_end, method}
      compressed_start = compressed_end
      logical_start = logical_end
    end
    frames
  end

  private def read_u32(bytes : Bytes, offset : Int) : UInt32
    if offset < 0 || offset > bytes.size - 4
      raise CrystalClick::CorruptPartError.new("native data.bin has a truncated frame header")
    end
    bytes[offset].to_u32 |
      (bytes[offset + 1].to_u32 << 8) |
      (bytes[offset + 2].to_u32 << 16) |
      (bytes[offset + 3].to_u32 << 24)
  end

  private def write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
    8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
  end

  private def find_all(bytes : Bytes, needle : Bytes) : Array(Int32)
    matches = [] of Int32
    return matches if needle.empty? || needle.size > bytes.size
    (bytes.size - needle.size + 1).times do |start|
      matches << start if bytes[start, needle.size] == needle
    end
    matches
  end
end
