require "file_utils"
require "../../scripts/support/compact_json_w263_fixture"
require "../../scripts/support/compact_physical_context_w259_fixture"
require "./compact_static_json_w263_adversary_fixture"

module CompactStaticJsonMrk4ChunkedW263Fixture
  extend self

  LABEL = "obj_v3_dyn_v3_advanced_chunked_mrk4_s0_variant_basic"
  ROWS  = [2_u64, 2_u64, 2_u64, 2_u64]

  ROOT_EVENTS = [
    "root.object_structure",
    "root.note.dynamic_structure",
    "root.note.variant_discr_prefix",
    "root.sample.dynamic_structure",
    "root.sample.variant_discr_prefix",
    "root.id",
    "root.label",
    "root.note.variant_discr",
    "root.note.SharedVariant",
    "root.note.String",
    "root.sample.variant_discr",
    "root.sample.Int64",
    "root.sample.SharedVariant",
    "root.object_shared_data.0.structure_prefix",
    "root.object_shared_data.0.data",
    "root.object_shared_data.0.paths_marks",
    "root.object_shared_data.0.substreams",
    "root.object_shared_data.0.substreams_marks",
    "root.object_shared_data.0.paths_substreams_metadata",
    "root.object_shared_data.0.structure_suffix",
    "root.object_shared_data.1.structure_prefix",
    "root.object_shared_data.1.data",
    "root.object_shared_data.1.paths_marks",
    "root.object_shared_data.1.substreams",
    "root.object_shared_data.1.substreams_marks",
    "root.object_shared_data.1.paths_substreams_metadata",
    "root.object_shared_data.1.structure_suffix",
    "root.object_shared_data.copy.sizes",
    "root.object_shared_data.copy.paths_indexes",
    "root.object_shared_data.copy.values",
  ] of String

  MARK0_INTERVALS = [
    {"root.object_structure", 125_i64, 165_i64},
    {"root.note.dynamic_structure", 165_i64, 179_i64},
    {"root.note.variant_discr_prefix", 179_i64, 187_i64},
    {"root.sample.dynamic_structure", 187_i64, 210_i64},
    {"root.sample.variant_discr_prefix", 210_i64, 218_i64},
    {"root.id", 218_i64, 220_i64},
    {"root.label", 220_i64, 234_i64},
    {"root.note.variant_discr", 234_i64, 236_i64},
    {"root.note.SharedVariant", 236_i64, 236_i64},
    {"root.note.String", 236_i64, 250_i64},
    {"root.sample.variant_discr", 250_i64, 252_i64},
    {"root.sample.Int64", 252_i64, 260_i64},
    {"root.sample.SharedVariant", 260_i64, 270_i64},
    {"root.object_shared_data.0.structure_prefix", 270_i64, 274_i64},
    {"root.object_shared_data.0.data", 274_i64, 274_i64},
    {"root.object_shared_data.0.paths_marks", 274_i64, 274_i64},
    {"root.object_shared_data.0.substreams", 274_i64, 274_i64},
    {"root.object_shared_data.0.substreams_marks", 274_i64, 274_i64},
    {"root.object_shared_data.0.paths_substreams_metadata", 274_i64, 274_i64},
    {"root.object_shared_data.0.structure_suffix", 274_i64, 370_i64},
    {"root.object_shared_data.1.structure_prefix", 370_i64, 398_i64},
    {"root.object_shared_data.1.data", 398_i64, 462_i64},
    {"root.object_shared_data.1.paths_marks", 462_i64, 494_i64},
    {"root.object_shared_data.1.substreams", 494_i64, 654_i64},
    {"root.object_shared_data.1.substreams_marks", 654_i64, 814_i64},
    {"root.object_shared_data.1.paths_substreams_metadata", 814_i64, 878_i64},
    {"root.object_shared_data.1.structure_suffix", 878_i64, 974_i64},
    {"root.object_shared_data.copy.sizes", 974_i64, 990_i64},
    {"root.object_shared_data.copy.paths_indexes", 990_i64, 992_i64},
    {"root.object_shared_data.copy.values", 992_i64, 1018_i64},
  ] of Tuple(String, Int64, Int64)

  def evidence_root : String
    CompactStaticJsonW263AdversaryFixture.evidence_root
  end

  def source_part(root : String = evidence_root) : NamedTuple(path: String, inventory: Array(Tuple(String, Int64, String)))
    CompactStaticJsonW263AdversaryFixture.source_part(root, LABEL)
  end

  def copy_part(source_part : String) : Tuple(String, String)
    CompactStaticJsonW263AdversaryFixture.copy_part(source_part)
  end

  # Return an independently authenticated source context after checking the
  # exact native callback roster, empty callbacks, and whole-data coordinates.
  def assert_native_roster!(part_path : String) : CrystalClick::CompactPartPhysicalContext
    physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
    raise "chunked stock source is not mrk4" unless physical.mode.mrk4?
    physical.row_count.should eq(8_u64)
    physical.granule_count.should eq(4)
    physical.mark_row_counts.should eq(ROWS)

    windows = physical.read_window("root", 0, physical.granule_count).granules
    windows.size.should eq(4)
    windows.each_with_index do |granule, mark_index|
      granule.mark.should eq(mark_index)
      granule.row_count.should eq(ROWS[mark_index])
      granule.shards.map do |shard|
        shard.stream_name || raise(CrystalClick::CorruptPartError.new("chunked root shard has no stream identity"))
      end.should eq(ROOT_EVENTS)
    end

    first = windows.first
    first.shards.map do |shard|
      {
        shard.stream_name || raise(CrystalClick::CorruptPartError.new("chunked root shard has no stream identity")),
        shard.logical_start,
        shard.logical_end,
      }
    end.should eq(MARK0_INTERVALS)

    assert_bucket_structure!(first.shards, 0, [
      { {0, 2}, 1_u64, [] of String, {243_u64, 149_u64}, {243_u64, 149_u64}, {243_u64, 149_u64} },
      { {2, 4}, 1_u64, [] of String, {243_u64, 149_u64}, {243_u64, 149_u64}, {243_u64, 149_u64} },
    ] of Tuple(Tuple(Int32, Int32), UInt64, Array(String), Tuple(UInt64, UInt64), Tuple(UInt64, UInt64), Tuple(UInt64, UInt64)))
    assert_bucket_structure!(first.shards, 1, [
      { {0, 14}, 1_u64, ["zz_overflow"], {243_u64, 273_u64}, {243_u64, 337_u64}, {243_u64, 689_u64} },
      { {14, 28}, 1_u64, ["zz_overflow"], {243_u64, 305_u64}, {243_u64, 353_u64}, {243_u64, 721_u64} },
    ] of Tuple(Tuple(Int32, Int32), UInt64, Array(String), Tuple(UInt64, UInt64), Tuple(UInt64, UInt64), Tuple(UInt64, UInt64)))
    physical
  end

  # Reframe a same-length logical mutation as valid literal-LZ4 transport.
  # Both outer mrk4 mark pairs and every persisted ADVANCED_CHUNKED saved pair
  # are mapped from the original whole-data.bin domain; none are rebased to a
  # selected column or callback. Reopen and authenticate the entire new source
  # before returning to a reader adversary.
  def rewrite_mrk4_tape!(part_path : String, physical : CrystalClick::CompactPartPhysicalContext, raw : Bytes) : Nil
    unless physical.mode.mrk4? && physical.mark_row_counts == ROWS
      raise "chunked tape rewrite requires the authenticated four-mark mrk4 grid"
    end
    slots = physical.physical_roster
    raise "chunked tape rewrite has no physical slots" if slots.empty?

    column_names = [] of String
    slots.each do |slot|
      column_names << slot.column_name unless column_names.includes?(slot.column_name)
    end
    shard_grid = Array(Array(CrystalClick::CompactPartPhysicalShard?)).new(physical.granule_count) do
      Array(CrystalClick::CompactPartPhysicalShard?).new(slots.size, nil)
    end
    column_names.each do |column_name|
      window = physical.read_window(column_name, 0, physical.granule_count)
      window.granules.each_with_index do |granule, mark_index|
        granule.shards.each do |shard|
          unless shard.slot_index >= 0 && shard.slot_index < slots.size && slots[shard.slot_index].column_name == column_name
            raise "chunked tape rewrite observed a shard outside its authenticated slot roster"
          end
          shard_grid[mark_index][shard.slot_index] = shard
        end
      end
    end

    queries = [] of UInt64
    physical.granule_count.times do |mark_index|
      slots.size.times do |slot_index|
        shard = shard_grid[mark_index][slot_index] || raise "chunked tape rewrite missed a physical slot"
        queries << shard.logical_start.to_u64
      end
    end
    slots.size.times { queries << raw.size.to_u64 }
    outer_coordinate_count = queries.size

    pair_byte_offsets = [] of Int32
    pair_logical_positions = [] of Int64
    root_window = physical.read_window("root", 0, physical.granule_count)
    root_window.granules.each do |granule|
      names = Hash(String, CrystalClick::CompactPartPhysicalShard).new
      granule.shards.each do |shard|
        name = shard.stream_name || raise(CrystalClick::CorruptPartError.new("chunked root shard has no stream name"))
        names[name] = shard
      end
      2.times do |bucket_index|
        base = "root.object_shared_data.#{bucket_index}"
        prefix = names["#{base}.structure_prefix"].bytes
        suffix_shard = names["#{base}.structure_suffix"]
        suffix = suffix_shard.bytes
        records = CrystalClick::ObjectSharedChunkStructureCodec.read_split_record_spans(
          prefix,
          suffix,
          CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS),
        )

        path_count = records.sum(0_i64) { |span| span.record.path_count.to_i64 }
        if path_count > Int32::MAX
          raise "chunked path count exceeds the fixture's bounded pair domain"
        end
        expected_path_count = path_count.to_i32
        if expected_path_count > Int32::MAX // 2
          raise "chunked metadata pair count exceeds the fixture's bounded pair domain"
        end

        paths_marks_shard = names["#{base}.paths_marks"]
        metadata_shard = names["#{base}.paths_substreams_metadata"]
        substreams_shard = names["#{base}.substreams"]
        substreams_marks_shard = names["#{base}.substreams_marks"]
        expected_event_count = substream_event_count(substreams_shard.bytes, expected_path_count)
        append_saved_lane_pairs!(
          raw,
          physical,
          paths_marks_shard,
          expected_path_count,
          pair_byte_offsets,
          pair_logical_positions,
          queries,
        )
        append_saved_lane_pairs!(
          raw,
          physical,
          substreams_marks_shard,
          expected_event_count,
          pair_byte_offsets,
          pair_logical_positions,
          queries,
        )
        append_saved_lane_pairs!(
          raw,
          physical,
          metadata_shard,
          expected_path_count * 2,
          pair_byte_offsets,
          pair_logical_positions,
          queries,
        )

        records.each_with_index do |span, record_index|
          raise "chunked suffix does not contain one full coordinate record" if (record_index + 1) * 48 > suffix.size
          suffix_offset = suffix_shard.logical_start.to_i32 + record_index * 48
          [
            {span.record.data_marks, 0_i32},
            {span.record.paths_marks, 16_i32},
            {span.record.paths_substreams_metadata_marks, 32_i32},
          ].each do |entry|
            pair, pair_offset = entry
            append_saved_coordinate_pair!(
              raw,
              physical,
              suffix_offset + pair_offset,
              pair_byte_offsets,
              pair_logical_positions,
              queries,
              pair,
            )
          end
        end
      end
    end

    remapped = CrystalClick::CompressedMarkWriter.plan_literal_positions(
      raw.size.to_i64,
      queries,
      frame_bytes: 4096,
    )
    raise "chunked coordinate remap returned the wrong cardinality" unless remapped.size == queries.size

    unless pair_byte_offsets.size == pair_logical_positions.size
      raise "chunked saved-pair map lost its source logical positions"
    end
    pair_byte_offsets.each_with_index do |byte_offset, index|
      pair = remapped[outer_coordinate_count + index]
      write_u64_le(raw, byte_offset, pair[0])
      write_u64_le(raw, byte_offset + 8, pair[1])
    end

    record_width = slots.size * 16 + 8
    marks = Bytes.new((physical.granule_count + 1) * record_width, 0_u8)
    physical.granule_count.times do |mark_index|
      slots.size.times do |slot_index|
        coordinate_index = mark_index * slots.size + slot_index
        write_u64_le(marks, mark_index * record_width + slot_index * 16, remapped[coordinate_index][0])
        write_u64_le(marks, mark_index * record_width + slot_index * 16 + 8, remapped[coordinate_index][1])
      end
      write_u64_le(marks, mark_index * record_width + slots.size * 16, physical.mark_row_counts[mark_index])
    end
    slots.size.times do |slot_index|
      coordinate_index = physical.granule_count * slots.size + slot_index
      write_u64_le(marks, physical.granule_count * record_width + slot_index * 16, remapped[coordinate_index][0])
      write_u64_le(marks, physical.granule_count * record_width + slot_index * 16 + 8, remapped[coordinate_index][1])
    end
    write_u64_le(marks, physical.granule_count * record_width + slots.size * 16, 0_u64)

    File.write(File.join(part_path, "data.bin"), CrystalClick::CompressedMarkWriter.encode_all(raw, frame_bytes: 4096))
    File.write(File.join(part_path, "data.mrk4"), marks)
    CompactPhysicalContextW259Fixture.refresh_checksums(part_path)

    reopened = CrystalClick::CompactPartPhysicalContext.open(part_path)
    unless reopened.mode.mrk4? && reopened.mark_row_counts == ROWS
      raise "reframed chunked source changed its mrk4 physical grid"
    end
    full_raw = CrystalClick::CompressedMarkReader.read_all(
      File.join(part_path, "data.bin"),
      File.size(File.join(part_path, "data.bin")).to_i64,
    )
    raise "reframed chunked source did not preserve the same logical byte domain" unless full_raw == raw

    reopened_slots = Array(Array(CrystalClick::CompactPartPhysicalShard?)).new(reopened.granule_count) do
      Array(CrystalClick::CompactPartPhysicalShard?).new(slots.size, nil)
    end
    column_names.each do |column_name|
      reopened_window = reopened.read_window(column_name, 0, reopened.granule_count)
      reopened_window.granules.each_with_index do |granule, mark_index|
        granule.shards.each do |shard|
          reopened_slots[mark_index][shard.slot_index] = shard
        end
      end
    end
    physical.granule_count.times do |mark_index|
      slots.size.times do |slot_index|
        original = shard_grid[mark_index][slot_index] || raise "chunked source snapshot missed a physical slot"
        observed = reopened_slots[mark_index][slot_index] || raise "reframed source missed a physical slot"
        observed.stream_name.should eq(original.stream_name)
        observed.logical_start.should eq(original.logical_start)
        observed.logical_end.should eq(original.logical_end)
      end
    end

    pair_byte_offsets.each_with_index do |byte_offset, index|
      pair = {read_u64_le(raw, byte_offset), read_u64_le(raw, byte_offset + 8)}
      reopened.logical_position(pair).should eq(pair_logical_positions[index])
    end
    nil
  end

  # The second bucket's second native chunk header occupies [14,28) in its
  # mark-0 StructurePrefix. Its single path length is byte 16 of that header.
  # Raising 11 to 127 preserves all outer sizes while making the complete
  # EOF-selected structure roster impossible to parse.
  def corrupt_late_structure_path_length!(part_path : String) : Tuple(Int64, Int32)
    physical = assert_native_roster!(part_path)
    raw = read_logical_data(part_path)
    root = physical.read_window("root", 0, 1).granules.first? || raise "mark zero is absent"
    shard = root.shards.find { |candidate| candidate.stream_name == "root.object_shared_data.1.structure_prefix" } ||
            raise "bucket-1 StructurePrefix is absent"
    expected = Bytes[1_u8, 1_u8, 11_u8, 0x7a_u8, 0x7a_u8, 0x5f_u8, 0x6f_u8, 0x76_u8, 0x65_u8,
      0x72_u8, 0x66_u8, 0x6c_u8, 0x6f_u8, 0x77_u8,
      1_u8, 1_u8, 11_u8, 0x7a_u8, 0x7a_u8, 0x5f_u8, 0x6f_u8, 0x76_u8, 0x65_u8,
      0x72_u8, 0x66_u8, 0x6c_u8, 0x6f_u8, 0x77_u8]
    shard.bytes.should eq(expected)
    offset = shard.logical_start.to_i + 16
    raw[offset].should eq(11_u8)
    raw[offset] = 127_u8
    rewrite_mrk4_tape!(part_path, physical, raw)
    {shard.logical_start + 16_i64, expected.size}
  end

  # Poison the inner BinaryValue type tag in the first Copy envelope while
  # retaining its envelope length and the full authenticated data.bin framing.
  def corrupt_first_shared_value_tag!(part_path : String) : Tuple(Int64, Int32)
    physical = assert_native_roster!(part_path)
    raw = read_logical_data(part_path)
    root = physical.read_window("root", 0, 1).granules.first? || raise "mark zero is absent"
    shard = root.shards.find { |candidate| candidate.stream_name == "root.object_shared_data.copy.values" } ||
            raise "Copy values callback is absent"
    shard.logical_start.should eq(992_i64)
    shard.logical_end.should eq(1018_i64)
    bytes = shard.bytes
    bytes.size.should eq(26)
    bytes[1].should eq(CrystalClick::BinaryDataType::TAG_STRING)
    raw[shard.logical_start.to_i + 1] = 0xff_u8
    rewrite_mrk4_tape!(part_path, physical, raw)

    reopened = CrystalClick::CompactPartPhysicalContext.open(part_path)
    reopened.mark_row_counts.should eq(ROWS)
    observed = reopened.read_window("root", 0, 1).granules.first?.try(&.shards.find do |candidate|
      candidate.stream_name == "root.object_shared_data.copy.values"
    end) || raise "authenticated Copy values callback is absent after rewrite"
    observed.logical_start.should eq(shard.logical_start)
    observed.logical_end.should eq(shard.logical_end)
    observed.byte_at(1).should eq(0xff_u8)
    {shard.logical_start, bytes.size}
  end

  private def assert_bucket_structure!(
    shards : Array(CrystalClick::CompactPartPhysicalShard),
    bucket_index : Int32,
    expected : Array(Tuple(Tuple(Int32, Int32), UInt64, Array(String), Tuple(UInt64, UInt64), Tuple(UInt64, UInt64), Tuple(UInt64, UInt64))),
  ) : Nil
    base = "root.object_shared_data.#{bucket_index}"
    prefix = shards.find { |shard| shard.stream_name == "#{base}.structure_prefix" } || raise "chunked StructurePrefix is absent"
    suffix = shards.find { |shard| shard.stream_name == "#{base}.structure_suffix" } || raise "chunked StructureSuffix is absent"
    spans = CrystalClick::ObjectSharedChunkStructureCodec.read_split_record_spans(
      prefix.bytes,
      suffix.bytes,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS),
    )
    spans.map do |span|
      {
        {span.prefix_start, span.prefix_end},
        span.record.row_count,
        span.record.paths,
        span.record.data_marks,
        span.record.paths_marks,
        span.record.paths_substreams_metadata_marks,
      }
    end.should eq(expected)
    suffix.bytes.size.should eq(2 * CrystalClick::ObjectSharedChunkStructureCodec::TRANSPORT_SUFFIX_BYTES.to_i)
    nil
  end

  private def read_logical_data(part_path : String) : Bytes
    data_path = File.join(part_path, "data.bin")
    CrystalClick::CompressedMarkReader.read_all(data_path, File.size(data_path).to_i64)
  end

  private def append_saved_lane_pairs!(
    raw : Bytes,
    physical : CrystalClick::CompactPartPhysicalContext,
    shard : CrystalClick::CompactPartPhysicalShard,
    expected_pair_count : Int32,
    pair_byte_offsets : Array(Int32),
    pair_logical_positions : Array(Int64),
    queries : Array(UInt64),
  ) : Nil
    unless expected_pair_count >= 0 && shard.logical_end >= shard.logical_start &&
           shard.logical_end - shard.logical_start == expected_pair_count.to_i64 * 16_i64
      raise "chunked persisted pair lane disagrees with its parsed source roster"
    end
    bytes = shard.bytes
    unless bytes.size == expected_pair_count * 16
      raise "chunked persisted pair callback has an unexpected byte extent"
    end
    if shard.logical_start < 0 || shard.logical_start > Int32::MAX ||
       shard.logical_start + bytes.size > raw.size
      raise "chunked persisted pair callback is outside the logical data domain"
    end
    unless raw[shard.logical_start.to_i32, bytes.size] == bytes
      raise "chunked persisted pair callback differs from the original logical tape"
    end

    expected_pair_count.times do |index|
      byte_offset = shard.logical_start.to_i32 + index * 16
      append_saved_coordinate_pair!(
        raw,
        physical,
        byte_offset,
        pair_byte_offsets,
        pair_logical_positions,
        queries,
      )
    end
    nil
  end

  private def append_saved_coordinate_pair!(
    raw : Bytes,
    physical : CrystalClick::CompactPartPhysicalContext,
    byte_offset : Int32,
    pair_byte_offsets : Array(Int32),
    pair_logical_positions : Array(Int64),
    queries : Array(UInt64),
    expected_pair : Tuple(UInt64, UInt64)? = nil,
  ) : Nil
    if byte_offset < 0 || byte_offset > raw.size - 16
      raise "chunked saved pair is outside the original logical data domain"
    end
    pair = {read_u64_le(raw, byte_offset), read_u64_le(raw, byte_offset + 8)}
    if expected = expected_pair
      unless pair == expected
        raise "chunked split suffix pair differs from its authenticated structure record"
      end
    end
    logical_position = physical.logical_position(pair)
    if logical_position < 0 || logical_position > raw.size
      raise "chunked saved pair resolves outside the original logical data domain"
    end
    pair_byte_offsets << byte_offset
    pair_logical_positions << logical_position
    queries << logical_position.to_u64
    nil
  end

  # Each Substreams record is VarUInt(event_count), followed by that many
  # VarUInt(name_size)+name byte strings. SubstreamsMarks stores one whole-data
  # coordinate pair per event; parsing these counts prevents silently leaving
  # a saved pair behind when a path has multiple callback positions.
  private def substream_event_count(bytes : Bytes, path_count : Int32) : Int32
    limits = CrystalClick::BinaryCodecLimits.default
    budget = CrystalClick::BinaryCodecBudget.new(limits)
    context = CrystalClick::BinaryCodecContext.new(limits, bytes, false, budget)
    event_count = 0_u64
    path_count.times do
      raw_count = context.read_var_uint
      count = context.preflight_metadata(
        raw_count,
        1_u64,
        maximum_count: Int32::MAX.to_u64,
        label: "chunked substream event count",
      )
      if event_count > Int32::MAX.to_u64 - count.to_u64
        raise "chunked substream mark count exceeds Int32"
      end
      event_count += count.to_u64
      count.times do
        name_size = context.read_var_uint
        context.read_slice(name_size)
      end
    end
    context.ensure_consumed
    event_count.to_i32
  end

  private def read_u64_le(bytes : Bytes, offset : Int32) : UInt64
    value = 0_u64
    8.times do |index|
      value |= bytes[offset + index].to_u64 << (index * 8)
    end
    value
  end

  private def write_u64_le(bytes : Bytes, offset : Int32, value : UInt64) : Nil
    8.times do |index|
      bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8
    end
  end
end
