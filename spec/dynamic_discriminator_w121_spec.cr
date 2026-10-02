require "./spec_helper"

private def w121_structure : CrystalClick::DynamicStructure
  CrystalClick::DynamicStructure.new([
    CrystalClick::BinaryDataType.primitive("UInt8"),
    CrystalClick::BinaryDataType.primitive("String"),
  ] of CrystalClick::BinaryDataType)
end

private def w121_copy(bytes : Bytes) : Bytes
  Bytes.new(bytes.size) { |index| bytes[index] }
end

private def w121_concat(first : Bytes, second : Bytes) : Bytes
  Bytes.new(first.size + second.size) do |index|
    if index < first.size
      first[index]
    else
      second[index - first.size]
    end
  end
end

private def w121_marks(pairs : Array(Tuple(UInt64, UInt64))) : Array(CrystalClick::DynamicDiscriminatorMark)
  pairs.map { |offset, rows| CrystalClick::DynamicDiscriminatorMark.new(offset, rows) }
end

private def w121_limits(
  max_nodes : Int = 1_000_000,
  max_elements : Int = 3_000_000,
  max_bytes : Int = 64 * 1024 * 1024,
) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: 1,
    max_nodes: max_nodes,
    max_elements: max_elements,
    max_bytes: max_bytes
  )
end

