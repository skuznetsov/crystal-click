require "./spec_helper"

private def w189_framing_budget(max_bytes : Int, max_elements : Int, writing : Bool)
  limits = CrystalClick::BinaryCodecLimits.new(
    max_depth: 1,
    max_nodes: 8,
    max_elements: max_elements,
    max_bytes: max_bytes,
  )
  CrystalClick::BinaryCodecBudget.new(limits, writing: writing)
end

private def w189_framing_role : String
  "json.x.discriminators"
end

private def w189_mode_header(mode : UInt8) : Bytes
  Bytes[mode, 0, 0, 0, 0, 0, 0, 0]
end

describe "W189 typed Dynamic physical discriminator framing" do
  it "writes and reads literal BASIC/COMPACT lanes with repeated empty mark coordinates" do
    source = CrystalClick::BinaryBulkStream.new(
      Bytes[255, 255, 1, 2, 1],
      [0_u64, 2_u64, 2_u64, 5_u64],
    )
    adapter = CrystalClick::BinaryBulkDiscriminatorFramingAdapter

    adapter.physical_size(source, 1_u64).should eq(16)
    write_budget = w189_framing_budget(16, 4, true)
    lanes = [{w189_framing_role, source, 1_u64}] of Tuple(
      String,
      CrystalClick::BinaryBulkStream,
      UInt64,
    )
    adapter.preflight_write(lanes, write_budget)
    physical, physical_offsets, prefix = adapter.write_lane(w189_framing_role, source, 1_u64)
    physical.should eq(Bytes[1, 0, 0, 0, 0, 0, 0, 0, 2, 1, 255, 3, 0, 1, 2, 1])
    physical_offsets.should eq([8_u64, 11_u64, 11_u64, 16_u64])
    prefix.should eq(8)

    adapter.validate_header(w189_framing_role, physical, prefix).should eq(1_u64)
    read_budget = w189_framing_budget(13, 4, false)
    CrystalClick::BinaryBulkPhysicalPrefixAdapter.preflight_read(
      [{w189_framing_role, prefix, physical_offsets.size}],
      read_budget,
    )
    logical, logical_offsets, logical_prefix = adapter.read_lane(
      w189_framing_role,
      physical,
      physical_offsets,
      prefix,
      read_budget,
    )
    logical.should eq(Bytes[255, 255, 1, 2, 1])
    logical_offsets.should eq([0_u64, 2_u64, 2_u64, 5_u64])
    logical_prefix.should eq(0)
    {read_budget.wire_byte_count, read_budget.element_count}.should eq({13_i64, 4_i64})
  end

  it "normalizes multiple positive frames within one selected interval and accepts all-empty header-only lanes" do
    adapter = CrystalClick::BinaryBulkDiscriminatorFramingAdapter
    # The selected first interval contains two concatenated frames; the second
    # selected mark is empty. No one-frame-per-mark assumption is made here.
    selected = Bytes[1, 0, 0, 0, 0, 0, 0, 0, 1, 1, 7, 2, 0, 9, 10]
    adapter.validate_header(w189_framing_role, selected, 8).should eq(1_u64)
    selected_budget = w189_framing_budget(13, 3, false)
    CrystalClick::BinaryBulkPhysicalPrefixAdapter.preflight_read(
      [{w189_framing_role, 8, 3}],
      selected_budget,
    )
    selected_tags, selected_offsets, _prefix = adapter.read_lane(
      w189_framing_role,
      selected,
      [8_u64, 15_u64, 15_u64],
      8,
      selected_budget,
    )
    selected_tags.should eq(Bytes[7, 9, 10])
    selected_offsets.should eq([0_u64, 3_u64, 3_u64])
    {selected_budget.wire_byte_count, selected_budget.element_count}.should eq({11_i64, 3_i64})

    empty_source = CrystalClick::BinaryBulkStream.new(Bytes.new(0), [0_u64, 0_u64, 0_u64])
    empty_budget = w189_framing_budget(8, 3, true)
    adapter.preflight_write(
      [{w189_framing_role, empty_source, 1_u64}] of Tuple(String, CrystalClick::BinaryBulkStream, UInt64),
      empty_budget,
    )
    empty_bytes, empty_offsets, _ = adapter.write_lane(w189_framing_role, empty_source, 1_u64)
    empty_bytes.should eq(w189_mode_header(1))
    empty_offsets.should eq([8_u64, 8_u64, 8_u64])
    adapter.validate_header(w189_framing_role, empty_bytes, 8).should eq(1_u64)

    empty_read_budget = w189_framing_budget(11, 3, false)
    CrystalClick::BinaryBulkPhysicalPrefixAdapter.preflight_read(
      [{w189_framing_role, 8, 3}],
      empty_read_budget,
    )
    empty_tags, empty_logical_offsets, _ = adapter.read_lane(
      w189_framing_role,
      empty_bytes,
      empty_offsets,
      8,
      empty_read_budget,
    )
    empty_tags.should be_empty
    empty_logical_offsets.should eq([0_u64, 0_u64, 0_u64])
  end

  it "preserves BASIC mode bytes and leaves the legacy adapter BASIC-only" do
    adapter = CrystalClick::BinaryBulkDiscriminatorFramingAdapter
    source = CrystalClick::BinaryBulkStream.new(Bytes[255, 3], [0_u64, 1_u64, 2_u64])
    adapter.physical_size(source, 0_u64).should eq(10)
    physical, physical_offsets, prefix = adapter.write_lane(w189_framing_role, source, 0_u64)
    physical.should eq(Bytes[0, 0, 0, 0, 0, 0, 0, 0, 255, 3])
    physical_offsets.should eq([8_u64, 9_u64, 10_u64])
    prefix.should eq(8)

    read_budget = w189_framing_budget(8, 3, false)
    CrystalClick::BinaryBulkPhysicalPrefixAdapter.preflight_read(
      [{w189_framing_role, 8, 3}],
      read_budget,
    )
    logical, offsets, logical_prefix = adapter.read_lane(w189_framing_role, physical, physical_offsets, 8, read_budget)
    logical.should eq(Bytes[255, 3])
    offsets.should eq([0_u64, 1_u64, 2_u64])
    logical_prefix.should eq(0)

    compact = Bytes[1, 0, 0, 0, 0, 0, 0, 0, 1, 1, 255]
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkPhysicalPrefixAdapter.read_lane(
        w189_framing_role,
        compact,
        [8_u64, 11_u64],
        8,
      )
    end
  end

  it "preflights aggregate adapted output and coordinate work before two-lane allocation" do
    adapter = CrystalClick::BinaryBulkDiscriminatorFramingAdapter
    first = CrystalClick::BinaryBulkStream.new(Bytes[1, 2], [0_u64, 2_u64])
    second = CrystalClick::BinaryBulkStream.new(Bytes.new(0), [0_u64, 0_u64])
    lanes = [
      {"a.discriminators", first, 1_u64},
      {"b.discriminators", second, 1_u64},
    ] of Tuple(String, CrystalClick::BinaryBulkStream, UInt64)

    exact = w189_framing_budget(20, 4, true)
    adapter.preflight_write(lanes, exact)
    {exact.wire_byte_count, exact.element_count}.should eq({20_i64, 4_i64})
    adapter.write_lane("a.discriminators", first, 1_u64)[0].size.should eq(12)
    adapter.write_lane("b.discriminators", second, 1_u64)[0].size.should eq(8)

    byte_short = w189_framing_budget(19, 4, true)
    expect_raises(CrystalClick::UnsupportedFormatError) { adapter.preflight_write(lanes, byte_short) }
    {byte_short.wire_byte_count, byte_short.element_count}.should eq({0_i64, 0_i64})

    coordinate_short = w189_framing_budget(20, 3, true)
    expect_raises(CrystalClick::UnsupportedFormatError) { adapter.preflight_write(lanes, coordinate_short) }
    {coordinate_short.wire_byte_count, coordinate_short.element_count}.should eq({0_i64, 0_i64})
  end

  it "charges normalized COMPACT expansion after caller-owned header and coordinate preflight" do
    adapter = CrystalClick::BinaryBulkDiscriminatorFramingAdapter
    physical = Bytes[1, 0, 0, 0, 0, 0, 0, 0, 3, 1, 255]
    offsets = [8_u64, 11_u64]

    exact = w189_framing_budget(11, 2, false)
    CrystalClick::BinaryBulkPhysicalPrefixAdapter.preflight_read(
      [{w189_framing_role, 8, 2}],
      exact,
    )
    tags, _normalized_offsets, _prefix = adapter.read_lane(w189_framing_role, physical, offsets, 8, exact)
    tags.should eq(Bytes[255, 255, 255])
    {exact.wire_byte_count, exact.element_count}.should eq({11_i64, 2_i64})

    byte_short = w189_framing_budget(10, 2, false)
    CrystalClick::BinaryBulkPhysicalPrefixAdapter.preflight_read(
      [{w189_framing_role, 8, 2}],
      byte_short,
    )
    expect_raises(CrystalClick::CorruptPartError) do
      adapter.read_lane(w189_framing_role, physical, offsets, 8, byte_short)
    end
    {byte_short.wire_byte_count, byte_short.element_count}.should eq({8_i64, 2_i64})
  end

  it "rejects invalid headers, frames, extents, and logical/physical coordinate grids" do
    adapter = CrystalClick::BinaryBulkDiscriminatorFramingAdapter
    invalid_headers = [
      Bytes[2, 0, 0, 0, 0, 0, 0, 0],
      Bytes[1, 0, 0, 0, 0, 0, 0, 1],
      Bytes[0, 0, 0, 0, 0, 0, 0],
    ]
    invalid_headers.each do |header|
      expect_raises(CrystalClick::CorruptPartError) do
        adapter.validate_header(w189_framing_role, header, 8)
      end
    end
    expect_raises(CrystalClick::CorruptPartError) { adapter.validate_header("wrong.role", w189_mode_header(1), 8) }
    expect_raises(CrystalClick::CorruptPartError) { adapter.validate_header(w189_framing_role, w189_mode_header(1), 7) }

    malformed_frames = [
      Bytes[0, 1, 255],                    # zero count
      Bytes[0x81, 0x00, 1, 255],           # nonminimal count
      Bytes[0x80],                         # truncated count
      Bytes[1, 2, 255],                    # unknown format
      Bytes[2, 0, 255],                    # short row-tag payload
      Bytes[1, 1],                         # short uniform payload
      Bytes[1, 1, 7, 0x80],                # truncated following frame
      Bytes[0xFF, 0xFF, 0xFF, 0xFF, 0x08], # count outside Int32
      Bytes[0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0x02], # UInt64 overflow
    ]
    malformed_frames.each do |body|
      bytes = Bytes.new(8 + body.size) do |index|
        index < 8 ? w189_mode_header(1)[index] : body[index - 8]
      end
      expect_raises(CrystalClick::CorruptPartError) do
        adapter.read_lane(w189_framing_role, bytes, [8_u64, bytes.size.to_u64], 8, w189_framing_budget(4096, 32, false))
      end
    end

    expect_raises(CrystalClick::CorruptPartError) do
      adapter.read_lane(w189_framing_role, w189_mode_header(1), [7_u64], 8, w189_framing_budget(16, 1, false))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      adapter.physical_size(CrystalClick::BinaryBulkStream.new(Bytes[1], [0_u64, 1_u64]), 2_u64)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      adapter.physical_size(CrystalClick::BinaryBulkStream.new(Bytes[1], [1_u64, 1_u64]), 1_u64)
    end
  end

  it "keeps inspect_body exact-one-frame while exposing nonallocating frame inspection" do
    validator = CrystalClick::DynamicDiscriminatorBodyValidator
    joined = Bytes[2, 1, 255, 1, 0, 7]
    validator.inspect_frame(joined, 0).should eq({2_u64, 1_u8, 2_i32, 3_i32})
    validator.inspect_frame(joined, 3).should eq({1_u64, 0_u8, 5_i32, 6_i32})
    validator.inspect_body(1_u64, Bytes[2, 1, 255], 2_u64).should eq({1_u8, 2_i32})
    expect_raises(CrystalClick::CorruptPartError) do
      validator.inspect_body(1_u64, joined, 2_u64)
    end
  end
end
