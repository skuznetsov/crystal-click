require "./spec_helper"

private def w120_guard_limits(nodes : Int = 4, elements : Int = 2, bytes : Int = 24)
  CrystalClick::BinaryCodecLimits.new(
    max_depth: 1, max_nodes: nodes, max_elements: elements, max_bytes: bytes
  )
end

describe "W120 independent metadata contract guards" do
  it "uses order-independent shared-map identity without erasing positional count order" do
    left = CrystalClick::StructureStatistics.new(
      [4_u64, 8_u64],
      [CrystalClick::StructureStatistic.new("z", 3_u64), CrystalClick::StructureStatistic.new("a", 5_u64)]
    )
    right = CrystalClick::StructureStatistics.new(
      [4_u64, 8_u64],
      [CrystalClick::StructureStatistic.new("a", 5_u64), CrystalClick::StructureStatistic.new("z", 3_u64)]
    )
    left.should eq(right)
    left.hash.should eq(right.hash)
    indexed = {left => 1}
    indexed[right].should eq(1)
    reversed_counts = CrystalClick::StructureStatistics.new([8_u64, 4_u64], right.shared)
    left.should_not eq(reversed_counts)
    changed_shared = CrystalClick::StructureStatistics.new(
      [4_u64, 8_u64],
      [CrystalClick::StructureStatistic.new("a", 6_u64), CrystalClick::StructureStatistic.new("z", 3_u64)]
    )
    left.should_not eq(changed_shared)
    changed_name = CrystalClick::StructureStatistics.new(
      [4_u64, 8_u64],
      [CrystalClick::StructureStatistic.new("a", 5_u64), CrystalClick::StructureStatistic.new("x", 3_u64)]
    )
    left.should_not eq(changed_name)

    dynamic = CrystalClick::DynamicStructure.new(
      [CrystalClick::BinaryDataType.primitive("UInt8")], statistics: left
    )
    # Canonical re-emission sorts shared entries, not the descriptor or counts.
    wire = Bytes[4, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 4, 8, 2, 1, 97, 5, 1, 122, 3]
    CrystalClick::DynamicStructureCodec.encode(dynamic).should eq(wire)
    CrystalClick::DynamicStructureCodec.decode(wire).should eq(dynamic)
  end

  it "classifies unknown structure versions as corruption, not recognized unsupported profiles" do
    [Bytes[5, 0, 0, 0, 0, 0, 0, 0], Bytes.new(8, 0xff_u8)].each do |unknown|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::ObjectStructureCodec.decode(unknown)
      end
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::DynamicStructureCodec.decode(unknown)
      end
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicStructureCodec.decode(Bytes.new(8, 0_u8))
    end
  end

  it "charges four literal nodes and two collection edges in both directions" do
    object = CrystalClick::ObjectStructure.new(["p"])
    dynamic = CrystalClick::DynamicStructure.new([CrystalClick::BinaryDataType.primitive("UInt8")])
    set = CrystalClick::ObjectDynamicStructureSet.new(object, {"p" => dynamic})
    # Object root/path and Dynamic root/descriptor; no synthetic batch root.
    # The header bytes are independently authored, not obtained via encode.
    object_wire = Bytes[4, 0, 0, 0, 0, 0, 0, 0, 1, 1, 112, 0, 0]
    dynamic_wire = Bytes[4, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0]
    streams = CrystalClick::ObjectDynamicStructureStreams.new(object_wire, {"p" => dynamic_wire})
    exact = w120_guard_limits
    encoded = CrystalClick::ObjectDynamicStructureCodec.encode(set, exact)
    encoded.object.should eq(object_wire)
    encoded.dynamics["p"].should eq(dynamic_wire)
    CrystalClick::ObjectDynamicStructureCodec.decode(streams, exact).object.dynamic_paths.should eq(["p"])

    [w120_guard_limits(nodes: 3), w120_guard_limits(elements: 1), w120_guard_limits(bytes: 23)].each do |limit|
      # Each stream fits alone. The batch must not reset limits per child.
      CrystalClick::ObjectStructureCodec.encode(object, limit).should eq(object_wire)
      CrystalClick::DynamicStructureCodec.encode(dynamic, limit).should eq(dynamic_wire)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDynamicStructureCodec.encode(set, limit)
      end
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::ObjectDynamicStructureCodec.decode(streams, limit)
      end
    end
  end

  it "preflights all input bytes before parsing even the first malformed header" do
    streams = CrystalClick::ObjectDynamicStructureStreams.new(
      Bytes[0xaa], {"p" => Bytes[4, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0]}
    )
    error = expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectDynamicStructureCodec.decode(streams, w120_guard_limits(bytes: 11))
    end
    error.message.not_nil!.should contain("byte")
  end

  it "keeps descriptor depth and child charges inside the enclosing Dynamic budget" do
    type = CrystalClick::BinaryDataType.array(
      CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.primitive("UInt8"))
    )
    dynamic = CrystalClick::DynamicStructure.new([type])
    wire = Bytes[4, 0, 0, 0, 0, 0, 0, 0, 1, 0x1e, 0x23, 1, 0]
    exact = CrystalClick::BinaryCodecLimits.new(max_depth: 3, max_nodes: 4, max_elements: 3, max_bytes: 13)
    CrystalClick::DynamicStructureCodec.encode(dynamic, exact).should eq(wire)
    CrystalClick::DynamicStructureCodec.decode(wire, exact).types.should eq([type])
    shallow = CrystalClick::BinaryCodecLimits.new(max_depth: 2, max_nodes: 4, max_elements: 3, max_bytes: 13)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::DynamicStructureCodec.encode(dynamic, shallow)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicStructureCodec.decode(wire, shallow)
    end
  end

  it "rejects oversized input before any detached accessor copies the wire slices" do
    # Model construction owns the caller's input before the measured operation.
    large = Bytes.new(2 * 1024 * 1024, 0_u8)
    streams = CrystalClick::ObjectDynamicStructureStreams.new(large, {} of String => Bytes)
    GC.stats
    before = GC.stats.total_bytes
    error = expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectDynamicStructureCodec.decode(streams, w120_guard_limits(bytes: 1))
    end
    error.message.not_nil!.should contain("byte")
    (GC.stats.total_bytes - before).should be < 131_072_u64
  end

  it "preflights Object shared statistics before detaching any large reordered collection" do
    # Caller-owned model construction is outside the measured codec operation.
    shared = Array(CrystalClick::StructureStatistic).new(32_768) do |index|
      CrystalClick::StructureStatistic.new(index.to_s, 0_u64)
    end
    stats = CrystalClick::StructureStatistics.new([] of UInt64, shared)
    object = CrystalClick::ObjectStructure.new([] of String, statistics: stats)
    limits = CrystalClick::BinaryCodecLimits.new(max_depth: 1, max_nodes: 1, max_elements: 0, max_bytes: 4096)
    GC.stats
    before = GC.stats.total_bytes
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectStructureCodec.encode(object, limits)
    end
    (GC.stats.total_bytes - before).should be < 131_072_u64
  end

  it "rejects an oversized foreign Dynamic roster before copying all its keys" do
    foreign = {} of String => Bytes
    32_768.times { |index| foreign[index.to_s] = Bytes.empty }
    streams = CrystalClick::ObjectDynamicStructureStreams.new(
      Bytes[4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], foreign
    )
    limits = CrystalClick::BinaryCodecLimits.new(max_depth: 1, max_nodes: 1, max_elements: 0, max_bytes: 11)
    GC.stats
    before = GC.stats.total_bytes
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectDynamicStructureCodec.decode(streams, limits)
    end
    (GC.stats.total_bytes - before).should be < 131_072_u64

    # Equal key counts must not bypass this guard through one huge wrong key.
    huge_key = "x" * (2 * 1024 * 1024)
    wrong_name = CrystalClick::ObjectDynamicStructureStreams.new(
      Bytes[4, 0, 0, 0, 0, 0, 0, 0, 1, 1, 112, 0, 0], {huge_key => Bytes.empty}
    )
    key_limits = CrystalClick::BinaryCodecLimits.new(max_depth: 1, max_nodes: 2, max_elements: 1, max_bytes: 13)
    GC.stats
    before_key = GC.stats.total_bytes
    error = expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectDynamicStructureCodec.decode(wrong_name, key_limits)
    end
    error.message.not_nil!.should contain("missing")
    (GC.stats.total_bytes - before_key).should be < 131_072_u64
  end
end
