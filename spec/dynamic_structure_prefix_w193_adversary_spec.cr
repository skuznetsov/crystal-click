require "./spec_helper"

describe "W193 Dynamic no-statistics prefix boundary" do
  it "omits the entire statistics suffix and does not accept complete-blob framing as a prefix" do
    int64 = CrystalClick::BinaryDataType.primitive("Int64")
    structure = CrystalClick::DynamicStructure.new([int64])
    prefix = Bytes[4, 0, 0, 0, 0, 0, 0, 0, 1, 0x0a]
    complete = Bytes[4, 0, 0, 0, 0, 0, 0, 0, 1, 0x0a, 0]
    CrystalClick::DynamicStructureCodec.encode_prefix_without_statistics(structure).should eq(prefix)
    CrystalClick::DynamicStructureCodec.encode(structure).should eq(complete)
    decoded = CrystalClick::DynamicStructureCodec.decode_prefix_without_statistics(prefix)
    decoded.types.should eq([int64])
    decoded.statistics.should be_nil
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicStructureCodec.decode_prefix_without_statistics(complete)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicStructureCodec.decode(prefix)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicStructureCodec.decode_prefix_without_statistics(prefix[0, prefix.size - 1])
    end
  end

  it "preserves the known-version error distinction in prefix mode" do
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::DynamicStructureCodec.decode_prefix_without_statistics(Bytes[2, 0, 0, 0, 0, 0, 0, 0, 0])
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicStructureCodec.decode_prefix_without_statistics(Bytes[3, 0, 0, 0, 0, 0, 0, 0, 0])
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicStructureCodec.decode_prefix_without_statistics(Bytes[4, 0, 0, 0, 0, 0, 0, 0, 0x80, 0])
    end
  end

  it "uses the original direction-specific shared budget across prefix operations" do
    structure = CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)
    prefix = Bytes[4, 0, 0, 0, 0, 0, 0, 0, 0]
    limits = CrystalClick::BinaryCodecLimits.new(64, 4_096, 1_000_000, 9)
    writing = CrystalClick::BinaryCodecBudget.new(limits, true)
    context = CrystalClick::BinaryCodecContext.new(limits, nil, true, writing)
    CrystalClick::DynamicStructureCodec.write_prefix_without_statistics(structure, context)
    context.finish_bytes.should eq(prefix)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      next_context = CrystalClick::BinaryCodecContext.new(limits, nil, true, writing)
      CrystalClick::DynamicStructureCodec.write_prefix_without_statistics(structure, next_context)
    end
    reading = CrystalClick::BinaryCodecBudget.new(limits)
    read_context = CrystalClick::BinaryCodecContext.new(limits, prefix, false, reading)
    CrystalClick::DynamicStructureCodec.read_prefix_without_statistics(read_context).types.should be_empty
    read_context.ensure_consumed
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryCodecContext.new(limits, prefix, false, reading)
    end
  end
end
