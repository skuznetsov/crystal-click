require "./spec_helper"

private def w188_structure : CrystalClick::DynamicStructure
  CrystalClick::DynamicStructure.new([
    CrystalClick::BinaryDataType.primitive("UInt8"),
    CrystalClick::BinaryDataType.primitive("String"),
  ] of CrystalClick::BinaryDataType)
end

private def w188_budget(writing : Bool) : CrystalClick::BinaryCodecBudget
  limits = CrystalClick::BinaryCodecLimits.new(
    max_depth: 64,
    max_nodes: 100_000,
    max_elements: 300_000,
    max_bytes: 4 * 1024 * 1024,
  )
  CrystalClick::BinaryCodecBudget.new(limits, writing)
end

private def w188_grid(logical : Array(UInt64) = [0_u64, 1_u64, 3_u64, 0_u64]) : CrystalClick::StorageOccurrenceGrid
  CrystalClick::StorageOccurrenceGrid.new(
    [2_u64, 2_u64, 2_u64, 2_u64],
    logical,
    w188_budget(true),
  )
end

private def w188_compact_literal : CrystalClick::DynamicDiscriminatorStream
  # Independently authored COMPACT header and bodies. Marks 0 and 3 are real
  # parent groups with no child occurrences, so both have zero body extent.
  CrystalClick::DynamicDiscriminatorStream.new(
    Bytes[
      0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x01_u8, 0x01_u8, 0x01_u8,
      0x03_u8, 0x00_u8, 0x02_u8, 0xff_u8, 0x01_u8,
    ],
    [
      CrystalClick::DynamicDiscriminatorMark.new(8_u64, 0_u64),
      CrystalClick::DynamicDiscriminatorMark.new(8_u64, 1_u64),
      CrystalClick::DynamicDiscriminatorMark.new(11_u64, 3_u64),
      CrystalClick::DynamicDiscriminatorMark.new(16_u64, 0_u64),
      CrystalClick::DynamicDiscriminatorMark.new(16_u64, 0_u64),
    ] of CrystalClick::DynamicDiscriminatorMark,
  )
end

private def w188_tags : Array(Array(UInt8))
  [
    [] of UInt8,
    [1_u8],
    [2_u8, 255_u8, 1_u8],
    [] of UInt8,
  ] of Array(UInt8)
end

private def w188_dynamic_values : Array(Array(CrystalClick::BinaryValue))
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  [
    [] of CrystalClick::BinaryValue,
    [CrystalClick::BinaryValue.string("one")],
    [
      CrystalClick::BinaryValue.fixed(uint8, Bytes[7_u8]),
      CrystalClick::BinaryValue.null,
      CrystalClick::BinaryValue.string("tail"),
    ] of CrystalClick::BinaryValue,
    [] of CrystalClick::BinaryValue,
  ] of Array(CrystalClick::BinaryValue)
end

