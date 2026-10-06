require "./spec_helper"
require "file_utils"

private def w188oc_limits : CrystalClick::BinaryCodecLimits
  CrystalClick::ObjectDocumentCodec::DEFAULT_LIMITS
end

private def w188oc_plan : CrystalClick::ObjectDocumentPlan
  int64 = CrystalClick::BinaryDataType.primitive("Int64")
  string = CrystalClick::BinaryDataType.primitive("String")
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new(["d"] of String),
    {"d" => CrystalClick::DynamicStructure.new([int64, string] of CrystalClick::BinaryDataType)},
  )
  CrystalClick::ObjectDocumentPlan.new(
    structures,
    {"t" => CrystalClick::BinaryDataType.primitive("UInt8")},
  )
end

private def w188oc_document(byte : UInt8, dynamic : CrystalClick::BinaryValue) : CrystalClick::ObjectDocument
  CrystalClick::ObjectDocument.new({
    "t" => CrystalClick::BinaryValue.fixed(
      CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[byte]
    ),
    "d" => dynamic,
  } of String => CrystalClick::BinaryValue)
end

private def w188oc_granules : Array(Array(CrystalClick::ObjectDocument))
  [
    [] of CrystalClick::ObjectDocument,
    [w188oc_document(11_u8, CrystalClick::BinaryValue.string("blue"))],
    [
      w188oc_document(13_u8, CrystalClick::BinaryValue.int64(42_i64)),
      w188oc_document(14_u8, CrystalClick::BinaryValue.null),
      w188oc_document(15_u8, CrystalClick::BinaryValue.string("green")),
    ] of CrystalClick::ObjectDocument,
    [] of CrystalClick::ObjectDocument,
  ] of Array(CrystalClick::ObjectDocument)
end

private def w188oc_grid(budget : CrystalClick::BinaryCodecBudget) : CrystalClick::StorageOccurrenceGrid
  CrystalClick::StorageOccurrenceGrid.new(
    [2_u64, 2_u64, 2_u64, 2_u64],
    [0_u64, 1_u64, 3_u64, 0_u64],
    budget,
  )
end

private def w188oc_files(
  mode : UInt64 = CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE,
) : CrystalClick::ObjectDocumentColumnFiles
  limits = w188oc_limits
  budget = CrystalClick::BinaryCodecBudget.new(limits, true)
  plan = w188oc_plan
  prefix = "pair%2Eleft"
  physical = CrystalClick::ObjectDocumentPhysicalPlan.from_escaped_prefix(
    prefix,
    plan,
    CrystalClick::BinaryBulkProfile.single_stream,
    CrystalClick::BinaryBulkProfile.single_stream,
    limits,
    0_u64,
    CrystalClick::PhysicalStreamPlanContext.new(limits),
  )
  CrystalClick::ObjectDocumentColumnWriter.encode_child_at_physical_site(
    prefix,
    plan,
    physical,
    w188oc_grid(budget),
    w188oc_granules,
    budget,
    CrystalClick::CompressedStreamBudget.write_default,
    mode: mode,
    frame_bytes: 64,
  )
end

private def w188oc_encode_discriminator_lane(
  bytes : Bytes,
  offsets : Array(UInt64) = [8_u64, 8_u64, 11_u64, 16_u64, 16_u64],
) : CrystalClick::CompressedMarkFiles
  marks = Array(CrystalClick::DynamicDiscriminatorMark).new(5)
  [0_u64, 1_u64, 3_u64, 0_u64, 0_u64].each_with_index do |rows, index|
    marks << CrystalClick::DynamicDiscriminatorMark.new(offsets[index], rows)
  end
  stream = CrystalClick::DynamicDiscriminatorStream.new(bytes, marks)
  lane = CrystalClick::ObjectDocumentColumnLane.new(
    "pair%2Eleft.d.dynamic_structure.discriminators",
    bytes,
    discriminator_source: stream,
    prefix_size: CrystalClick::DynamicDiscriminatorCodec::HEADER_BYTES.to_i,
  )
  limits = w188oc_limits
  grid = w188oc_grid(CrystalClick::BinaryCodecBudget.new(limits, true))
  lane.encode_child_site(grid, 64, CrystalClick::CompressedStreamBudget.write_default)
