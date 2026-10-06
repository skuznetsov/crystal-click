require "./spec_helper"

describe "W194 root physical-lane boundary controls" do
  it "inspects owned path sizes and immutable events without data snapshots" do
    input = Bytes[0x41_u8, 0x42_u8]
    event = CrystalClick::ObjectSharedPathSubstreamEvent.new("same", 0_u64)
    events = [event, event]
    streams = CrystalClick::ObjectSharedPathStreams.new(input, events)
    input[0] = 0_u8
    events.clear
    streams.data_size.should eq(2)
    streams.event_count.should eq(2)
    streams.data_byte_at(0).should eq(0x41_u8)
    streams.event_at(1).name.should eq("same")
    expect_raises(IndexError) { streams.data_byte_at(2) }
    expect_raises(IndexError) { streams.event_at(2) }
  end

  it "detaches names, model collections, and file descriptor paths" do
    name = String.new("a".to_slice)
    path = CrystalClick::ObjectSharedPhysicalPath.new(name,
      CrystalClick::ObjectSharedPathStreams.new(Bytes[0x41_u8], [
        CrystalClick::ObjectSharedPathSubstreamEvent.new("x", 0_u64),
      ]))
    paths = [path]
    chunk = CrystalClick::ObjectSharedPhysicalChunk.new(1_u64, paths)
    chunks = [chunk]
    parent = CrystalClick::ObjectSharedPhysicalParentMark.new(2_u64, chunks)
    name.to_unsafe[0] = 0x62_u8
    name_snapshot = path.name
    name_snapshot.to_unsafe[0] = 0x63_u8
    paths.clear
    chunks.clear
    chunk.paths.clear
    parent.chunks.clear
    parent.chunks[0].paths[0].name.should eq("a")

    data_path = String.new("data-path".to_slice)
    marks_path = String.new("mark-path".to_slice)
    lane = CrystalClick::ObjectSharedPhysicalLaneInput.new(data_path, marks_path, 1_i64, 48_i64)
    data_path.to_unsafe[0] = 0x78_u8
    marks_path.to_unsafe[0] = 0x78_u8
    data_snapshot = lane.data_path
    marks_snapshot = lane.marks_path
    data_snapshot.to_unsafe[0] = 0x78_u8
    marks_snapshot.to_unsafe[0] = 0x78_u8
    lane.data_path.should eq("data-path")
    lane.marks_path.should eq("mark-path")
    expect_raises(ArgumentError) do
      CrystalClick::ObjectSharedPhysicalChunk.new(0_u64, [path])
    end
  end
end

# These raw fields are authored independently of the physical bucket writer.
# Its paired transport is used only to package the six field streams.
private def w194_root_words(words : Array(UInt64)) : Bytes
  bytes = Bytes.new(words.size * 8, 0_u8)
  words.each_with_index do |word, index|
    8.times { |byte| bytes[index * 8 + byte] = ((word >> (byte * 8)) & 255_u64).to_u8 }
  end
  bytes
end

private def w194_root_raw_lanes : Hash(String, Bytes)
  suffix = w194_root_words([0_u64, 0_u64, 0_u64, 0_u64, 0_u64, 0_u64])
  structure = Bytes.new(4 + suffix.size)
  Bytes[1_u8, 1_u8, 1_u8, 0x61_u8].copy_to(structure[0, 4]) # one row, path "a"
  suffix.copy_to(structure[4, suffix.size])
  {
    "structure"                 => structure,
    "data"                      => Bytes[0x41_u8, 0x42_u8, 0x43_u8, 0x44_u8],
    "paths_marks"               => w194_root_words([0_u64, 0_u64]),
    "substreams"                => Bytes[2_u8, 1_u8, 0x78_u8, 1_u8, 0x78_u8], # duplicate "x"
    "substreams_marks"          => w194_root_words([0_u64, 0_u64, 30_u64, 0_u64]),
    "paths_substreams_metadata" => w194_root_words([0_u64, 0_u64, 0_u64, 0_u64]),
  }
end

