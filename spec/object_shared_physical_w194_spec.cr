require "./spec_helper"

private def w194_physical_stream(
  bytes : Bytes,
  events : Array(CrystalClick::ObjectSharedPathSubstreamEvent),
) : CrystalClick::ObjectSharedPathStreams
  CrystalClick::ObjectSharedPathStreams.new(bytes, events)
end

private def w194_physical_path(
  name : String,
  bytes : Bytes,
  events : Array(CrystalClick::ObjectSharedPathSubstreamEvent),
) : CrystalClick::ObjectSharedPhysicalPath
  CrystalClick::ObjectSharedPhysicalPath.new(name, w194_physical_stream(bytes, events))
end

private def w194_physical_fixture : Array(CrystalClick::ObjectSharedPhysicalParentMark)
  event = CrystalClick::ObjectSharedPathSubstreamEvent
  first_chunk = CrystalClick::ObjectSharedPhysicalChunk.new(1_u64, [
    w194_physical_path("alpha", Bytes[0xa1_u8, 0xa2_u8, 0xa3_u8], [
      event.new("value", 0_u64), event.new("value", 0_u64), event.new("size", 3_u64),
    ]),
    w194_physical_path("omega", Bytes[0xb1_u8], [event.new("value", 0_u64)]),
  ])
  zero_chunk = CrystalClick::ObjectSharedPhysicalChunk.new(0_u64, [] of CrystalClick::ObjectSharedPhysicalPath)
  last_chunk = CrystalClick::ObjectSharedPhysicalChunk.new(2_u64, [
    w194_physical_path("alpha", Bytes[0xc1_u8, 0xc2_u8], [
      event.new("value", 0_u64), event.new("value", 1_u64),
    ]),
  ])
  second_parent_chunk = CrystalClick::ObjectSharedPhysicalChunk.new(4_u64, [
    w194_physical_path("beta", Bytes[0xd1_u8], [event.new("value", 0_u64)]),
  ])

  [
    CrystalClick::ObjectSharedPhysicalParentMark.new(2_u64, [first_chunk, zero_chunk, last_chunk]),
    CrystalClick::ObjectSharedPhysicalParentMark.new(1_u64, [second_parent_chunk]),
  ]
end

private def w194_write_physical_inputs(
  files : CrystalClick::ObjectSharedPhysicalBucketFiles,
  override_name : String? = nil,
  override_files : CrystalClick::CompressedMarkFiles? = nil,
  &
) : Nil
  lane_names = [
    "structure", "data", "paths_marks", "substreams", "substreams_marks", "paths_substreams_metadata",
  ]
  temporary_paths = [] of String
  descriptors = Hash(String, CrystalClick::ObjectSharedPhysicalLaneInput).new
  begin
    lane_names.each do |name|
      lane = if override_name == name
               override_files || raise "missing W194 override files"
             else
               files.lane(name)
             end
      data_path = File.tempname("crystal-click-w194-#{name}-data")
      marks_path = File.tempname("crystal-click-w194-#{name}-marks")
      temporary_paths << data_path
      temporary_paths << marks_path
      data = lane.data
      marks = lane.marks
      File.open(data_path, "wb") { |io| io.write(data) }
      File.open(marks_path, "wb") { |io| io.write(marks) }
      descriptors[name] = CrystalClick::ObjectSharedPhysicalLaneInput.new(
        data_path, marks_path, data.size.to_i64, marks.size.to_i64
      )
    end
    yield CrystalClick::ObjectSharedPhysicalBucketLaneInputs.new(descriptors)
  ensure
    temporary_paths.each { |path| File.delete(path) if File.exists?(path) }
  end
end

