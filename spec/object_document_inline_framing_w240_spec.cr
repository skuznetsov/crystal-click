require "./spec_helper"

private def w240fr_budget(writing : Bool) : CrystalClick::BinaryCodecBudget
  CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, writing: writing)
end

private def w240fr_with_lane_files(files : CrystalClick::CompressedMarkFiles, & : Bytes ->)
  directory = File.tempname("crystal-click-w240-framing-")
  Dir.mkdir(directory)
  begin
    data_path = File.join(directory, "lane.bin")
    marks_path = File.join(directory, "lane.mrk2")
    File.write(data_path, files.data)
    File.write(marks_path, files.marks)
    window = CrystalClick::CompressedMarkReader.read(
      data_path,
      marks_path,
      files.data.size.to_i64,
      files.marks.size.to_i64,
      first_mark: 0,
      mark_count: 1,
      prefix_size: 8,
      budget: CrystalClick::CompressedStreamBudget.read_default,
    )
    yield window.bytes
  ensure
    FileUtils.rm_rf(directory) if Dir.exists?(directory)
  end
end

describe "W240 inline child physical framing" do
  it "uses the literal Compact mode-1 Variant frame only for inline callbacks" do
    source = CrystalClick::BinaryBulkStream.new(
      Bytes[0x00_u8, 0x00_u8, 0x01_u8],
      [0_u64, 3_u64],
    )
    grid = CrystalClick::StorageOccurrenceGrid.new(
      [1_u64], [3_u64], w240fr_budget(true),
    )
    lane = CrystalClick::ObjectDocumentColumnLane.new(
      ".child.a.variant_discr",
      source.borrowed_slice(0, source.byte_size),
      nil,
      source,
      nil,
      8,
      "root.discriminators",
    )

    callbacks = lane.inline_fragments_for_child_site(grid, w240fr_budget(true))
    callbacks.map(&.[0]).should eq([
      ".child.a.variant_discr_prefix",
      ".child.a.variant_discr",
    ])
    callbacks[0][1].should eq(Bytes[1_u8, 0, 0, 0, 0, 0, 0, 0])
    # Compact mode 1: varUInt(3), row-tags format 0, then three tags.
    callbacks[1][1].should eq(Bytes[3_u8, 0, 0, 0, 1])

    # The ordinary Wide lane encoder remains BASIC mode 0.
    wide = lane.encode([3_u64], 4096, CrystalClick::CompressedStreamBudget.write_default)
    w240fr_with_lane_files(wide) do |bytes|
      bytes.should eq(Bytes[0_u8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
    end
  end

  it "keeps the LowCardinality dictionary UInt64(1) in its inline prefix callback" do
    source = CrystalClick::BinaryBulkStream.new(
      Bytes[1_u8, 0, 0, 0, 0, 0, 0, 0, 0x44_u8],
      [8_u64, 9_u64],
    )
    grid = CrystalClick::StorageOccurrenceGrid.new(
      [1_u64], [1_u64], w240fr_budget(true),
    )
    lane = CrystalClick::ObjectDocumentColumnLane.new(
      ".child.b.dict",
      source.borrowed_slice(0, source.byte_size),
      nil,
      source,
      nil,
      8,
    )

    callbacks = lane.inline_fragments_for_child_site(grid, w240fr_budget(true))
    callbacks.map(&.[0]).should eq([".child.b.dict_prefix", ".child.b.dict"])
    callbacks[0][1].should eq(Bytes[1_u8, 0, 0, 0, 0, 0, 0, 0])
    callbacks[1][1].should eq(Bytes[0x44_u8])
  end

  it "does not infer LowCardinality framing from a `.dict` basename" do
    grid = CrystalClick::StorageOccurrenceGrid.new(
      [1_u64], [1_u64], w240fr_budget(true),
    )
    ordinary_source = CrystalClick::BinaryBulkStream.new(
      Bytes[0x44_u8], [0_u64, 1_u64],
    )
    ordinary = CrystalClick::ObjectDocumentColumnLane.new(
      ".child.dict",
      ordinary_source.borrowed_slice(0, ordinary_source.byte_size),
      nil,
      ordinary_source,
    )
    callbacks = ordinary.inline_fragments_for_child_site(grid, w240fr_budget(true))
    callbacks.should eq([{".child.dict", Bytes[0x44_u8]}])

    unsupported_source = CrystalClick::BinaryBulkStream.new(
      Bytes[0x44_u8], [0_u64, 1_u64],
    )
    unsupported = CrystalClick::ObjectDocumentColumnLane.new(
      ".child.bad.dict",
      unsupported_source.borrowed_slice(0, unsupported_source.byte_size),
      nil,
      unsupported_source,
      nil,
      4,
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      unsupported.inline_fragments_for_child_site(grid, w240fr_budget(true))
    end
  end
end
