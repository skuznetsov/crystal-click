require "./spec_helper"

describe "W122 independent Dynamic shared-envelope and late-failure attack" do
  it "spills same-display-name Decimal values with a different nominal width" do
    ordinary_type = CrystalClick::BinaryDataType.decimal(32, 5, 2)
    spilled_type = CrystalClick::BinaryDataType.decimal(64, 5, 2)
    ordinary_type.name.should eq("Decimal(5, 2)")
    spilled_type.name.should eq(ordinary_type.name)
    (ordinary_type == spilled_type).should be_false
    structure = CrystalClick::DynamicStructure.new([ordinary_type])
    structure.canonical_variant_names.should eq(["Decimal(5, 2)", "SharedVariant"])
    value = CrystalClick::BinaryValue.fixed(spilled_type, Bytes[7, 0, 0, 0, 0, 0, 0, 0])
    encoded = CrystalClick::DynamicValueCodec.encode(structure, [[value]])
    encoded.discriminators.byte_at(10).should eq(1_u8)
    encoded.arm("Decimal(5, 2)").stream("root.data").bytes.should be_empty
    # Eleven envelope bytes: Decimal64 tag 26, precision 5, scale 2,
    # and eight raw value bytes. The framing length is separate.
    encoded.arm("SharedVariant").stream("root.data").bytes.should eq(Bytes[11, 26, 5, 2, 7, 0, 0, 0, 0, 0, 0, 0])
    decoded = CrystalClick::DynamicValueCodec.decode(structure, encoded).first.first
    decoded.type.should eq(spilled_type)
    decoded.bytes.should eq(Bytes[7, 0, 0, 0, 0, 0, 0, 0])
  end

  it "charges the exact aggregate ledger including assembly of NULL rows" do
    structure = CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)
    discriminator = CrystalClick::DynamicDiscriminatorStream.new(Bytes[1, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 255], [
      CrystalClick::DynamicDiscriminatorMark.new(8_u64, 2_u64),
      CrystalClick::DynamicDiscriminatorMark.new(12_u64, 0_u64),
    ])
    literal = CrystalClick::DynamicValueStreams.new(discriminator, {
      "SharedVariant" => CrystalClick::BinaryBulkStreams.new(1, {
        "root.data" => CrystalClick::BinaryBulkStream.new(Bytes[2, 45, 1], [0_u64, 3_u64]),
      }),
    })
    values = [[CrystalClick::BinaryValue.bool(true), CrystalClick::BinaryValue.null]]
    # W121: 5 nodes / 9 edges. Bulk String descriptor + 3 metadata +
    # one value: 5 nodes / 3 edges. Shared Bool envelope: 2 nodes.
    # Read assembly (owner, mark, both rows, including NULL): 4 nodes / 3
    # edges. Write validates two input descriptors and has no read assembly.
    read_limits = CrystalClick::BinaryCodecLimits.new(max_depth: 64, max_nodes: 16, max_elements: 15, max_bytes: 15)
    write_limits = CrystalClick::BinaryCodecLimits.new(max_depth: 64, max_nodes: 14, max_elements: 12, max_bytes: 15)
    read = CrystalClick::BinaryCodecBudget.new(read_limits)
    decoded = CrystalClick::DynamicValueCodec.decode_with_budget(structure, literal, read).first
    decoded.size.should eq(2)
    decoded.first.as_bool.should be_true
    decoded.last.is_null?.should be_true
    {read.node_count, read.element_count, read.wire_byte_count}.should eq({16_i64, 15_i64, 15_i64})
    write = CrystalClick::BinaryCodecBudget.new(write_limits, true)
    encoded = CrystalClick::DynamicValueCodec.encode_with_budget(structure, values, write)
    encoded.discriminators.bytes.should eq(discriminator.bytes)
    encoded.arm("SharedVariant").stream("root.data").bytes.should eq(Bytes[2, 45, 1])
    {write.node_count, write.element_count, write.wire_byte_count}.should eq({14_i64, 12_i64, 15_i64})
    [{15, 15, 15}, {16, 14, 15}, {16, 15, 14}].each do |nodes, edges, bytes|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::DynamicValueCodec.decode(structure, literal,
          limits: CrystalClick::BinaryCodecLimits.new(max_depth: 64, max_nodes: nodes, max_elements: edges, max_bytes: bytes))
      end
    end
    [{13, 12, 15}, {14, 11, 15}, {14, 12, 14}].each do |nodes, edges, bytes|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::DynamicValueCodec.encode(structure, values,
          limits: CrystalClick::BinaryCodecLimits.new(max_depth: 64, max_nodes: nodes, max_elements: edges, max_bytes: bytes))
      end
    end
  end

  it "keeps SharedVariant Bool envelope separate from top-level NULL" do
    structure = CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)
    granules = [[CrystalClick::BinaryValue.bool(true), CrystalClick::BinaryValue.null]]
    encoded = CrystalClick::DynamicValueCodec.encode(structure, granules)
    encoded.discriminators.bytes.should eq(Bytes[1, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 255])
    encoded.arm("SharedVariant").stream("root.data").bytes.should eq(Bytes[2, 45, 1])
    encoded.arm("SharedVariant").stream("root.data").offsets.should eq([0_u64, 3_u64])
    literal = CrystalClick::DynamicValueStreams.new(
      CrystalClick::DynamicDiscriminatorStream.new(Bytes[1, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 255], [
        CrystalClick::DynamicDiscriminatorMark.new(8_u64, 2_u64),
        CrystalClick::DynamicDiscriminatorMark.new(12_u64, 0_u64),
      ]),
      {"SharedVariant" => CrystalClick::BinaryBulkStreams.new(1, {
        "root.data" => CrystalClick::BinaryBulkStream.new(Bytes[2, 45, 1], [0_u64, 3_u64]),
      })}
    )
    decoded = CrystalClick::DynamicValueCodec.decode(structure, literal).first
    decoded.size.should eq(2)
    decoded[0].type.should eq(CrystalClick::BinaryDataType.primitive("Bool"))
    decoded[0].as_bool.should be_true
    decoded[1].type.tag.should eq(CrystalClick::BinaryDataType::TAG_NOTHING)
    decoded[1].is_null?.should be_true
  end

  it "refuses NULL aliases inside shared envelopes and top-level Nullable input" do
    structure = CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)
    discriminator = CrystalClick::DynamicDiscriminatorStream.new(Bytes[0, 0, 0, 0, 0, 0, 0, 0, 0], [
      CrystalClick::DynamicDiscriminatorMark.new(8_u64, 1_u64),
      CrystalClick::DynamicDiscriminatorMark.new(9_u64, 0_u64),
    ])
    # Typed Nothing envelope is a single 00 byte, String-framed as 01 00.
    malformed = CrystalClick::DynamicValueStreams.new(discriminator, {
      "SharedVariant" => CrystalClick::BinaryBulkStreams.new(1, {
        "root.data" => CrystalClick::BinaryBulkStream.new(Bytes[1, 0], [0_u64, 2_u64]),
      }),
    })
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicValueCodec.decode(structure, malformed)
    end
    type = CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.primitive("String"))
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::DynamicValueCodec.encode(structure, [[CrystalClick::BinaryValue.nullable(type)]])
    end
  end

  it "validates the last selected arm before publishing rows and ignores unselected bodies" do
    structure = CrystalClick::DynamicStructure.new([CrystalClick::BinaryDataType.primitive("String")])
    # BASIC: two single String tags; canonical String index1, Shared index0.
    discriminator = CrystalClick::DynamicDiscriminatorStream.new(Bytes[0, 0, 0, 0, 0, 0, 0, 0, 1, 1], [
      CrystalClick::DynamicDiscriminatorMark.new(8_u64, 1_u64),
      CrystalClick::DynamicDiscriminatorMark.new(9_u64, 1_u64),
      CrystalClick::DynamicDiscriminatorMark.new(10_u64, 0_u64),
    ])
    malformed = CrystalClick::DynamicValueStreams.new(discriminator, {
      "String" => CrystalClick::BinaryBulkStreams.new(2, {
        "root.data" => CrystalClick::BinaryBulkStream.new(Bytes[1, 120, 128], [0_u64, 2_u64, 3_u64]),
      }),
      "SharedVariant" => CrystalClick::BinaryBulkStreams.new(2, {
        "root.data" => CrystalClick::BinaryBulkStream.new(Bytes.empty, [0_u64, 0_u64, 0_u64]),
      }),
    })
    returned = false
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicValueCodec.decode(structure, malformed)
      returned = true
    end
    returned.should be_false
    CrystalClick::DynamicValueCodec.decode(structure, malformed, first_mark: 0, mark_count: 1).first.first.as_string.should eq("x")
    # Invalid caller selection retains the W121 ArgumentError API; corrupt
    # selected physical bodies above are CorruptPartError instead.
    expect_raises(ArgumentError) do
      CrystalClick::DynamicValueCodec.decode(structure, malformed, first_mark: Int128::MAX, mark_count: 0)
    end
  end

  it "charges one aggregate selected physical budget including shared String framing" do
    structure = CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)
    # COMPACT two one-row shared marks: header8 + body3+3. Shared Bool typed
    # envelopes use String frames of 3+3. Full=20, last mark alone=14 bytes.
    discriminator = CrystalClick::DynamicDiscriminatorStream.new(Bytes[1, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 1, 1, 0], [
      CrystalClick::DynamicDiscriminatorMark.new(8_u64, 1_u64),
      CrystalClick::DynamicDiscriminatorMark.new(11_u64, 1_u64),
      CrystalClick::DynamicDiscriminatorMark.new(14_u64, 0_u64),
    ])
    literal = CrystalClick::DynamicValueStreams.new(discriminator, {
      "SharedVariant" => CrystalClick::BinaryBulkStreams.new(2, {
        "root.data" => CrystalClick::BinaryBulkStream.new(Bytes[2, 45, 1, 2, 45, 0], [0_u64, 3_u64, 6_u64]),
      }),
    })
    limits = CrystalClick::BinaryCodecLimits.new(max_depth: 64, max_nodes: 1000, max_elements: 1000, max_bytes: 20)
    read = CrystalClick::BinaryCodecBudget.new(limits)
    CrystalClick::DynamicValueCodec.decode_with_budget(structure, literal, read).map { |mark| mark.first.as_bool }.should eq([true, false])
    read.wire_byte_count.should eq(20_i64)
    write = CrystalClick::BinaryCodecBudget.new(limits, true)
    encoded = CrystalClick::DynamicValueCodec.encode_with_budget(structure, [[CrystalClick::BinaryValue.bool(true)], [CrystalClick::BinaryValue.bool(false)]], write)
    write.wire_byte_count.should eq(20_i64)
    encoded.arm("SharedVariant").stream("root.data").bytes.should eq(Bytes[2, 45, 1, 2, 45, 0])
    shorter = CrystalClick::BinaryCodecLimits.new(max_depth: 64, max_nodes: 1000, max_elements: 1000, max_bytes: 19)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicValueCodec.decode(structure, literal, limits: shorter)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::DynamicValueCodec.encode(structure, [[CrystalClick::BinaryValue.bool(true)], [CrystalClick::BinaryValue.bool(false)]], limits: shorter)
    end
    selected_limits = CrystalClick::BinaryCodecLimits.new(max_depth: 64, max_nodes: 1000, max_elements: 1000, max_bytes: 14)
    selected = CrystalClick::BinaryCodecBudget.new(selected_limits)
    CrystalClick::DynamicValueCodec.decode_with_budget(structure, literal, selected, first_mark: 1, mark_count: 1).first.first.as_bool.should be_false
    selected.wire_byte_count.should eq(14_i64)
  end

  it "checks a growing shared VarUInt frame after earlier pending envelopes" do
    structure = CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)
    text = "x" * 126
    values = [[CrystalClick::BinaryValue.bool(true), CrystalClick::BinaryValue.string(text)]]
    # Typed String: tag 21 + length 126 + 126 raw bytes = 128 bytes.
    # Its outer String length now needs two bytes (80 01), after the
    # earlier three-byte Bool frame. COMPACT discriminator costs 11 bytes.
    literal = Bytes.new(133, 120_u8)
    literal[0, 7].copy_from(Bytes[2, 45, 1, 128, 1, 21, 126])
    limits = CrystalClick::BinaryCodecLimits.new(max_depth: 64, max_nodes: 1000, max_elements: 1000, max_bytes: 144)
    budget = CrystalClick::BinaryCodecBudget.new(limits, true)
    encoded = CrystalClick::DynamicValueCodec.encode_with_budget(structure, values, budget)
    encoded.discriminators.bytes.should eq(Bytes[1, 0, 0, 0, 0, 0, 0, 0, 2, 1, 0])
    encoded.arm("SharedVariant").stream("root.data").bytes.should eq(literal)
    budget.wire_byte_count.should eq(144_i64)
    read = CrystalClick::BinaryCodecBudget.new(limits)
    decoded = CrystalClick::DynamicValueCodec.decode_with_budget(structure, encoded, read).first
    decoded[0].as_bool.should be_true
    decoded[1].as_string.should eq(text)
    read.wire_byte_count.should eq(144_i64)
    shorter = CrystalClick::BinaryCodecLimits.new(max_depth: 64, max_nodes: 1000, max_elements: 1000, max_bytes: 143)
    failed_write = CrystalClick::BinaryCodecBudget.new(shorter, true)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::DynamicValueCodec.encode_with_budget(structure, values, failed_write)
    end
    # Pending child bytes were not charged by the temporary envelope codec.
    failed_write.wire_byte_count.should eq(11_i64)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicValueCodec.decode(structure, encoded, limits: shorter)
    end
  end
end