private def w194_mark_rows(marks : Bytes) : Array(UInt64)
  raise "W194 marks must contain complete records" unless marks.size % CrystalClick::CompressedMarkWriter::MARK_RECORD_SIZE == 0
  mark_count = marks.size // CrystalClick::CompressedMarkWriter::MARK_RECORD_SIZE
  Array(UInt64).new(mark_count) do |record_index|
    offset = record_index * CrystalClick::CompressedMarkWriter::MARK_RECORD_SIZE + 16
    value = 0_u64
    8.times { |index| value |= marks[offset + index].to_u64 << (index * 8) }
    value
  end
end

private def w194_assert_physical_parents(
  expected : Array(CrystalClick::ObjectSharedPhysicalParentMark),
  actual : Array(CrystalClick::ObjectSharedPhysicalParentMark),
) : Nil
  actual.size.should eq(expected.size)
  expected.each_with_index do |parent, parent_index|
    observed = actual[parent_index]
    observed.physical_rows.should eq(parent.physical_rows)
    observed.chunks.size.should eq(parent.chunks.size)
    parent.chunks.each_with_index do |chunk, chunk_index|
      observed_chunk = observed.chunks[chunk_index]
      observed_chunk.row_count.should eq(chunk.row_count)
      observed_chunk.paths.size.should eq(chunk.paths.size)
      chunk.paths.each_with_index do |path, path_index|
        observed_path = observed_chunk.paths[path_index]
        observed_path.name.should eq(path.name)
        observed_path.streams.data.should eq(path.streams.data)
        observed_events = observed_path.streams.events
        expected_events = path.streams.events
        observed_events.size.should eq(expected_events.size)
        expected_events.each_with_index do |event, event_index|
          observed_events[event_index].name.should eq(event.name)
          observed_events[event_index].relative_offset.should eq(event.relative_offset)
        end
      end
    end
  end
end