end

private def w188oc_write_varuint(io, value : UInt64) : Nil
  remaining = value
  while remaining >= 128_u64
    io.write_byte(((remaining & 127_u64) | 128_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w188oc_write_string(io, value : String) : Nil
  w188oc_write_varuint(io, value.bytesize.to_u64)
  io.write(value.to_slice)
end

private def w188oc_with_part(files : CrystalClick::ObjectDocumentColumnFiles, &)
  path = File.tempname("crystal-click-w188-object-compact")
  Dir.mkdir(path)
  begin
    files.file_names.each do |name|
      File.open(File.join(path, name), "wb") { |io| io.write(files.file_bytes(name)) }
    end

    payload = IO::Memory.new
    w188oc_write_varuint(payload, files.file_names.size.to_u64)
    files.file_names.each do |name|
      bytes = files.file_bytes(name)
      w188oc_write_string(payload, name)
      w188oc_write_varuint(payload, bytes.size.to_u64)
      payload.write(Bytes.new(16, 0_u8))
      payload.write_byte(0_u8)
    end
    checksums = CrystalClick::CompressedMarkWriter.encode_all(payload.to_slice)
    File.open(File.join(path, "checksums.txt"), "wb") do |io|
      io << CrystalClick::PartChecksums::CHECKSUMS_HEADER
      io.write(checksums)
    end
    yield CrystalClick::PartStreamSource.new(path)
  ensure
    FileUtils.rm_rf(path)
  end
end

private def w188oc_read(
  source : CrystalClick::PartStreamSource,
  first_mark : Int = 0,
  mark_count : Int? = nil,
) : Array(Array(CrystalClick::ObjectDocument))
  limits = w188oc_limits
  budget = CrystalClick::BinaryCodecBudget.new(limits)
  grid = w188oc_grid(budget)
  CrystalClick::ObjectDocumentFileReader.read_child_at_site(
    source,
    "pair%2Eleft",
    {"t" => CrystalClick::BinaryDataType.primitive("UInt8")},
    grid,
    budget,
    CrystalClick::PhysicalStreamPlanContext.new(limits),
    CrystalClick::CompressedStreamBudget.read_default,
    first_mark: first_mark,
    mark_count: mark_count,
  )
end

describe "W188 Object physical child-site COMPACT discriminator" do
  it "round trips P=[2,2,2,2] separately from C=[0,1,3,0], including NULL and selected windows" do
    files = w188oc_files
    dynamic = CrystalClick::DynamicStructure.new([
      CrystalClick::BinaryDataType.primitive("Int64"),
      CrystalClick::BinaryDataType.primitive("String"),
    ] of CrystalClick::BinaryDataType)
    dynamic.canonical_variant_names.should eq(["Int64", "SharedVariant", "String"] of String)

    discriminator_name = files.physical.discriminator_stream("d")
    files.stream_names.includes?(discriminator_name).should be_true
    w188oc_with_part(files) do |source|
      # Every .mrk2 remains on the parent's four-mark physical row grid.
      files.stream_names.each do |name|
        grid = source.inspect_grid(name + ".bin", name + ".mrk2")
        grid.rows_per_mark.should eq([2_u64, 2_u64, 2_u64, 2_u64])
      end

      # The eight-byte coordinate prefix is Dynamic's global mode header.
      # Empty child groups add no per-mark bytes after it.
      discriminator = source.read_window(
        discriminator_name + ".bin",
        discriminator_name + ".mrk2",
        0,
        4,
        CrystalClick::DynamicDiscriminatorCodec::HEADER_BYTES.to_i,
        CrystalClick::CompressedStreamBudget.read_default,
      )
      discriminator.rows_per_mark.should eq([2_u64, 2_u64, 2_u64, 2_u64])
      discriminator.offsets.should eq([8_u64, 8_u64, 11_u64, 16_u64, 16_u64])
      discriminator.bytes.should eq(Bytes[
        0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
        0x01_u8, 0x01_u8, 0x02_u8,
        0x03_u8, 0x00_u8, 0x00_u8, 0xff_u8, 0x02_u8,
      ])

      full = w188oc_read(source)
      full.map(&.size).should eq([0, 1, 3, 0])
      full[1][0].value_for("t").byte_at(0).should eq(11_u8)
      full[1][0].value_for("d").as_string.should eq("blue")
      full[2].map { |document| document.value_for("t").byte_at(0) }.should eq([13_u8, 14_u8, 15_u8])
      full[2][0].value_for("d").as_int64.should eq(42_i64)
      # Positive untyped Dynamic NULL survives as a tag/input occurrence but
      # normalizes to absence of the dynamic path in the decoded document.
      full[2][1].has_path?("d").should be_false
      full[2][2].value_for("d").as_string.should eq("green")

      middle = w188oc_read(source, first_mark: 2, mark_count: 2)
      middle.map(&.size).should eq([3, 0])
      middle[0][0].value_for("d").as_int64.should eq(42_i64)
      middle[0][1].has_path?("d").should be_false
      middle[0][2].value_for("d").as_string.should eq("green")

      w188oc_read(source, first_mark: 4, mark_count: 0).should be_empty
    end
  end

  it "admits declared typed Dynamic in the COMPACT discriminator profile" do
    string = CrystalClick::BinaryDataType.primitive("String")
    dynamic_type = CrystalClick::BinaryDataType.dynamic(1)
    declared = CrystalClick::ObjectDocumentPlan.new(
      CrystalClick::ObjectDynamicStructureSet.new(
        CrystalClick::ObjectStructure.new([] of String),
        {} of String => CrystalClick::DynamicStructure,
      ),
      {"td" => dynamic_type},
      {"td" => CrystalClick::DynamicStructure.new([string] of CrystalClick::BinaryDataType)},
    )
    document = CrystalClick::ObjectDocument.new({
      "td" => CrystalClick::BinaryValue.dynamic(dynamic_type, CrystalClick::BinaryValue.string("value")),
    } of String => CrystalClick::BinaryValue)

    streams = CrystalClick::ObjectDocumentCodec.encode(
      declared,
      [[document]] of Array(CrystalClick::ObjectDocument),
      mode: CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE,
    )
    streams.typed_dynamic_mode.should eq(CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE)
    decoded = CrystalClick::ObjectDocumentCodec.decode({"td" => dynamic_type}, streams)
    decoded[0][0].value_for("td").child_at(0).as_string.should eq("value")
  end

  it "rejects malformed COMPACT mode, C=0 body, and per-mark count before returning lane files" do
    compact_prefix = Bytes[
      0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    ]
    malformed_count = Bytes[
      0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x02_u8, 0x01_u8, 0x02_u8,
      0x03_u8, 0x00_u8, 0x00_u8, 0xff_u8, 0x02_u8,
    ]
    count_error = expect_raises(CrystalClick::UnsupportedFormatError) do
      w188oc_encode_discriminator_lane(malformed_count)
    end
    count_error.message.not_nil!.should contain("COMPACT row count does not equal its mark rows")

    malformed_empty = Bytes[
      compact_prefix[0], compact_prefix[1], compact_prefix[2], compact_prefix[3],
      compact_prefix[4], compact_prefix[5], compact_prefix[6], compact_prefix[7],
      0xff_u8,
      0x01_u8, 0x01_u8, 0x02_u8,
      0x03_u8, 0x00_u8, 0x00_u8, 0xff_u8, 0x02_u8,
    ]
    empty_error = expect_raises(CrystalClick::UnsupportedFormatError) do
      w188oc_encode_discriminator_lane(malformed_empty, [8_u64, 9_u64, 12_u64, 17_u64, 17_u64])
    end
    empty_error.message.not_nil!.should contain("empty Dynamic COMPACT child group contains body bytes")

    malformed_mode = malformed_count.dup
    malformed_mode[0] = 0x02_u8
    mode_error = expect_raises(CrystalClick::UnsupportedFormatError) do
      w188oc_encode_discriminator_lane(malformed_mode)
    end
    mode_error.message.not_nil!.should contain("unknown Dynamic discriminator mode")

    expect_raises(CrystalClick::UnsupportedFormatError) do
      w188oc_files(2_u64)
    end
  end
end
