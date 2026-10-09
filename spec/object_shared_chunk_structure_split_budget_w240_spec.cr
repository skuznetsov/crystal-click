require "./spec_helper"

private def w240_split_append_record(
  prefix : Array(UInt8),
  suffix : Array(UInt8),
  row_count : UInt64,
  paths : Array(String),
) : Nil
  zero_marks = {0_u64, 0_u64}
  record = CrystalClick::ObjectSharedChunkStructure.new(
    row_count,
    paths,
    zero_marks,
    zero_marks,
    zero_marks,
  )
  wire = CrystalClick::ObjectSharedChunkStructureCodec.encode(record)
  prefix_size = wire.size - CrystalClick::ObjectSharedChunkStructureCodec::TRANSPORT_SUFFIX_BYTES.to_i
  wire[0, prefix_size].each { |byte| prefix << byte }
  wire[prefix_size, CrystalClick::ObjectSharedChunkStructureCodec::TRANSPORT_SUFFIX_BYTES.to_i].each do |byte|
    suffix << byte
  end
end

describe "W240 split Object chunk structure budget accounting" do
  it "charges one record node at depth one for an interleaved read" do
    marks = {0_u64, 0_u64}
    record = CrystalClick::ObjectSharedChunkStructure.new(
      1_u64,
      [] of String,
      marks,
      marks,
      marks,
    )
    wire = CrystalClick::ObjectSharedChunkStructureCodec.encode(record)
    limits = CrystalClick::BinaryCodecLimits.new(1, 1, 0, wire.size)
    budget = CrystalClick::BinaryCodecBudget.new(limits)
    context = CrystalClick::BinaryCodecContext.new(limits, wire, false, budget)

    CrystalClick::ObjectSharedChunkStructureCodec.read_from(context).row_count.should eq(1_u64)
    context.ensure_consumed
    budget.node_count.should eq(1_i64)
    budget.element_count.should eq(0_i64)
    budget.wire_byte_count.should eq(wire.size.to_i64)
  end

  it "charges each split record exactly once alongside its path metadata" do
    prefix = [] of UInt8
    suffix = [] of UInt8
    w240_split_append_record(prefix, suffix, 1_u64, ["a"] of String)
    w240_split_append_record(prefix, suffix, 2_u64, ["b"] of String)
    prefix_bytes = Bytes.new(prefix.size) { |index| prefix[index] }
    suffix_bytes = Bytes.new(suffix.size) { |index| suffix[index] }
    suffix_bytes.size.should eq(96)

    # Two record nodes plus two path-metadata nodes fit exactly; both record
    # visits must use the inherited depth and must not be double-counted. The
    # returned roster is preflighted here, while its caller charges that array
    # edge after grid validation; this codec charges only the two path edges.
    limits = CrystalClick::BinaryCodecLimits.new(1, 4, 2, suffix_bytes.size)
    budget = CrystalClick::BinaryCodecBudget.new(limits)
    records = CrystalClick::ObjectSharedChunkStructureCodec.read_split_records(
      prefix_bytes,
      suffix_bytes,
      budget,
    )

    records.map(&.row_count).should eq([1_u64, 2_u64])
    records.size.should eq(2)
    records[0].paths.should eq(["a"] of String)
    records[1].paths.should eq(["b"] of String)
    budget.node_count.should eq(4_i64)
    budget.element_count.should eq(2_i64)
    # Prefix input is already charged by its authenticated enclosing lane;
    # this method charges the separately supplied suffix exactly once.
    budget.wire_byte_count.should eq(suffix_bytes.size.to_i64)
  end

  it "enforces split depth, node, and suffix-byte limits at their exact boundary" do
    prefix = [] of UInt8
    suffix = [] of UInt8
    w240_split_append_record(prefix, suffix, 1_u64, ["a"] of String)
    w240_split_append_record(prefix, suffix, 2_u64, ["b"] of String)
    prefix_bytes = Bytes.new(prefix.size) { |index| prefix[index] }
    suffix_bytes = Bytes.new(suffix.size) { |index| suffix[index] }

    depth_budget = CrystalClick::BinaryCodecBudget.new(
      CrystalClick::BinaryCodecLimits.new(0, 4, 2, suffix_bytes.size)
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedChunkStructureCodec.read_split_records(
        prefix_bytes,
        suffix_bytes,
        depth_budget,
      )
    end

    node_budget = CrystalClick::BinaryCodecBudget.new(
      CrystalClick::BinaryCodecLimits.new(1, 3, 2, suffix_bytes.size)
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedChunkStructureCodec.read_split_records(
        prefix_bytes,
        suffix_bytes,
        node_budget,
      )
    end

    byte_budget = CrystalClick::BinaryCodecBudget.new(
      CrystalClick::BinaryCodecLimits.new(1, 4, 2, suffix_bytes.size - 1)
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedChunkStructureCodec.read_split_records(
        prefix_bytes,
        suffix_bytes,
        byte_budget,
      )
    end
    byte_budget.wire_byte_count.should eq(0_i64)
  end
end
