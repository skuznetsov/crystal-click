require "./spec_helper"

private def w263_structure_prefix_literal : Bytes
  # One shared StructurePrefix callback containing two chunk headers:
  # [rows=1, paths=0], then [rows=1, paths=["zz_overflow"]].
  Bytes[
    0x01_u8, 0x00_u8,
    0x01_u8, 0x01_u8, 0x0b_u8,
    0x7a_u8, 0x7a_u8, 0x5f_u8, 0x6f_u8, 0x76_u8, 0x65_u8,
    0x72_u8, 0x66_u8, 0x6c_u8, 0x6f_u8, 0x77_u8,
  ]
end

private def w263_structure_suffix_literal : Bytes
  # Two 48-byte records, each holding the original Data, PathsMarks, and
  # PathsSubstreamsMetadata compressed/decompressed mark pairs.
  Bytes[
    0x11_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    0x21_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    0x12_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    0x22_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    0x13_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    0x23_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,

    0x31_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    0x41_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    0x32_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    0x42_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    0x33_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    0x43_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
  ]
end

describe "W263 split Object chunk structure parser spans" do
  it "returns exact callback-local header spans and independent suffix pairs" do
    prefix = w263_structure_prefix_literal
    suffix = w263_structure_suffix_literal
    budget = CrystalClick::BinaryCodecBudget.new(
      CrystalClick::BinaryCodecLimits.new(1, 3, 2, 96)
    )

    spans = CrystalClick::ObjectSharedChunkStructureCodec.read_split_record_spans(
      prefix,
      suffix,
      budget,
    )

    spans.size.should eq(2)
    spans[0].prefix_start.should eq(0_i32)
    spans[0].prefix_end.should eq(2_i32)
    spans[0].record.row_count.should eq(1_u64)
    spans[0].record.paths.should be_empty
    spans[0].record.data_marks.should eq({0x11_u64, 0x21_u64})
    spans[0].record.paths_marks.should eq({0x12_u64, 0x22_u64})
    spans[0].record.paths_substreams_metadata_marks.should eq({0x13_u64, 0x23_u64})

    spans[1].prefix_start.should eq(2_i32)
    spans[1].prefix_end.should eq(16_i32)
    spans[1].record.row_count.should eq(1_u64)
    spans[1].record.paths.should eq(["zz_overflow"] of String)
    spans[1].record.data_marks.should eq({0x31_u64, 0x41_u64})
    spans[1].record.paths_marks.should eq({0x32_u64, 0x42_u64})
    spans[1].record.paths_substreams_metadata_marks.should eq({0x33_u64, 0x43_u64})

    # Prefix bytes are prepaid by the authenticated enclosing callback. The
    # parser charges two record nodes, one path metadata node/edge, and the
    # separately supplied 96-byte suffix exactly once. The two-record roster
    # is preflighted against the element cap, but its edge is caller-owned.
    budget.node_count.should eq(3_i64)
    budget.element_count.should eq(1_i64)
    budget.wire_byte_count.should eq(96_i64)
  end

  it "uses byte offsets across multibyte row counts and path lengths" do
    # Independent VarUInt literal: rows=128 with no paths, followed by
    # rows=16384 and one 128-byte path. No production encoder supplies offsets.
    prefix = Bytes.new(137, 0x78_u8)
    prefix[0] = 0x80_u8
    prefix[1] = 0x01_u8
    prefix[2] = 0x00_u8
    prefix[3] = 0x80_u8
    prefix[4] = 0x80_u8
    prefix[5] = 0x01_u8
    prefix[6] = 0x01_u8
    prefix[7] = 0x80_u8
    prefix[8] = 0x01_u8
    # The prepaid prefix still has to fit the per-input bound. Its 137 bytes
    # are not charged again; only the separately supplied suffix is charged.
    budget = CrystalClick::BinaryCodecBudget.new(
      CrystalClick::BinaryCodecLimits.new(1, 3, 2, 137)
    )

    spans = CrystalClick::ObjectSharedChunkStructureCodec.read_split_record_spans(
      prefix, w263_structure_suffix_literal, budget,
    )

    spans.map { |span| {span.prefix_start, span.prefix_end} }.should eq([
      {0_i32, 3_i32}, {3_i32, 137_i32},
    ])
    spans.map(&.record.row_count).should eq([128_u64, 16384_u64])
    spans[1].record.paths.should eq(["x" * 128])
    budget.node_count.should eq(3_i64)
    budget.element_count.should eq(1_i64)
    budget.wire_byte_count.should eq(96_i64)
  end

  it "rejects trailing or truncated prefix bytes and a short suffix roster" do
    prefix_with_trailing_byte = Bytes[
      0x01_u8, 0x00_u8,
      0x01_u8, 0x01_u8, 0x0b_u8,
      0x7a_u8, 0x7a_u8, 0x5f_u8, 0x6f_u8, 0x76_u8, 0x65_u8,
      0x72_u8, 0x66_u8, 0x6c_u8, 0x6f_u8, 0x77_u8,
      0xff_u8,
    ]
    prefix_truncated_in_path = Bytes[
      0x01_u8, 0x00_u8,
      0x01_u8, 0x01_u8, 0x0b_u8,
      0x7a_u8, 0x7a_u8, 0x5f_u8, 0x6f_u8, 0x76_u8, 0x65_u8,
      0x72_u8, 0x66_u8, 0x6c_u8, 0x6f_u8,
    ]
    prefix = w263_structure_prefix_literal
    suffix = w263_structure_suffix_literal

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedChunkStructureCodec.read_split_record_spans(
        prefix_with_trailing_byte, suffix,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
      )
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedChunkStructureCodec.read_split_record_spans(
        prefix_truncated_in_path, suffix,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
      )
    end
    # One suffix record cannot silently leave the second header unparsed.
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedChunkStructureCodec.read_split_record_spans(
        prefix, Bytes.new(48) { |index| suffix[index] },
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
      )
    end
  end

  it "rejects empty and partial fixed-width suffix records" do
    prefix = w263_structure_prefix_literal
    suffix = w263_structure_suffix_literal

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedChunkStructureCodec.read_split_record_spans(
        prefix, Bytes.empty,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
      )
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedChunkStructureCodec.read_split_record_spans(
        prefix, Bytes.new(95) { |index| suffix[index] },
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
      )
    end
    # A single final byte dropped from one suffix record is also rejected as
    # an incomplete 48-byte fixed record, even if its remaining fields decode.
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedChunkStructureCodec.read_split_record_spans(
        prefix, Bytes.new(47) { |index| suffix[index] },
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
      )
    end
  end

  it "keeps the caller's prepaid prefix charge and adds the suffix exactly once" do
    prefix = w263_structure_prefix_literal
    suffix = w263_structure_suffix_literal
    budget = CrystalClick::BinaryCodecBudget.new(
      CrystalClick::BinaryCodecLimits.new(1, 3, 2, 112)
    )
    budget.charge_wire_bytes(16_u64)

    spans = CrystalClick::ObjectSharedChunkStructureCodec.read_split_record_spans(
      prefix, suffix, budget,
    )

    spans.size.should eq(2)
    budget.wire_byte_count.should eq(112_i64)
    budget.node_count.should eq(3_i64)
    budget.element_count.should eq(1_i64)

    too_small = CrystalClick::BinaryCodecBudget.new(
      CrystalClick::BinaryCodecLimits.new(1, 3, 2, 111)
    )
    too_small.charge_wire_bytes(16_u64)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedChunkStructureCodec.read_split_record_spans(
        prefix, suffix, too_small,
      )
    end
    too_small.wire_byte_count.should eq(16_i64)
    too_small.node_count.should eq(0_i64)
    too_small.element_count.should eq(0_i64)
  end

  it "preserves read direction and inherited depth/node/element/suffix budgets" do
    prefix = w263_structure_prefix_literal
    suffix = w263_structure_suffix_literal

    expect_raises(ArgumentError) do
      CrystalClick::ObjectSharedChunkStructureCodec.read_split_record_spans(
        prefix, suffix,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
      )
    end

    [
      CrystalClick::BinaryCodecLimits.new(0, 3, 2, 96),
      CrystalClick::BinaryCodecLimits.new(1, 2, 2, 96),
      CrystalClick::BinaryCodecLimits.new(1, 3, 1, 96),
      CrystalClick::BinaryCodecLimits.new(1, 3, 2, 95),
    ].each do |limits|
      budget = CrystalClick::BinaryCodecBudget.new(limits)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::ObjectSharedChunkStructureCodec.read_split_record_spans(prefix, suffix, budget)
      end
      if limits.max_bytes == 95_i64
        budget.wire_byte_count.should eq(0_i64)
      end
    end
  end
end