private def w194_root_inputs(raw : Hash(String, Bytes), &) : Nil
  paths = [] of String
  inputs = {} of String => CrystalClick::ObjectSharedPhysicalLaneInput
  begin
    raw.each do |name, bytes|
      files = CrystalClick::CompressedMarkWriter.encode(bytes, [0_u64, bytes.size.to_u64], [2_u64], frame_bytes: 4)
      data_path = File.tempname("crystal-click-w194-root-#{name}-data")
      marks_path = File.tempname("crystal-click-w194-root-#{name}-marks")
      paths << data_path << marks_path
      data = files.data
      marks = files.marks
      File.open(data_path, "wb") { |io| io.write(data) }
      File.open(marks_path, "wb") { |io| io.write(marks) }
      inputs[name] = CrystalClick::ObjectSharedPhysicalLaneInput.new(data_path, marks_path, data.size.to_i64, marks.size.to_i64)
    end
    yield CrystalClick::ObjectSharedPhysicalBucketLaneInputs.new(inputs)
  ensure
    paths.each { |path| File.delete(path) if File.exists?(path) }
  end
end

private def w194_root_decode(inputs : CrystalClick::ObjectSharedPhysicalBucketLaneInputs)
  CrystalClick::ObjectSharedPhysicalBucketCodec.decode(
    3, inputs, [2_u64],
    CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
    CrystalClick::CompressedStreamBudget.read_default
  )
end

