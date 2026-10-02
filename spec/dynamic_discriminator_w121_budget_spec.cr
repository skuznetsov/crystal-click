require "./spec_helper"

module W121BudgetProbe
  class_property byte_copies = 0
  class_property grid_copies = 0
  class_property mark_visits = 0
  class_property slices = 0
  class_property byte_reads = 0

  def self.reset : Nil
    self.byte_copies = 0
    self.grid_copies = 0
    self.mark_visits = 0
    self.slices = 0
    self.byte_reads = 0
  end
end

class CrystalClick::DynamicDiscriminatorStream
  def bytes : Bytes
    W121BudgetProbe.byte_copies += 1
    previous_def
  end

  def marks : Array(CrystalClick::DynamicDiscriminatorMark)
    W121BudgetProbe.grid_copies += 1
    previous_def
  end

  def mark_at(index : Int) : CrystalClick::DynamicDiscriminatorMark
    W121BudgetProbe.mark_visits += 1
    previous_def
  end

  def byte_at(index : Int) : UInt8
    W121BudgetProbe.byte_reads += 1
    previous_def
  end

  def borrowed_slice(offset : Int, size : Int) : Bytes
    W121BudgetProbe.slices += 1
    previous_def
  end
end

private def w121_budget_structure
  CrystalClick::DynamicStructure.new([CrystalClick::BinaryDataType.primitive("String")])
end

private def w121_budget_tags
  [Bytes[1, 1].to_a, Bytes[0, 255, 1].to_a]
end

private def w121_budget_stream
  # Literal COMPACT bytes: mode 1; uniform String(2); SharedVariant/NULL/String.
  CrystalClick::DynamicDiscriminatorStream.new(
    Bytes[1, 0, 0, 0, 0, 0, 0, 0, 2, 1, 1, 3, 0, 0, 255, 1],
    [
      CrystalClick::DynamicDiscriminatorMark.new(8_u64, 2_u64),
      CrystalClick::DynamicDiscriminatorMark.new(11_u64, 3_u64),
      CrystalClick::DynamicDiscriminatorMark.new(16_u64, 0_u64),
    ]
  )
end

private def w121_budget_limits(nodes : Int = 9, elements : Int = 23, bytes : Int = 16, depth : Int = 1)
  CrystalClick::BinaryCodecLimits.new(max_depth: depth, max_nodes: nodes, max_elements: elements, max_bytes: bytes)
end

