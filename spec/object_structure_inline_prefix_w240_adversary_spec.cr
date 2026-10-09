require "./spec_helper"

private def w240_object_prefix_read(
  bytes : Bytes,
  budget : CrystalClick::BinaryCodecBudget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
  depth : Int32 = 1_i32,
) : CrystalClick::ObjectStructure
  context = CrystalClick::BinaryCodecContext.new(budget.limits, bytes, false, budget)
  structure, offset = CrystalClick::ObjectStructureCodec.read_prefix_without_statistics(context, depth)
  offset.should eq(context.input_offset)
  context.ensure_consumed
  structure
end

describe "W240 inline Object no-statistics prefix adversary" do
  it "consumes a literal Object V3 header without synthesizing or accepting a statistics flag" do
    # Object V3, no Dynamic paths, ADVANCED_CHUNKED, two buckets. There is
    # deliberately no statistics flag: nested serializers use mode NONE.
    prefix = Bytes[4, 0, 0, 0, 0, 0, 0, 0, 0, 3, 2]
    structure = w240_object_prefix_read(prefix)
    structure.version.should eq(4_u64)
    structure.dynamic_paths.should be_empty
    structure.shared_data_version.should eq(3_u64)
    structure.bucket_count.should eq(2_u64)
    structure.statistics.should be_nil

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectStructureCodec.decode(prefix)
    end
    complete = Bytes[4, 0, 0, 0, 0, 0, 0, 0, 0, 3, 2, 0]
    expect_raises(CrystalClick::CorruptPartError) { w240_object_prefix_read(complete) }
    CrystalClick::ObjectStructureCodec.decode(complete).shared_data_version.should eq(3_u64)
  end

  it "retains known-version rejection and invalid shared-layout distinctions" do
    [0_u8, 2_u8].each do |version|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        w240_object_prefix_read(Bytes[version, 0, 0, 0, 0, 0, 0, 0])
      end
    end
    [1_u8, 3_u8, 5_u8].each do |version|
      expect_raises(CrystalClick::CorruptPartError) do
        w240_object_prefix_read(Bytes[version, 0, 0, 0, 0, 0, 0, 0])
      end
    end
    expect_raises(CrystalClick::CorruptPartError) do
      w240_object_prefix_read(Bytes[4, 0, 0, 0, 0, 0, 0, 0, 0, 4])
    end
    expect_raises(CrystalClick::CorruptPartError) do
      w240_object_prefix_read(Bytes[4, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0])
    end
  end

  it "does not replace the inherited byte budget between child prefixes" do
    prefix = Bytes[4, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    limits = CrystalClick::BinaryCodecLimits.new(64, 4_096, 1_000_000, prefix.size)
    budget = CrystalClick::BinaryCodecBudget.new(limits)
    w240_object_prefix_read(prefix, budget).shared_data_version.should eq(0_u64)
    expect_raises(CrystalClick::CorruptPartError) { w240_object_prefix_read(prefix, budget) }
  end

  it "keeps the inherited descriptor depth rather than resetting at the Object leaf" do
    prefix = Bytes[4, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    limits = CrystalClick::BinaryCodecLimits.new(3, 4_096, 1_000_000, 1_024)
    budget = CrystalClick::BinaryCodecBudget.new(limits)
    expect_raises(CrystalClick::CorruptPartError) { w240_object_prefix_read(prefix, budget, 4_i32) }
  end
end