describe "W188 COMPACT Dynamic child occurrence grids" do
  it "encodes and decodes literal COMPACT groups over P=[2,2,2,2], C=[0,1,3,0]" do
    structure = w188_structure
    structure.canonical_variant_names.should eq([
      "SharedVariant", "String", "UInt8",
    ] of String)
    grid = w188_grid

    encoded = CrystalClick::DynamicDiscriminatorCodec.encode_child_site_with_budget(
      structure,
      w188_tags,
      grid,
      w188_budget(true),
      mode: CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE,
    )
    encoded.bytes.should eq(w188_compact_literal.bytes)
    encoded.marks.map { |mark| {mark.offset, mark.rows} }.should eq([
      {8_u64, 0_u64}, {8_u64, 1_u64}, {11_u64, 3_u64},
      {16_u64, 0_u64}, {16_u64, 0_u64},
    ])

    full = CrystalClick::DynamicDiscriminatorCodec.decode_child_site_with_budget(
      structure, w188_compact_literal, grid, w188_budget(false)
    )
    full.map(&.row_count).should eq([0, 1, 3, 0])
    full.map(&.mark_index).should eq([0, 1, 2, 3])
    full.map(&.first_row).should eq([0_u64, 0_u64, 1_u64, 4_u64])
    full[0].tags.should be_empty
    full[1].tags.should eq([1_u8])
    full[1].ranks.should eq([0_i32] of Int32?)
    full[1].arm_counts.should eq([0_u64, 1_u64, 0_u64])
    full[2].tags.should eq([2_u8, 255_u8, 1_u8])
    full[2].ranks.should eq([0_i32, nil, 0_i32] of Int32?)
    full[2].arm_counts.should eq([0_u64, 1_u64, 1_u64])
    full[3].tags.should be_empty

    middle = CrystalClick::DynamicDiscriminatorCodec.decode_child_site_with_budget(
      structure,
      w188_compact_literal,
      grid,
      w188_budget(false),
      first_mark: 2,
      mark_count: 2,
    )
    middle.map(&.mark_index).should eq([2, 3])
    middle.map(&.first_row).should eq([1_u64, 4_u64])
    middle[0].tags.should eq([2_u8, 255_u8, 1_u8])
    # Ranks and offsets are relative to the selected window, not prior marks.
    middle[0].arm_offsets.should eq([0_u64, 0_u64, 0_u64])

    empty_window = CrystalClick::DynamicDiscriminatorCodec.decode_child_site_with_budget(
      structure,
      w188_compact_literal,
      grid,
      w188_budget(false),
      first_mark: 4,
      mark_count: 0,
    )
    empty_window.should be_empty
  end

  it "uses a nontrivial uniform form and keeps root COMPACT behavior admitted" do
    structure = w188_structure
    basic_grid = w188_grid
    basic = CrystalClick::DynamicDiscriminatorCodec.encode_child_site_with_budget(
      structure,
      w188_tags,
      basic_grid,
      w188_budget(true),
      mode: CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
    )
    basic.bytes.should eq(Bytes[
      0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x01_u8, 0x02_u8, 0xff_u8, 0x01_u8,
    ])
    basic.marks.map { |mark| {mark.offset, mark.rows} }.should eq([
      {8_u64, 0_u64}, {8_u64, 1_u64}, {9_u64, 3_u64},
      {12_u64, 0_u64}, {12_u64, 0_u64},
    ])
    CrystalClick::DynamicDiscriminatorCodec.decode_child_site_with_budget(
      structure, basic, basic_grid, w188_budget(false)
    ).map(&.row_count).should eq([0, 1, 3, 0])

    uniform_grid = w188_grid([0_u64, 2_u64, 3_u64, 0_u64])
    tags = [
      [] of UInt8,
      [1_u8, 1_u8],
      [2_u8, 255_u8, 1_u8],
      [] of UInt8,
    ] of Array(UInt8)
    encoded = CrystalClick::DynamicDiscriminatorCodec.encode_child_site_with_budget(
      structure,
      tags,
      uniform_grid,
      w188_budget(true),
      mode: CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE,
    )
    encoded.bytes.should eq(Bytes[
      0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x02_u8, 0x01_u8, 0x01_u8,
      0x03_u8, 0x00_u8, 0x02_u8, 0xff_u8, 0x01_u8,
    ])
    CrystalClick::DynamicDiscriminatorCodec.decode_child_site_with_budget(
      structure, encoded, uniform_grid, w188_budget(false)
    ).map(&.row_count).should eq([0, 2, 3, 0])

    root = CrystalClick::DynamicDiscriminatorCodec.encode(
      structure,
      [[1_u8, 1_u8], [2_u8, 255_u8]] of Array(UInt8),
      mode: CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE,
    )
    root.bytes.should eq(Bytes[
      0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x02_u8, 0x01_u8, 0x01_u8,
      0x02_u8, 0x00_u8, 0x02_u8, 0xff_u8,
    ])
    CrystalClick::DynamicDiscriminatorCodec.decode(structure, root).map(&.row_count).should eq([2, 2])
  end

  it "retains the global COMPACT header for an all-empty child grid" do
    structure = w188_structure
    grid = CrystalClick::StorageOccurrenceGrid.new(
      [2_u64, 2_u64],
      [0_u64, 0_u64],
      w188_budget(true),
    )
    encoded = CrystalClick::DynamicDiscriminatorCodec.encode_child_site_with_budget(
      structure,
      [[] of UInt8, [] of UInt8] of Array(UInt8),
      grid,
      w188_budget(true),
      mode: CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE,
    )
    encoded.bytes.should eq(Bytes[
      0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    ])
    encoded.marks.map { |mark| {mark.offset, mark.rows} }.should eq([
      {8_u64, 0_u64}, {8_u64, 0_u64}, {8_u64, 0_u64},
    ])
    decoded = CrystalClick::DynamicDiscriminatorCodec.decode_child_site_with_budget(
      structure, encoded, grid, w188_budget(false)
    )
    decoded.map(&.row_count).should eq([0, 0])

    synthetic_empty_frame = CrystalClick::DynamicDiscriminatorStream.new(
      Bytes[
        0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
        0x00_u8, 0x01_u8, 0xff_u8,
      ],
      [
        CrystalClick::DynamicDiscriminatorMark.new(8_u64, 0_u64),
        CrystalClick::DynamicDiscriminatorMark.new(11_u64, 0_u64),
        CrystalClick::DynamicDiscriminatorMark.new(11_u64, 0_u64),
      ] of CrystalClick::DynamicDiscriminatorMark,
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicDiscriminatorCodec.decode_child_site_with_budget(
        structure, synthetic_empty_frame, grid, w188_budget(false), first_mark: 2, mark_count: 0
      )
    end

    malformed_header = CrystalClick::DynamicDiscriminatorStream.new(
      Bytes[0x02_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8],
      [
        CrystalClick::DynamicDiscriminatorMark.new(8_u64, 0_u64),
        CrystalClick::DynamicDiscriminatorMark.new(8_u64, 0_u64),
        CrystalClick::DynamicDiscriminatorMark.new(8_u64, 0_u64),
      ] of CrystalClick::DynamicDiscriminatorMark,
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicDiscriminatorCodec.decode_child_site_with_budget(
        structure, malformed_header, grid, w188_budget(false), first_mark: 2, mark_count: 0
      )
    end
  end

  it "rejects inner count, format, extent, and per-mark grid corruption even on an empty selection" do
    structure = w188_structure
    grid = w188_grid

    wrong_inner_count = CrystalClick::DynamicDiscriminatorStream.new(
      Bytes[
        0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
        0x02_u8, 0x01_u8, 0x01_u8,
        0x03_u8, 0x00_u8, 0x02_u8, 0xff_u8, 0x01_u8,
      ],
      [
        CrystalClick::DynamicDiscriminatorMark.new(8_u64, 0_u64),
        CrystalClick::DynamicDiscriminatorMark.new(8_u64, 1_u64),
        CrystalClick::DynamicDiscriminatorMark.new(11_u64, 3_u64),
        CrystalClick::DynamicDiscriminatorMark.new(16_u64, 0_u64),
        CrystalClick::DynamicDiscriminatorMark.new(16_u64, 0_u64),
      ] of CrystalClick::DynamicDiscriminatorMark,
    )
    nonminimal_inner_count = CrystalClick::DynamicDiscriminatorStream.new(
      Bytes[
        0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
        0x81_u8, 0x00_u8, 0x01_u8, 0x01_u8,
        0x03_u8, 0x00_u8, 0x02_u8, 0xff_u8, 0x01_u8,
      ],
      [
        CrystalClick::DynamicDiscriminatorMark.new(8_u64, 0_u64),
        CrystalClick::DynamicDiscriminatorMark.new(8_u64, 1_u64),
        CrystalClick::DynamicDiscriminatorMark.new(12_u64, 3_u64),
        CrystalClick::DynamicDiscriminatorMark.new(17_u64, 0_u64),
        CrystalClick::DynamicDiscriminatorMark.new(17_u64, 0_u64),
      ] of CrystalClick::DynamicDiscriminatorMark,
    )
    unknown_format = CrystalClick::DynamicDiscriminatorStream.new(
      Bytes[
        0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
        0x01_u8, 0x02_u8, 0x01_u8,
        0x03_u8, 0x00_u8, 0x02_u8, 0xff_u8, 0x01_u8,
      ],
      [
        CrystalClick::DynamicDiscriminatorMark.new(8_u64, 0_u64),
        CrystalClick::DynamicDiscriminatorMark.new(8_u64, 1_u64),
        CrystalClick::DynamicDiscriminatorMark.new(11_u64, 3_u64),
        CrystalClick::DynamicDiscriminatorMark.new(16_u64, 0_u64),
        CrystalClick::DynamicDiscriminatorMark.new(16_u64, 0_u64),
      ] of CrystalClick::DynamicDiscriminatorMark,
    )
    truncated_uniform = CrystalClick::DynamicDiscriminatorStream.new(
      Bytes[
        0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
        0x01_u8, 0x01_u8, 0x01_u8,
        0x03_u8, 0x01_u8,
      ],
      [
        CrystalClick::DynamicDiscriminatorMark.new(8_u64, 0_u64),
        CrystalClick::DynamicDiscriminatorMark.new(8_u64, 1_u64),
        CrystalClick::DynamicDiscriminatorMark.new(11_u64, 3_u64),
        CrystalClick::DynamicDiscriminatorMark.new(13_u64, 0_u64),
        CrystalClick::DynamicDiscriminatorMark.new(13_u64, 0_u64),
      ] of CrystalClick::DynamicDiscriminatorMark,
    )

    [wrong_inner_count, nonminimal_inner_count, unknown_format, truncated_uniform].each do |stream|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::DynamicDiscriminatorCodec.decode_child_site_with_budget(
          structure, stream, grid, w188_budget(false)
        )
      end
      # A zero-width selection still validates every mark's count, format, and
      # extent; it merely returns no decoded schedules.
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::DynamicDiscriminatorCodec.decode_child_site_with_budget(
          structure,
          stream,
          grid,
          w188_budget(false),
          first_mark: 4,
          mark_count: 0,
        )
      end
    end

    redistributed = w188_grid([0_u64, 3_u64, 1_u64, 0_u64])
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicDiscriminatorCodec.decode_child_site_with_budget(
        structure,
        w188_compact_literal,
        redistributed,
        w188_budget(false),
        first_mark: 1,
        mark_count: 0,
      )
    end
  end

  it "preflights the complete COMPACT output and input extent against byte caps" do
    structure = w188_structure
    grid = w188_grid
    too_small = CrystalClick::BinaryCodecLimits.new(
      max_depth: 64,
      max_nodes: 100_000,
      max_elements: 300_000,
      max_bytes: 15,
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::DynamicDiscriminatorCodec.encode_child_site_with_budget(
        structure,
        w188_tags,
        grid,
        CrystalClick::BinaryCodecBudget.new(too_small, true),
        mode: CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE,
      )
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicDiscriminatorCodec.decode_child_site_with_budget(
        structure,
        w188_compact_literal,
        grid,
        CrystalClick::BinaryCodecBudget.new(too_small),
      )
    end

    # The full stream is 16 bytes. A zero-width selection still pays the
    # 8-byte global header and both positive groups' 2-byte framing prefixes,
    # but it does not pay/materialize their tag payloads: exact cap 12 passes.
    zero_window_prefix_budget = CrystalClick::BinaryCodecLimits.new(
      max_depth: 64,
      max_nodes: 100_000,
      max_elements: 300_000,
      max_bytes: 12,
    )
    CrystalClick::DynamicDiscriminatorCodec.decode_child_site_with_budget(
      structure,
      w188_compact_literal,
      grid,
      CrystalClick::BinaryCodecBudget.new(zero_window_prefix_budget),
      first_mark: 4,
      mark_count: 0,
    ).should be_empty

    prefix_too_small = CrystalClick::BinaryCodecLimits.new(
      max_depth: 64,
      max_nodes: 100_000,
      max_elements: 300_000,
      max_bytes: 11,
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicDiscriminatorCodec.decode_child_site_with_budget(
        structure,
        w188_compact_literal,
        grid,
        CrystalClick::BinaryCodecBudget.new(prefix_too_small),
        first_mark: 4,
        mark_count: 0,
      )
    end

    # Mark 2 contributes its 5 selected bytes; mark 1 is structurally scanned
    # but only its 2-byte prefix is charged. The omitted unselected tag makes
    # this exact 15-byte cap smaller than the complete 16-byte stream.
    selected_plus_prefix = CrystalClick::BinaryCodecLimits.new(
      max_depth: 64,
      max_nodes: 100_000,
      max_elements: 300_000,
      max_bytes: 15,
    )
    selected = CrystalClick::DynamicDiscriminatorCodec.decode_child_site_with_budget(
      structure,
      w188_compact_literal,
      grid,
      CrystalClick::BinaryCodecBudget.new(selected_plus_prefix),
      first_mark: 2,
      mark_count: 1,
    )
    selected.size.should eq(1)
    selected[0].tags.should eq([2_u8, 255_u8, 1_u8])

    selected_too_small = CrystalClick::BinaryCodecLimits.new(
      max_depth: 64,
      max_nodes: 100_000,
      max_elements: 300_000,
      max_bytes: 14,
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicDiscriminatorCodec.decode_child_site_with_budget(
        structure,
        w188_compact_literal,
        grid,
        CrystalClick::BinaryCodecBudget.new(selected_too_small),
        first_mark: 2,
        mark_count: 1,
      )
    end
  end

  it "structurally checks unselected frames but validates roster tags only in the selected window" do
    structure = w188_structure
    grid = w188_grid
    invalid_unselected_tag = CrystalClick::DynamicDiscriminatorStream.new(
      Bytes[
        0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
        0x01_u8, 0x01_u8, 0xfe_u8,
        0x03_u8, 0x00_u8, 0x02_u8, 0xff_u8, 0x01_u8,
      ],
      [
        CrystalClick::DynamicDiscriminatorMark.new(8_u64, 0_u64),
        CrystalClick::DynamicDiscriminatorMark.new(8_u64, 1_u64),
        CrystalClick::DynamicDiscriminatorMark.new(11_u64, 3_u64),
        CrystalClick::DynamicDiscriminatorMark.new(16_u64, 0_u64),
        CrystalClick::DynamicDiscriminatorMark.new(16_u64, 0_u64),
      ] of CrystalClick::DynamicDiscriminatorMark,
    )

    selected = CrystalClick::DynamicDiscriminatorCodec.decode_child_site_with_budget(
      structure,
      invalid_unselected_tag,
      grid,
      w188_budget(false),
      first_mark: 2,
      mark_count: 1,
    )
    selected[0].tags.should eq([2_u8, 255_u8, 1_u8])
    CrystalClick::DynamicDiscriminatorCodec.decode_child_site_with_budget(
      structure,
      invalid_unselected_tag,
      grid,
      w188_budget(false),
      first_mark: 4,
      mark_count: 0,
    ).should be_empty
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicDiscriminatorCodec.decode_child_site_with_budget(
        structure,
        invalid_unselected_tag,
        grid,
        w188_budget(false),
        first_mark: 1,
        mark_count: 1,
      )
    end
  end

  it "round trips child Dynamic values through COMPACT while preserving the literal discriminator" do
    structure = w188_structure
    grid = w188_grid
    streams = CrystalClick::DynamicValueCodec.encode_child_site_with_budget(
      structure,
      w188_dynamic_values,
      grid,
      w188_budget(true),
      mode: CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE,
    )
    streams.discriminators.bytes.should eq(w188_compact_literal.bytes)

    full = CrystalClick::DynamicValueCodec.decode_child_site_with_budget(
      structure, streams, grid, w188_budget(false)
    )
    full.map(&.size).should eq([0, 1, 3, 0])
    full[1][0].as_string.should eq("one")
    full[2][0].type.name.should eq("UInt8")
    full[2][0].byte_at(0).should eq(7_u8)
    full[2][1].is_null?.should be_true
    full[2][2].as_string.should eq("tail")

    middle = CrystalClick::DynamicValueCodec.decode_child_site_with_budget(
      structure,
      streams,
      grid,
      w188_budget(false),
      first_mark: 2,
      mark_count: 2,
    )
    middle.map(&.size).should eq([3, 0])
    middle[0][0].byte_at(0).should eq(7_u8)
    middle[0][1].is_null?.should be_true
    middle[0][2].as_string.should eq("tail")
    CrystalClick::DynamicValueCodec.decode_child_site_with_budget(
      structure,
      streams,
      grid,
      w188_budget(false),
      first_mark: 4,
      mark_count: 0,
    ).should be_empty
  end
end