describe "W121 independent aggregate schedule budget and coordinate guards" do
  it "charges the literal complete grid, row work, arm arrays and wire in both directions" do
    structure = w121_budget_structure
    # M=3, K=2, R=5, V=2 => nodes=9, elements=23, bytes=16.
    write = CrystalClick::BinaryCodecBudget.new(w121_budget_limits, true)
    encoded = CrystalClick::DynamicDiscriminatorCodec.encode_with_budget(structure, w121_budget_tags, write)
    encoded.bytes.should eq(w121_budget_stream.bytes)
    {write.node_count, write.element_count, write.wire_byte_count}.should eq({9_i64, 23_i64, 16_i64})
    read = CrystalClick::BinaryCodecBudget.new(w121_budget_limits)
    decoded = CrystalClick::DynamicDiscriminatorCodec.decode_with_budget(structure, w121_budget_stream, read)
    decoded.size.should eq(2)
    decoded[1].ranks.should eq([0, nil, 0])
    decoded[1].arm_counts.should eq([1_u64, 1_u64])
    decoded[1].arm_offsets.should eq([0_u64, 2_u64])
    {read.node_count, read.element_count, read.wire_byte_count}.should eq({9_i64, 23_i64, 16_i64})
  end

  it "rejects one-less node, element, wire and depth limits in both directions" do
    [w121_budget_limits(nodes: 8), w121_budget_limits(elements: 22), w121_budget_limits(bytes: 15), w121_budget_limits(depth: 0)].each do |limits|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::DynamicDiscriminatorCodec.encode(w121_budget_structure, w121_budget_tags, limits: limits)
      end
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::DynamicDiscriminatorCodec.decode(w121_budget_structure, w121_budget_stream, limits: limits)
      end
    end
  end

  it "uses selected-window arm offsets rather than part-wide ranks or outer row numbers" do
    # M=3, K=1, R=3, V=2 => nodes=7, elements=15, selected wire=8+5.
    limits = w121_budget_limits(nodes: 7, elements: 15, bytes: 13)
    budget = CrystalClick::BinaryCodecBudget.new(limits)
    result = CrystalClick::DynamicDiscriminatorCodec.decode_with_budget(
      w121_budget_structure, w121_budget_stream, budget, first_mark: 1, mark_count: 1
    )
    result.size.should eq(1)
    result[0].mark_index.should eq(1)
    result[0].first_row.should eq(2_u64)
    result[0].tags.should eq(Bytes[0, 255, 1].to_a)
    result[0].ranks.should eq([0, nil, 0])
    result[0].arm_offsets.should eq([0_u64, 0_u64])
    {budget.node_count, budget.element_count, budget.wire_byte_count}.should eq({7_i64, 15_i64, 13_i64})
  end

  it "permits an empty interior window while charging the complete grid and prefix" do
    budget = CrystalClick::BinaryCodecBudget.new(w121_budget_limits(nodes: 4, elements: 5, bytes: 8))
    CrystalClick::DynamicDiscriminatorCodec.decode_with_budget(
      w121_budget_structure, w121_budget_stream, budget, first_mark: 1, mark_count: 0
    ).should be_empty
    {budget.node_count, budget.element_count, budget.wire_byte_count}.should eq({4_i64, 5_i64, 8_i64})
  end

  it "keeps global tag 254 distinct from NULL at the maximum ordinary roster size" do
    types = Array(CrystalClick::BinaryDataType).new(254) { |index| CrystalClick::BinaryDataType.fixed_string(index + 1) }
    structure = CrystalClick::DynamicStructure.new(types)
    # All FixedString names precede SharedVariant, so its global tag is 254.
    structure.canonical_variant_names.last.should eq("SharedVariant")
    structure.canonical_variant_count.should eq(255)
    tags = [[254_u8, 255_u8], [254_u8, 253_u8]]
    encoded = CrystalClick::DynamicDiscriminatorCodec.encode(structure, tags, mode: 0_u64)
    result = CrystalClick::DynamicDiscriminatorCodec.decode(structure, encoded)
    result[0].ranks.should eq([0, nil])
    result[0].arm_counts[254].should eq(1_u64)
    result[1].ranks.should eq([0, 0])
    result[1].arm_offsets[254].should eq(1_u64)
    result[1].arm_counts[254].should eq(1_u64)
    result[1].arm_counts[253].should eq(1_u64)
    result[1].arm_counts.sum.should eq(2_u64)
  end

  it "keeps an enclosing budget across calls instead of silently resetting it" do
    limits = w121_budget_limits(nodes: 11, elements: 24, bytes: 20)
    [false, true].each do |writing|
      budget = CrystalClick::BinaryCodecBudget.new(limits, writing)
      2.times { budget.charge_node }
      budget.charge_elements(1_u64)
      budget.charge_wire_bytes(4_u64)
      if writing
        CrystalClick::DynamicDiscriminatorCodec.encode_with_budget(w121_budget_structure, w121_budget_tags, budget)
        expect_raises(CrystalClick::UnsupportedFormatError) do
          CrystalClick::DynamicDiscriminatorCodec.encode_with_budget(w121_budget_structure, w121_budget_tags, budget)
        end
      else
        CrystalClick::DynamicDiscriminatorCodec.decode_with_budget(w121_budget_structure, w121_budget_stream, budget)
        expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::DynamicDiscriminatorCodec.decode_with_budget(w121_budget_structure, w121_budget_stream, budget)
        end
      end
      {budget.node_count, budget.element_count, budget.wire_byte_count}.should eq({11_i64, 24_i64, 20_i64})
    end
  end

  it "rejects a borrowed budget in the wrong direction before charging it" do
    read = CrystalClick::BinaryCodecBudget.new(w121_budget_limits)
    write = CrystalClick::BinaryCodecBudget.new(w121_budget_limits, true)
    expect_raises(ArgumentError) do
      CrystalClick::DynamicDiscriminatorCodec.encode_with_budget(w121_budget_structure, w121_budget_tags, read)
    end
    expect_raises(ArgumentError) do
      CrystalClick::DynamicDiscriminatorCodec.decode_with_budget(w121_budget_structure, w121_budget_stream, write)
    end
    {read.node_count, read.element_count, read.wire_byte_count}.should eq({0_i64, 0_i64, 0_i64})
    {write.node_count, write.element_count, write.wire_byte_count}.should eq({0_i64, 0_i64, 0_i64})
  end

  it "classifies selection integers outside UInt64 as caller errors without narrowing overflow" do
    expect_raises(ArgumentError) do
      CrystalClick::DynamicDiscriminatorCodec.decode(w121_budget_structure, w121_budget_stream, first_mark: Int128::MAX)
    end
    expect_raises(ArgumentError) do
      CrystalClick::DynamicDiscriminatorCodec.decode(w121_budget_structure, w121_budget_stream, mark_count: Int128::MAX)
    end
  end

  it "preflights complete grid metadata before traversal or detached accessor copies" do
    stream = w121_budget_stream
    W121BudgetProbe.reset
    error = expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicDiscriminatorCodec.decode(w121_budget_structure, stream, limits: w121_budget_limits(nodes: 3))
    end
    error.message.to_s.should contain("node")
    W121BudgetProbe.mark_visits.should eq(0)
    W121BudgetProbe.grid_copies.should eq(0)
    W121BudgetProbe.byte_copies.should eq(0)
    W121BudgetProbe.slices.should eq(0)
  end

  it "preflights all selected wire bytes before taking any selected slice" do
    stream = w121_budget_stream
    W121BudgetProbe.reset
    error = expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicDiscriminatorCodec.decode(w121_budget_structure, stream, limits: w121_budget_limits(bytes: 15))
    end
    error.message.to_s.should contain("byte")
    W121BudgetProbe.slices.should eq(0)
    W121BudgetProbe.byte_copies.should eq(0)
    W121BudgetProbe.grid_copies.should eq(0)
  end

  it "preflights the mode prefix before reading header bytes" do
    stream = w121_budget_stream
    W121BudgetProbe.reset
    error = expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicDiscriminatorCodec.decode(w121_budget_structure, stream, limits: w121_budget_limits(bytes: 7))
    end
    error.message.to_s.should contain("byte")
    W121BudgetProbe.byte_reads.should eq(0)
    W121BudgetProbe.slices.should eq(0)
    W121BudgetProbe.byte_copies.should eq(0)
  end

  it "does not copy a large unselected body or attest its tags" do
    bytes = Bytes.new(8 * 1024 * 1024, 0xfe_u8)
    8.times { |index| bytes[index] = 0_u8 }
    stream = CrystalClick::DynamicDiscriminatorStream.new(bytes, [
      CrystalClick::DynamicDiscriminatorMark.new(8_u64, 1_u64),
      CrystalClick::DynamicDiscriminatorMark.new(bytes.size.to_u64, 0_u64),
    ])
    limits = w121_budget_limits(nodes: 3, elements: 4, bytes: 8)
    W121BudgetProbe.reset
    GC.stats
    before = GC.stats.total_bytes
    CrystalClick::DynamicDiscriminatorCodec.decode(w121_budget_structure, stream, first_mark: 1, mark_count: 0, limits: limits).should be_empty
    (GC.stats.total_bytes - before).should be < 131_072_u64
    W121BudgetProbe.byte_copies.should eq(0)
    W121BudgetProbe.grid_copies.should eq(0)
    W121BudgetProbe.slices.should eq(0)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicDiscriminatorCodec.decode(w121_budget_structure, stream)
    end
  end

  it "admits an ordinary 8192-row uniform granule under schedule defaults" do
    tags = [Array(UInt8).new(8_192, 1_u8)]
    encoded = CrystalClick::DynamicDiscriminatorCodec.encode(w121_budget_structure, tags)
    # VarUInt(8192), uniform format, String global tag.
    encoded.bytes.should eq(Bytes[1, 0, 0, 0, 0, 0, 0, 0, 0x80, 0x40, 1, 1])
    result = CrystalClick::DynamicDiscriminatorCodec.decode(w121_budget_structure, encoded)
    result[0].tags.size.should eq(8_192)
    result[0].ranks.last.should eq(8_191)
    result[0].arm_counts.should eq([0_u64, 8_192_u64])
  end

  it "rejects uniform tag expansion before allocating a million-row schedule" do
    # Literal COMPACT row count 1,000,000; model construction is unmeasured.
    bytes = Bytes[1, 0, 0, 0, 0, 0, 0, 0, 0xc0, 0x84, 0x3d, 1, 1]
    stream = CrystalClick::DynamicDiscriminatorStream.new(bytes, [
      CrystalClick::DynamicDiscriminatorMark.new(8_u64, 1_000_000_u64),
      CrystalClick::DynamicDiscriminatorMark.new(13_u64, 0_u64),
    ])
    limits = w121_budget_limits(nodes: 1_000_003, elements: 2, bytes: 13)
    W121BudgetProbe.reset
    GC.stats
    before = GC.stats.total_bytes
    error = expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicDiscriminatorCodec.decode(w121_budget_structure, stream, limits: limits)
    end
    error.message.to_s.should contain("element")
    (GC.stats.total_bytes - before).should be < 131_072_u64
    W121BudgetProbe.slices.should eq(0)
    W121BudgetProbe.byte_copies.should eq(0)
  end
end