describe "W194 independently authored physical fields" do
  it "accepts duplicate callbacks and resolves canonical EOF from actual compression frames" do
    w194_root_inputs(w194_root_raw_lanes) do |inputs|
      parents = w194_root_decode(inputs)
      parents.size.should eq(1)
      parents[0].physical_rows.should eq(2_u64)
      chunk = parents[0].chunks[0]
      chunk.row_count.should eq(1_u64) # intentionally not physical_rows
      path = chunk.paths[0]
      path.name.should eq("a")
      path.streams.data.should eq(Bytes[0x41_u8, 0x42_u8, 0x43_u8, 0x44_u8])
      path.streams.events.map(&.name).should eq(["x", "x"])
      path.streams.events.map(&.relative_offset).should eq([0_u64, 4_u64])
    end
  end

  it "accepts a stock-style previous-frame-end alias instead of canonical physical EOF" do
    raw = w194_root_raw_lanes
    raw["substreams_marks"] = w194_root_words([0_u64, 0_u64, 0_u64, 4_u64])
    w194_root_inputs(raw) do |inputs|
      w194_root_decode(inputs)[0].chunks[0].paths[0].streams.events.last.relative_offset.should eq(4_u64)
    end
  end

  it "rejects source-derived corrupt coordinate/count/extent controls" do
    mutations = {
      "chunk Data starts after its outer interval" => {"structure", 12, 1_u8},
      "first path starts after its chunk"          => {"paths_marks", 8, 1_u8},
      "first event does not start at path zero"    => {"substreams_marks", 8, 1_u8},
      "compressed coordinate inside a frame"       => {"substreams_marks", 16, 1_u8},
      "event count exceeds names/mark extents"     => {"substreams", 0, 3_u8},
    }
    mutations.each do |label, mutation|
      raw = w194_root_raw_lanes
      name, offset, value = mutation
      raw[name][offset] = value
      w194_root_inputs(raw) do |inputs|
        expect_raises(CrystalClick::CorruptPartError, /./) { w194_root_decode(inputs) }
      end
    end
  end

  it "rejects unreferenced metadata tails and an event past its actual frame" do
    raw = w194_root_raw_lanes
    raw["substreams_marks"] = w194_root_words([0_u64, 0_u64, 0_u64, 5_u64])
    w194_root_inputs(raw) do |inputs|
      expect_raises(CrystalClick::CorruptPartError) { w194_root_decode(inputs) }
    end
    raw = w194_root_raw_lanes
    raw["paths_substreams_metadata"] = w194_root_words([0_u64, 0_u64, 0_u64, 0_u64, 0_u64])
    w194_root_inputs(raw) do |inputs|
      expect_raises(CrystalClick::CorruptPartError) { w194_root_decode(inputs) }
    end
  end

  it "rejects an attacker-selected enormous path count before count-derived retention" do
    raw = w194_root_raw_lanes
    prefix = Bytes[1_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 1_u8]
    structure = Bytes.new(prefix.size + 48, 0_u8)
    prefix.copy_to(structure)
    raw["structure"] = structure
    w194_root_inputs(raw) do |inputs|
      expect_raises(CrystalClick::CorruptPartError) { w194_root_decode(inputs) }
    end

    raw = w194_root_raw_lanes
    raw["substreams"] = Bytes[0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 1_u8]
    w194_root_inputs(raw) do |inputs|
      expect_raises(CrystalClick::CorruptPartError) { w194_root_decode(inputs) }
    end
  end

  it "keeps codec and transport limits cumulative across complete read operations" do
    w194_root_inputs(w194_root_raw_lanes) do |inputs|
      baseline_codec = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
      baseline_transport = CrystalClick::CompressedStreamBudget.read_default
      CrystalClick::ObjectSharedPhysicalBucketCodec.decode(3, inputs, [2_u64], baseline_codec, baseline_transport)
      baseline_codec.wire_byte_count.should be > 0_i64
      baseline_transport.file_byte_count.should be > 0_i64

      codec = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.new(
        max_depth: 64, max_nodes: 4096, max_elements: 1_000_000,
        max_bytes: baseline_codec.wire_byte_count * 2 - 1
      ))
      CrystalClick::ObjectSharedPhysicalBucketCodec.decode(3, inputs, [2_u64], codec, CrystalClick::CompressedStreamBudget.read_default)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::ObjectSharedPhysicalBucketCodec.decode(3, inputs, [2_u64], codec, CrystalClick::CompressedStreamBudget.read_default)
      end

      transport = CrystalClick::CompressedStreamBudget.new(CrystalClick::CompressedStreamLimits.new(
        max_file_bytes: baseline_transport.file_byte_count * 2 - 1
      ))
      CrystalClick::ObjectSharedPhysicalBucketCodec.decode(3, inputs, [2_u64],
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default), transport)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::ObjectSharedPhysicalBucketCodec.decode(3, inputs, [2_u64],
          CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default), transport)
      end
    end
  end

  it "keeps write budgets cumulative and rejects direction mismatches" do
    w194_root_inputs(w194_root_raw_lanes) do |inputs|
      parents = w194_root_decode(inputs)
      baseline_codec = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true)
      baseline_transport = CrystalClick::CompressedStreamBudget.write_default
      CrystalClick::ObjectSharedPhysicalBucketCodec.encode(3, parents, baseline_codec, baseline_transport, frame_bytes: 4)
      baseline_codec.wire_byte_count.should be > 0_i64

      codec = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.new(
        max_depth: 64, max_nodes: 4096, max_elements: 1_000_000,
        max_bytes: baseline_codec.wire_byte_count * 2 - 1
      ), true)
      CrystalClick::ObjectSharedPhysicalBucketCodec.encode(3, parents, codec, CrystalClick::CompressedStreamBudget.write_default, frame_bytes: 4)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectSharedPhysicalBucketCodec.encode(3, parents, codec, CrystalClick::CompressedStreamBudget.write_default, frame_bytes: 4)
      end
      expect_raises(ArgumentError) do
        CrystalClick::ObjectSharedPhysicalBucketCodec.encode(3, parents,
          CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default), CrystalClick::CompressedStreamBudget.write_default)
      end
      expect_raises(ArgumentError) do
        CrystalClick::ObjectSharedPhysicalBucketCodec.decode(3, inputs, [2_u64],
          CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true), CrystalClick::CompressedStreamBudget.read_default)
      end
    end
  end

  it "rejects zero metadata depth before retaining lanes or consuming transport work" do
    w194_root_inputs(w194_root_raw_lanes) do |inputs|
      parents = w194_root_decode(inputs)
      limits = CrystalClick::BinaryCodecLimits.new(0, 4096, 1_000_000, 64 * 1024 * 1024)
      write_codec = CrystalClick::BinaryCodecBudget.new(limits, true)
      write_transport = CrystalClick::CompressedStreamBudget.write_default
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectSharedPhysicalBucketCodec.encode(3, parents, write_codec, write_transport, frame_bytes: 4)
      end
      write_codec.wire_byte_count.should eq(0_i64)
      write_transport.file_byte_count.should eq(0_i64)

      read_codec = CrystalClick::BinaryCodecBudget.new(limits)
      read_transport = CrystalClick::CompressedStreamBudget.read_default
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::ObjectSharedPhysicalBucketCodec.decode(3, inputs, [2_u64], read_codec, read_transport)
      end
      read_codec.wire_byte_count.should eq(0_i64)
      read_transport.file_byte_count.should eq(0_i64)
    end
  end

  it "preflights logical lane bytes before compressed payload decoding" do
    w194_root_inputs(w194_root_raw_lanes) do |inputs|
      codec = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.new(
        64, 4096, 1_000_000, 0
      ))
      transport = CrystalClick::CompressedStreamBudget.read_default
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::ObjectSharedPhysicalBucketCodec.decode(3, inputs, [2_u64], codec, transport)
      end
      transport.decoded_byte_count.should eq(0_i64)
      codec.wire_byte_count.should eq(0_i64)
    end
  end
end
