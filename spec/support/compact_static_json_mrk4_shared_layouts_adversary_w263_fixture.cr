require "file_utils"
require "../../scripts/support/compact_json_w263_fixture"
require "../../scripts/support/compact_physical_context_w259_fixture"
require "./compact_static_json_w263_adversary_fixture"
require "./compact_static_json_mrk4_chunked_w263_fixture"

module CompactStaticJsonMrk4SharedLayoutsAdversaryW263Fixture
  extend self

  MAP_WITH_BUCKETS = "map_with_buckets"
  ADVANCED         = "advanced"
  ROWS             = [2_u64, 2_u64, 2_u64, 2_u64]
  FRAME_BYTES      = 4096

  alias SlotSpan = Tuple(Int32, String?, Int64, Int64)

  def source_part(label : String) : NamedTuple(path: String, inventory: Array(Tuple(String, Int64, String)))
    CompactStaticJsonW263AdversaryFixture.source_part(
      CompactStaticJsonW263AdversaryFixture.evidence_root,
      label,
    )
  end

  def copy_part(source_path : String) : Tuple(String, String)
    CompactStaticJsonW263AdversaryFixture.copy_part(source_path)
  end

  def label(layout : String, string_version : Int32 = 0, variant : String = "basic") : String
    "obj_v3_dyn_v3_#{layout}_mrk4_s#{string_version}_variant_#{variant}"
  end

  def callback_count(layout : String, string_version : Int32) : Int32
    base = layout == MAP_WITH_BUCKETS ? 19 : 30
    base + (string_version == 1 ? 4 : 0)
  end

  def assert_native_profile!(physical : CrystalClick::CompactPartPhysicalContext, layout : String, string_version : Int32) : Array(String)
    physical.mode.mrk4?.should be_true
    physical.row_count.should eq(8_u64)
    physical.mark_row_counts.should eq(ROWS)
    names = physical.physical_roster.select { |slot| slot.column_name == "root" }.map do |slot|
      slot.stream_name || raise(CrystalClick::CorruptPartError.new("native MRK4 root callback has no stream name"))
    end
    names.size.should eq(callback_count(layout, string_version))
    names.includes?("root.object_structure").should be_true
    names.includes?(copy_stream_for(layout)).should be_true
    if layout == MAP_WITH_BUCKETS
      names.includes?("root.object_shared_data.1%2Epaths").should be_true
    end

    first = physical.read_window("root", 0, 1).granules.first? ||
            raise(CrystalClick::CorruptPartError.new("native MRK4 root mark zero is absent"))
    object = first.shards.find { |shard| shard.stream_name == "root.object_structure" } ||
             raise(CrystalClick::CorruptPartError.new("native MRK4 Object prefix is absent"))
    context = CrystalClick::BinaryCodecContext.new(CrystalClick::BinaryCodecLimits.default, object.bytes)
    structure, _statistics_offset = CrystalClick::ObjectStructureCodec.read_with_statistics_offset(context)
    context.ensure_consumed
    structure.version.should eq(4_u64)
    structure.shared_data_version.should eq(layout == MAP_WITH_BUCKETS ? 1_u64 : 2_u64)
    structure.bucket_count.should eq(2_u64)
    names
  end

  def copy_stream_for(layout : String) : String
    layout == MAP_WITH_BUCKETS ? "root.object_shared_data.1%2Evalues" : "root.object_shared_data.copy.values"
  end

  # Reframe a pristine source before a fixed-length mutation. The ordinary
  # MAP_WITH_BUCKETS layout has only outer mark coordinates; ADVANCED also
  # carries persisted shared-data pairs and uses the existing authenticated
  # pair remapper. In both cases the logical tape length is unchanged.
  def reframe_pristine!(part_path : String, layout : String) : Bytes
    physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
    raw = read_logical_data(part_path)
    if layout == MAP_WITH_BUCKETS
      reframe_plain_mrk4!(part_path, physical, raw)
    elsif layout == ADVANCED
      CompactStaticJsonMrk4ChunkedW263Fixture.rewrite_mrk4_tape!(part_path, physical, raw)
    else
      raise ArgumentError.new("unknown shared layout #{layout}")
    end
    read_logical_data(part_path).should eq(raw)
    raw
  end

  # The literal writer's compressed frame geometry depends only on the
  # logical length. Once a pristine Advanced rewrite has remapped every saved
  # pair, a same-length poison can be re-encoded without moving any pair.
  def write_same_geometry_tape!(part_path : String, raw : Bytes) : CrystalClick::CompactPartPhysicalContext
    before = CrystalClick::CompactPartPhysicalContext.open(part_path)
    before_grid = slot_grid(before)
    before_frames = frame_geometry(part_path)
    File.write(
      File.join(part_path, "data.bin"),
      CrystalClick::CompressedMarkWriter.encode_all(raw, frame_bytes: FRAME_BYTES),
    )
    CompactPhysicalContextW259Fixture.refresh_checksums(part_path)

    reopened = CrystalClick::CompactPartPhysicalContext.open(part_path)
    reopened.mark_row_counts.should eq(ROWS)
    slot_grid(reopened).should eq(before_grid)
    frame_geometry(part_path).should eq(before_frames)
    read_logical_data(part_path).should eq(raw)
    reopened
  end

  def assert_callback_bytes!(
    physical : CrystalClick::CompactPartPhysicalContext,
    mark_index : Int32,
    stream_name : String,
    expected_hex : String,
  ) : CrystalClick::CompactPartPhysicalShard
    granule = physical.read_window("root", mark_index, 1).granules.first? ||
              raise(CrystalClick::CorruptPartError.new("selected root mark is absent"))
    shard = granule.shards.find { |candidate| candidate.stream_name == stream_name } ||
            raise(CrystalClick::CorruptPartError.new("selected callback #{stream_name} is absent"))
    shard.bytes.hexstring.should eq(expected_hex)
    shard
  end

  def object_bucket_count_offset!(bytes : Bytes, expected_shared_version : UInt64) : Int32
    context = CrystalClick::BinaryCodecContext.new(CrystalClick::BinaryCodecLimits.default, bytes)
    context.read_slice(8_u64)
    path_count = context.read_var_uint
    path_count.times do
      context.read_slice(context.read_var_uint)
    end
    context.read_var_uint.should eq(expected_shared_version)
    offset = context.input_offset
    context.read_var_uint.should eq(2_u64)
    structure_context = CrystalClick::BinaryCodecContext.new(CrystalClick::BinaryCodecLimits.default, bytes)
    structure, _statistics_offset = CrystalClick::ObjectStructureCodec.read_with_statistics_offset(structure_context)
    structure_context.ensure_consumed
    structure.version.should eq(4_u64)
    structure.bucket_count.should eq(2_u64)
    offset
  end

  def root_granule(physical : CrystalClick::CompactPartPhysicalContext, mark_index : Int32) : CrystalClick::CompactPartPhysicalGranule
    physical.read_window("root", mark_index, 1).granules.first? ||
      raise(CrystalClick::CorruptPartError.new("selected root mark is absent"))
  end

  private def reframe_plain_mrk4!(
    part_path : String,
    physical : CrystalClick::CompactPartPhysicalContext,
    raw : Bytes,
  ) : Nil
    unless physical.mode.mrk4? && physical.mark_row_counts == ROWS
      raise "plain MRK4 reframe requires the authenticated four-mark grid"
    end
    slots = physical.physical_roster
    raise "plain MRK4 reframe has no physical slots" if slots.empty?

    grid = Array(Array(CrystalClick::CompactPartPhysicalShard?)).new(physical.granule_count) do
      Array(CrystalClick::CompactPartPhysicalShard?).new(slots.size, nil)
    end
    columns = [] of String
    slots.each { |slot| columns << slot.column_name unless columns.includes?(slot.column_name) }
    columns.each do |column_name|
      window = physical.read_window(column_name, 0, physical.granule_count)
      window.granules.each_with_index do |granule, mark_index|
        granule.shards.each do |shard|
          unless shard.slot_index >= 0 && shard.slot_index < slots.size && slots[shard.slot_index].column_name == column_name
            raise "plain MRK4 reframe observed a shard outside its authenticated slot roster"
          end
          raise "plain MRK4 reframe duplicated a physical slot" if grid[mark_index][shard.slot_index]
          grid[mark_index][shard.slot_index] = shard
        end
      end
    end

    spans_before = slot_grid(physical)
    queries = [] of UInt64
    physical.granule_count.times do |mark_index|
      slots.size.times do |slot_index|
        shard = grid[mark_index][slot_index] || raise "plain MRK4 reframe missed a physical slot"
        queries << shard.logical_start.to_u64
      end
    end
    slots.size.times { queries << raw.size.to_u64 }
    positions = CrystalClick::CompressedMarkWriter.plan_literal_positions(
      raw.size.to_i64,
      queries,
      frame_bytes: FRAME_BYTES,
    )
    positions.size.should eq(queries.size)

    record_width = slots.size * 16 + 8
    marks = Bytes.new((physical.granule_count + 1) * record_width, 0_u8)
    physical.granule_count.times do |mark_index|
      slots.size.times do |slot_index|
        pair = positions[mark_index * slots.size + slot_index]
        write_u64_le(marks, mark_index * record_width + slot_index * 16, pair[0])
        write_u64_le(marks, mark_index * record_width + slot_index * 16 + 8, pair[1])
      end
      write_u64_le(marks, mark_index * record_width + slots.size * 16, physical.mark_row_counts[mark_index])
    end
    slots.size.times do |slot_index|
      pair = positions[physical.granule_count * slots.size + slot_index]
      write_u64_le(marks, physical.granule_count * record_width + slot_index * 16, pair[0])
      write_u64_le(marks, physical.granule_count * record_width + slot_index * 16 + 8, pair[1])
    end
    write_u64_le(marks, physical.granule_count * record_width + slots.size * 16, 0_u64)

    File.write(
      File.join(part_path, "data.bin"),
      CrystalClick::CompressedMarkWriter.encode_all(raw, frame_bytes: FRAME_BYTES),
    )
    File.write(File.join(part_path, "data.mrk4"), marks)
    CompactPhysicalContextW259Fixture.refresh_checksums(part_path)

    reopened = CrystalClick::CompactPartPhysicalContext.open(part_path)
    reopened.row_count.should eq(physical.row_count)
    reopened.mark_row_counts.should eq(ROWS)
    slot_grid(reopened).should eq(spans_before)
    read_logical_data(part_path).should eq(raw)
    nil
  end

  private def slot_grid(physical : CrystalClick::CompactPartPhysicalContext) : Array(Array(SlotSpan))
    slots = physical.physical_roster
    columns = [] of String
    slots.each { |slot| columns << slot.column_name unless columns.includes?(slot.column_name) }
    grid = Array(Array(SlotSpan)).new(physical.granule_count) { [] of SlotSpan }
    columns.each do |column_name|
      window = physical.read_window(column_name, 0, physical.granule_count)
      window.granules.each_with_index do |granule, mark_index|
        granule.shards.each do |shard|
          grid[mark_index] << {shard.slot_index, shard.stream_name, shard.logical_start, shard.logical_end}
        end
      end
    end
    grid.each(&.sort_by!(&.[0]))
    grid
  end

  private def frame_geometry(part_path : String) : Array(Tuple(Int64, Int64, Int64, Int64, UInt8))
    data = File.read(File.join(part_path, "data.bin")).to_slice
    index = CrystalClick::CompressedFrameIndex.new(
      data,
      CrystalClick::CompressedStreamLimits.new,
      CrystalClick::CompressedStreamBudget.read_default,
    )
    index.frames.map do |frame|
      {frame.compressed_offset, frame.end_offset, frame.logical_start, frame.logical_end, frame.method}
    end
  end

  private def read_logical_data(part_path : String) : Bytes
    path = File.join(part_path, "data.bin")
    CrystalClick::CompressedMarkReader.read_all(path, File.size(path).to_i64)
  end

  private def write_u64_le(bytes : Bytes, offset : Int32, value : UInt64) : Nil
    8.times do |index|
      bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8
    end
  end
end