describe "W194 physical Object shared-data bucket lanes" do
  it "round trips six paired lanes without conflating parent marks and logical chunks" do
    parents = w194_physical_fixture
    expected_parent_rows = parents.map(&.physical_rows)
    codec_write_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true)
    transport_write_budget = CrystalClick::CompressedStreamBudget.write_default

    files = CrystalClick::ObjectSharedPhysicalBucketCodec.encode(
      3, parents, codec_write_budget, transport_write_budget, frame_bytes: 7
    )

    lane_names = [
      "structure", "data", "paths_marks", "substreams", "substreams_marks", "paths_substreams_metadata",
    ]
    lane_names.each do |name|
      lane = files.lane(name)
      w194_mark_rows(lane.marks).should eq([2_u64, 1_u64, 0_u64])
      data_snapshot = lane.data
      if !data_snapshot.empty?
        first_byte = data_snapshot[0]
        data_snapshot[0] ^= 0xff_u8
        files.lane(name).data[0].should eq(first_byte)
      end
    end
    codec_write_budget.wire_byte_count.should be > 0_i64
    transport_write_budget.file_byte_count.should be > 0_i64

    w194_write_physical_inputs(files) do |lane_inputs|
      codec_read_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
      transport_read_budget = CrystalClick::CompressedStreamBudget.read_default
      decoded = CrystalClick::ObjectSharedPhysicalBucketCodec.decode(
        3, lane_inputs, expected_parent_rows, codec_read_budget, transport_read_budget
      )

      w194_assert_physical_parents(parents, decoded)
      decoded.map(&.physical_rows).should eq([2_u64, 1_u64])
      decoded[0].chunks.map(&.row_count).should eq([1_u64, 0_u64, 2_u64])
      decoded[1].chunks.map(&.row_count).should eq([4_u64])
      # The first path deliberately has duplicate callback names and equal
      # offsets. They remain separate ordered events after transport assembly.
      duplicate_events = decoded[0].chunks[0].paths[0].streams.events
      duplicate_events.map(&.name).should eq(["value", "value", "size"])
      duplicate_events.map(&.relative_offset).should eq([0_u64, 0_u64, 3_u64])
      codec_read_budget.wire_byte_count.should be > 0_i64
      transport_read_budget.decoded_byte_count.should be > 0_i64
    end
  end

  it "supports v2's one-chunk-per-parent form and rejects cross-lane outer-grid disagreement" do
    path = w194_physical_path("p", Bytes[0x41_u8], [
      CrystalClick::ObjectSharedPathSubstreamEvent.new("value", 0_u64),
    ])
    parents = [CrystalClick::ObjectSharedPhysicalParentMark.new(2_u64, [
      CrystalClick::ObjectSharedPhysicalChunk.new(2_u64, [path]),
    ])]
    files = CrystalClick::ObjectSharedPhysicalBucketCodec.encode(
      2,
      parents,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
      CrystalClick::CompressedStreamBudget.write_default,
      frame_bytes: 5
    )

    w194_write_physical_inputs(files) do |lane_inputs|
      decoded = CrystalClick::ObjectSharedPhysicalBucketCodec.decode(
        2,
        lane_inputs,
        [2_u64],
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
        CrystalClick::CompressedStreamBudget.read_default
      )
      w194_assert_physical_parents(parents, decoded)
    end

    # A locally valid adaptive grid with a different physical row partition
    # must not be admitted as the Data lane of the otherwise matching bucket.
    replacement = CrystalClick::CompressedMarkWriter.encode(
      Bytes[0x61_u8, 0x62_u8], [0_u64, 1_u64, 2_u64], [1_u64, 1_u64], frame_bytes: 5
    )
    w194_write_physical_inputs(files, "data", replacement) do |lane_inputs|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::ObjectSharedPhysicalBucketCodec.decode(
          2,
          lane_inputs,
          [2_u64],
          CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
          CrystalClick::CompressedStreamBudget.read_default
        )
      end
    end
  end

  it "rejects malformed logical path rosters, chunk forms, versions, and unbounded event tapes" do
    event = CrystalClick::ObjectSharedPathSubstreamEvent
    path_a = w194_physical_path("a", Bytes[0x41_u8], [event.new("v", 0_u64)])
    path_b = w194_physical_path("b", Bytes[0x42_u8], [event.new("v", 0_u64)])

    expect_raises(ArgumentError) do
      CrystalClick::ObjectSharedPhysicalChunk.new(1_u64, [path_b, path_a])
    end
    expect_raises(ArgumentError) do
      CrystalClick::ObjectSharedPhysicalChunk.new(1_u64, [path_a, path_a])
    end
    expect_raises(ArgumentError) do
      CrystalClick::ObjectSharedPhysicalParentMark.new(0_u64, [
        CrystalClick::ObjectSharedPhysicalChunk.new(0_u64, [] of CrystalClick::ObjectSharedPhysicalPath),
      ])
    end

    expect_raises(ArgumentError) do
      w194_physical_path("a", Bytes[0x41_u8, 0x42_u8], [event.new("v", 1_u64)])
    end
    expect_raises(ArgumentError) do
      w194_physical_path("a", Bytes[0x41_u8], [] of CrystalClick::ObjectSharedPathSubstreamEvent)
    end

    expect_raises(ArgumentError) do
      CrystalClick::ObjectSharedPhysicalBucketCodec.encode(
        2,
        [CrystalClick::ObjectSharedPhysicalParentMark.new(1_u64, [
          CrystalClick::ObjectSharedPhysicalChunk.new(0_u64, [] of CrystalClick::ObjectSharedPhysicalPath),
          CrystalClick::ObjectSharedPhysicalChunk.new(1_u64, [] of CrystalClick::ObjectSharedPhysicalPath),
        ])],
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
        CrystalClick::CompressedStreamBudget.write_default
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectSharedPhysicalBucketCodec.encode(
        1,
        [CrystalClick::ObjectSharedPhysicalParentMark.new(1_u64, [
          CrystalClick::ObjectSharedPhysicalChunk.new(1_u64, [path_a]),
        ])],
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
        CrystalClick::CompressedStreamBudget.write_default
      )
    end
  end
end