describe "W121 paired Dynamic discriminator stream and schedules" do
  it "decodes a BASIC literal and uses canonical SQL-name tags, not descriptor order" do
    # The roster is deliberately in the opposite order from its global names:
    # SharedVariant=0, String=1, UInt8=2, NULL=255.
    structure = w121_structure
    structure.canonical_variant_names.should eq(["SharedVariant", "String", "UInt8"] of String)
    wire = Bytes[
      0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x02_u8, 0xff_u8, 0x01_u8, 0x00_u8,
    ]
    marks = w121_marks([
      {8_u64, 2_u64},
      {10_u64, 2_u64},
      {12_u64, 0_u64},
    ] of Tuple(UInt64, UInt64))
    stream = CrystalClick::DynamicDiscriminatorStream.new(wire, marks)

    stream.byte_size.should eq(12)
    stream.mark_count.should eq(3)
    stream.mark_at(0).offset.should eq(8_u64)
    stream.mark_at(0).rows.should eq(2_u64)
    stream.mark_at(2).offset.should eq(12_u64)
    stream.mark_at(2).rows.should eq(0_u64)
    stream.borrowed_slice(8, 4).should eq(Bytes[0x02_u8, 0xff_u8, 0x01_u8, 0x00_u8])

    schedules = CrystalClick::DynamicDiscriminatorCodec.decode(structure, stream)
    schedules.size.should eq(2)
    schedules[0].mark_index.should eq(0_i32)
    schedules[0].first_row.should eq(0_u64)
    schedules[0].tags.should eq([2_u8, 255_u8])
    schedules[0].ranks.should eq([0_i32, nil] of Int32?)
    schedules[0].arm_counts.should eq([0_u64, 0_u64, 1_u64])
    schedules[0].arm_offsets.should eq([0_u64, 0_u64, 0_u64])

    schedules[1].mark_index.should eq(1_i32)
    schedules[1].first_row.should eq(2_u64)
    schedules[1].tags.should eq([1_u8, 0_u8])
    schedules[1].ranks.should eq([0_i32, 0_i32] of Int32?)
    schedules[1].arm_counts.should eq([1_u64, 1_u64, 0_u64])
    schedules[1].arm_offsets.should eq([0_u64, 0_u64, 1_u64])

    encoded = CrystalClick::DynamicDiscriminatorCodec.encode(
      structure,
      [[2_u8, 255_u8], [1_u8, 0_u8]] of Array(UInt8),
      mode: 0_u64
    )
    encoded.bytes.should eq(wire)
    encoded.marks.map { |mark| {mark.offset, mark.rows} }.should eq([
      {8_u64, 2_u64}, {10_u64, 2_u64}, {12_u64, 0_u64},
    ])
  end

  it "decodes and canonically writes COMPACT mixed, uniform, and all-NULL granules" do
    structure = w121_structure
    # Mark 0 uses compact uniform String; mark 1 uses compact uniform NULL;
    # mark 2 uses compact row tags. All bytes are authored literals.
    wire = Bytes[
      0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x02_u8, 0x01_u8, 0x01_u8,
      0x03_u8, 0x01_u8, 0xff_u8,
      0x02_u8, 0x00_u8, 0x02_u8, 0xff_u8,
    ]
    marks = w121_marks([
      {8_u64, 2_u64},
      {11_u64, 3_u64},
      {14_u64, 2_u64},
      {18_u64, 0_u64},
    ] of Tuple(UInt64, UInt64))
    stream = CrystalClick::DynamicDiscriminatorStream.new(wire, marks)
    schedules = CrystalClick::DynamicDiscriminatorCodec.decode(structure, stream)

    schedules.map(&.mark_index).should eq([0_i32, 1_i32, 2_i32])
    schedules.map(&.first_row).should eq([0_u64, 2_u64, 5_u64])
    schedules[0].tags.should eq([1_u8, 1_u8])
    schedules[0].ranks.should eq([0_i32, 1_i32] of Int32?)
    schedules[0].arm_counts.should eq([0_u64, 2_u64, 0_u64])
    schedules[0].arm_offsets.should eq([0_u64, 0_u64, 0_u64])
    schedules[1].tags.should eq([255_u8, 255_u8, 255_u8])
    schedules[1].ranks.should eq([nil, nil, nil] of Int32?)
    schedules[1].arm_counts.should eq([0_u64, 0_u64, 0_u64])
    schedules[1].arm_offsets.should eq([0_u64, 2_u64, 0_u64])
    schedules[2].tags.should eq([2_u8, 255_u8])
    schedules[2].ranks.should eq([0_i32, nil] of Int32?)
    schedules[2].arm_counts.should eq([0_u64, 0_u64, 1_u64])
    schedules[2].arm_offsets.should eq([0_u64, 2_u64, 0_u64])

    encoded = CrystalClick::DynamicDiscriminatorCodec.encode(
      structure,
      [[1_u8, 1_u8], [255_u8, 255_u8, 255_u8], [2_u8, 255_u8]] of Array(UInt8),
      mode: 1_u64
    )
    encoded.bytes.should eq(wire)
    encoded.marks.map { |mark| {mark.offset, mark.rows} }.should eq([
      {8_u64, 2_u64}, {11_u64, 3_u64}, {14_u64, 2_u64}, {18_u64, 0_u64},
    ])
  end

  it "rewrites valid noncanonical COMPACT row format to the uniform form" do
    structure = w121_structure
    # Row format is valid even when every tag agrees; the writer canonicalizes
    # this granule to the shorter uniform representation.
    noncanonical = Bytes[
      0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x02_u8, 0x00_u8, 0x01_u8, 0x01_u8,
    ]
    stream = CrystalClick::DynamicDiscriminatorStream.new(noncanonical, w121_marks([
      {8_u64, 2_u64}, {12_u64, 0_u64},
    ] of Tuple(UInt64, UInt64)))
    decoded = CrystalClick::DynamicDiscriminatorCodec.decode(structure, stream)
    decoded[0].tags.should eq([1_u8, 1_u8])

    canonical = Bytes[
      0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x02_u8, 0x01_u8, 0x01_u8,
    ]
    encoded = CrystalClick::DynamicDiscriminatorCodec.encode(
      structure,
      [[1_u8, 1_u8]] of Array(UInt8),
      mode: 1_u64
    )
    encoded.bytes.should eq(canonical)
    encoded.mark_at(1).offset.should eq(11_u64)
  end

  it "supports an empty complete stream and a zero-length terminal selection" do
    structure = CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)
    expected = Bytes[
      0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    ]
    stream = CrystalClick::DynamicDiscriminatorCodec.encode(
      structure,
      [] of Array(UInt8),
      mode: 1_u64
    )
    stream.bytes.should eq(expected)
    stream.marks.map { |mark| {mark.offset, mark.rows} }.should eq([{8_u64, 0_u64}])
    CrystalClick::DynamicDiscriminatorCodec.decode(structure, stream).should be_empty
    CrystalClick::DynamicDiscriminatorCodec.decode(
      structure,
      stream,
      first_mark: 0,
      mark_count: 0
    ).should be_empty
  end

  it "preserves absolute mark and row coordinates while resetting selected-window arm offsets" do
    structure = w121_structure
    wire = Bytes[
      0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x02_u8, 0x01_u8, 0x01_u8,
      0x03_u8, 0x01_u8, 0xff_u8,
      0x02_u8, 0x00_u8, 0x02_u8, 0xff_u8,
    ]
    stream = CrystalClick::DynamicDiscriminatorStream.new(wire, w121_marks([
      {8_u64, 2_u64}, {11_u64, 3_u64}, {14_u64, 2_u64}, {18_u64, 0_u64},
    ] of Tuple(UInt64, UInt64)))

    full = CrystalClick::DynamicDiscriminatorCodec.decode(structure, stream)
    full[2].arm_offsets.should eq([0_u64, 2_u64, 0_u64])
    selected = CrystalClick::DynamicDiscriminatorCodec.decode(
      structure,
      stream,
      first_mark: 2,
      mark_count: 1
    )
    selected.size.should eq(1)
    selected[0].mark_index.should eq(2_i32)
    selected[0].first_row.should eq(5_u64)
    selected[0].tags.should eq([2_u8, 255_u8])
    selected[0].ranks.should eq([0_i32, nil] of Int32?)
    # Earlier String rows do not leak into this selected window's offsets.
    selected[0].arm_offsets.should eq([0_u64, 0_u64, 0_u64])

    [
      {-1, 1},
      {0, -1},
      {4, 0},
      {3, 1},
    ].each do |first_mark, mark_count|
      expect_raises(ArgumentError) do
        CrystalClick::DynamicDiscriminatorCodec.decode(
          structure,
          stream,
          first_mark: first_mark,
          mark_count: mark_count
        )
      end
    end
  end

  it "accepts exact BASIC limits and rejects each one-unit-short limit" do
    structure = w121_structure
    tags = [[2_u8, 255_u8], [1_u8, 0_u8]] of Array(UInt8)
    wire = Bytes[
      0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x02_u8, 0xff_u8, 0x01_u8, 0x00_u8,
    ]
    stream = CrystalClick::DynamicDiscriminatorStream.new(wire, w121_marks([
      {8_u64, 2_u64}, {10_u64, 2_u64}, {12_u64, 0_u64},
    ] of Tuple(UInt64, UInt64)))
    exact = w121_limits(max_nodes: 8, max_elements: 26, max_bytes: 12)

    CrystalClick::DynamicDiscriminatorCodec.encode(structure, tags, mode: 0_u64, limits: exact).bytes.should eq(wire)
    CrystalClick::DynamicDiscriminatorCodec.decode(structure, stream, limits: exact).size.should eq(2)

    [
      w121_limits(max_nodes: 7, max_elements: 26, max_bytes: 12),
      w121_limits(max_nodes: 8, max_elements: 25, max_bytes: 12),
      w121_limits(max_nodes: 8, max_elements: 26, max_bytes: 11),
    ].each do |short|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::DynamicDiscriminatorCodec.encode(structure, tags, mode: 0_u64, limits: short)
      end
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::DynamicDiscriminatorCodec.decode(structure, stream, limits: short)
      end
    end
  end

  it "validates the grid but does not parse unselected payload bodies" do
    structure = w121_structure
    # The first BASIC tag is outside the roster; selecting only the second mark
    # remains admitted by the explicitly selected-window contract.
    wire = Bytes[
      0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x03_u8, 0x01_u8,
    ]
    stream = CrystalClick::DynamicDiscriminatorStream.new(wire, w121_marks([
      {8_u64, 1_u64}, {9_u64, 1_u64}, {10_u64, 0_u64},
    ] of Tuple(UInt64, UInt64)))
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicDiscriminatorCodec.decode(structure, stream)
    end
    selected = CrystalClick::DynamicDiscriminatorCodec.decode(
      structure,
      stream,
      first_mark: 1,
      mark_count: 1
    )
    selected[0].tags.should eq([1_u8])
    selected[0].first_row.should eq(1_u64)
  end

  it "classifies malformed modes, formats, tag domains, grids, and empty real marks" do
    structure = w121_structure
    bad_mode = CrystalClick::DynamicDiscriminatorStream.new(
      Bytes[0x02_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8],
      w121_marks([{8_u64, 0_u64}] of Tuple(UInt64, UInt64))
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicDiscriminatorCodec.decode(structure, bad_mode)
    end

    bad_format = CrystalClick::DynamicDiscriminatorStream.new(
      Bytes[0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x02_u8, 0x02_u8],
      w121_marks([{8_u64, 2_u64}, {10_u64, 0_u64}] of Tuple(UInt64, UInt64))
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicDiscriminatorCodec.decode(structure, bad_format)
    end

    row_mismatch = CrystalClick::DynamicDiscriminatorStream.new(
      Bytes[0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x03_u8, 0x01_u8, 0x01_u8],
      w121_marks([{8_u64, 2_u64}, {11_u64, 0_u64}] of Tuple(UInt64, UInt64))
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicDiscriminatorCodec.decode(structure, row_mismatch)
    end

    bad_tag = CrystalClick::DynamicDiscriminatorStream.new(
      Bytes[0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x03_u8],
      w121_marks([{8_u64, 1_u64}, {9_u64, 0_u64}] of Tuple(UInt64, UInt64))
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicDiscriminatorCodec.decode(structure, bad_tag)
    end

    nonminimal_row_count = CrystalClick::DynamicDiscriminatorStream.new(
      Bytes[0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x81_u8, 0x00_u8, 0x01_u8, 0x01_u8],
      w121_marks([{8_u64, 1_u64}, {12_u64, 0_u64}] of Tuple(UInt64, UInt64))
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicDiscriminatorCodec.decode(structure, nonminimal_row_count)
    end

    overflowing_varint_bytes = Bytes.new(18, 0x80_u8)
    overflowing_varint_bytes.to_unsafe[0] = 0x01_u8
    1.upto(7) { |index| overflowing_varint_bytes.to_unsafe[index] = 0x00_u8 }
    overflowing_varint_bytes.to_unsafe[17] = 0x02_u8
    overflowing_varint = CrystalClick::DynamicDiscriminatorStream.new(
      overflowing_varint_bytes,
      w121_marks([{8_u64, 1_u64}, {18_u64, 0_u64}] of Tuple(UInt64, UInt64))
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicDiscriminatorCodec.decode(structure, overflowing_varint)
    end

    unterminated_varint_bytes = Bytes.new(18, 0x80_u8)
    unterminated_varint_bytes.to_unsafe[0] = 0x01_u8
    1.upto(7) { |index| unterminated_varint_bytes.to_unsafe[index] = 0x00_u8 }
    unterminated_varint = CrystalClick::DynamicDiscriminatorStream.new(
      unterminated_varint_bytes,
      w121_marks([{8_u64, 1_u64}, {18_u64, 0_u64}] of Tuple(UInt64, UInt64))
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicDiscriminatorCodec.decode(structure, unterminated_varint)
    end

    compact_trailing = CrystalClick::DynamicDiscriminatorStream.new(
      Bytes[0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x01_u8, 0x01_u8, 0x01_u8, 0x55_u8],
      w121_marks([{8_u64, 1_u64}, {12_u64, 0_u64}] of Tuple(UInt64, UInt64))
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicDiscriminatorCodec.decode(structure, compact_trailing)
    end

    basic_extent_mismatch = CrystalClick::DynamicDiscriminatorStream.new(
      Bytes[0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x01_u8, 0x01_u8],
      w121_marks([{8_u64, 1_u64}, {10_u64, 0_u64}] of Tuple(UInt64, UInt64))
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicDiscriminatorCodec.decode(structure, basic_extent_mismatch)
    end

    too_many_rows = CrystalClick::DynamicDiscriminatorStream.new(
      Bytes[0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x01_u8],
      w121_marks([{8_u64, Int32::MAX.to_u64 + 1_u64}, {9_u64, 0_u64}] of Tuple(UInt64, UInt64))
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicDiscriminatorCodec.decode(structure, too_many_rows)
    end

    bad_last_selected_mark = CrystalClick::DynamicDiscriminatorStream.new(
      Bytes[
        0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
        0x01_u8, 0x01_u8, 0x01_u8,
        0x01_u8, 0x01_u8, 0x03_u8,
      ],
      w121_marks([{8_u64, 1_u64}, {11_u64, 1_u64}, {14_u64, 0_u64}] of Tuple(UInt64, UInt64))
    )
    expect_raises(CrystalClick::CorruptPartError) do
      # The first mark is valid; the later selected mark still prevents any
      # partial schedule result from escaping.
      CrystalClick::DynamicDiscriminatorCodec.decode(structure, bad_last_selected_mark)
    end

    header = Bytes[0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8]
    invalid_grids = [
      # First body must begin immediately after the eight-byte mode header.
      {header, w121_marks([{9_u64, 1_u64}, {9_u64, 0_u64}] of Tuple(UInt64, UInt64))},
      # A complete blob requires its terminal zero-row sentinel.
      {w121_concat(header, Bytes[0x00_u8]), w121_marks([{8_u64, 1_u64}] of Tuple(UInt64, UInt64))},
      # Positive-row marks must have positive byte extent.
      {header, w121_marks([{8_u64, 1_u64}, {8_u64, 0_u64}] of Tuple(UInt64, UInt64))},
      # The terminal position must be exactly the end of the complete stream.
      {header, w121_marks([{8_u64, 0_u64}, {7_u64, 0_u64}] of Tuple(UInt64, UInt64))},
      # A terminal-only grid is the header itself; it cannot hide trailing bytes.
      {w121_concat(header, Bytes[0x00_u8]), w121_marks([{9_u64, 0_u64}] of Tuple(UInt64, UInt64))},
    ] of Tuple(Bytes, Array(CrystalClick::DynamicDiscriminatorMark))
    invalid_grids.each do |bytes, marks|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::DynamicDiscriminatorCodec.decode(
          structure,
          CrystalClick::DynamicDiscriminatorStream.new(bytes, marks)
        )
      end
    end

    expect_raises(ArgumentError) do
      CrystalClick::DynamicDiscriminatorCodec.encode(structure, [[1_u8]] of Array(UInt8), mode: 2_u64)
    end
    expect_raises(ArgumentError) do
      CrystalClick::DynamicDiscriminatorCodec.encode(structure, [[] of UInt8], mode: 0_u64)
    end
    expect_raises(ArgumentError) do
      CrystalClick::DynamicDiscriminatorCodec.encode(structure, [[3_u8]] of Array(UInt8), mode: 0_u64)
    end
  end

  it "detaches caller inputs and every exposed mutable stream or schedule collection" do
    structure = w121_structure
    original_bytes = Bytes[
      0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x01_u8,
    ]
    input_bytes = w121_copy(original_bytes)
    input_marks = w121_marks([{8_u64, 1_u64}, {9_u64, 0_u64}] of Tuple(UInt64, UInt64))
    stream = CrystalClick::DynamicDiscriminatorStream.new(input_bytes, input_marks)

    input_bytes.to_unsafe[8] = 0x02_u8
    input_marks.clear
    stream.byte_at(8).should eq(1_u8)
    stream.mark_count.should eq(2)

    returned_bytes = stream.bytes
    returned_bytes.to_unsafe[8] = 0x03_u8
    returned_marks = stream.marks
    returned_marks.clear
    stream.byte_at(8).should eq(1_u8)
    stream.mark_count.should eq(2)

    schedule_tags = [1_u8]
    schedule_ranks = [0_i32] of Int32?
    schedule_counts = [0_u64, 1_u64, 0_u64]
    schedule_offsets = [0_u64, 0_u64, 0_u64]
    constructed = CrystalClick::DynamicMarkSchedule.new(
      0_i32,
      0_u64,
      schedule_tags,
      schedule_ranks,
      schedule_counts,
      schedule_offsets
    )
    schedule_tags[0] = 0xff_u8
    schedule_ranks[0] = nil
    schedule_counts[1] = 99_u64
    schedule_offsets[1] = 99_u64
    constructed.tags.should eq([1_u8])
    constructed.ranks.should eq([0_i32] of Int32?)
    constructed.arm_counts.should eq([0_u64, 1_u64, 0_u64])
    constructed.arm_offsets.should eq([0_u64, 0_u64, 0_u64])

    schedules = CrystalClick::DynamicDiscriminatorCodec.decode(structure, stream)
    first = schedules[0]
    tags = first.tags
    tags[0] = 0xff_u8
    ranks = first.ranks
    ranks[0] = 99_i32
    counts = first.arm_counts
    counts[1] = 99_u64
    offsets = first.arm_offsets
    offsets[1] = 99_u64
    first.tags.should eq([1_u8])
    first.ranks.should eq([0_i32] of Int32?)
    first.arm_counts.should eq([0_u64, 1_u64, 0_u64])
    first.arm_offsets.should eq([0_u64, 0_u64, 0_u64])
  end
end
