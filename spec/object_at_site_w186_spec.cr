require "./spec_helper"
require "file_utils"

private def w186_site_limits : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
end

private def w186_site_plan : CrystalClick::ObjectDocumentPlan
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new(["d"]),
    {"d" => CrystalClick::DynamicStructure.new([CrystalClick::BinaryDataType.primitive("String")])},
  )
  CrystalClick::ObjectDocumentPlan.new(
    structures,
    {"v" => CrystalClick::BinaryDataType.primitive("UInt64")},
  )
end

private def w186_site_documents : Array(Array(CrystalClick::ObjectDocument))
  [
    [CrystalClick::ObjectDocument.new({"v" => CrystalClick::BinaryValue.uint64(1_u64), "d" => CrystalClick::BinaryValue.string("one")})],
    [
      CrystalClick::ObjectDocument.new({"v" => CrystalClick::BinaryValue.uint64(2_u64), "d" => CrystalClick::BinaryValue.string("two")}),
      CrystalClick::ObjectDocument.new({"v" => CrystalClick::BinaryValue.uint64(3_u64), "d" => CrystalClick::BinaryValue.string("three")}),
    ],
    [CrystalClick::ObjectDocument.new({"v" => CrystalClick::BinaryValue.uint64(4_u64), "d" => CrystalClick::BinaryValue.string("four")})],
  ]
end

private def w186_site_files(
  codec_budget : CrystalClick::BinaryCodecBudget = CrystalClick::BinaryCodecBudget.new(w186_site_limits, true),
  name_context : CrystalClick::PhysicalStreamPlanContext = CrystalClick::PhysicalStreamPlanContext.new(w186_site_limits),
  transport_budget : CrystalClick::CompressedStreamBudget = CrystalClick::CompressedStreamBudget.write_default,
  prefix : String = "pair%2Eleft",
) : CrystalClick::ObjectDocumentColumnFiles
  CrystalClick::ObjectDocumentColumnWriter.encode_at_site(
    prefix,
    w186_site_plan,
    w186_site_documents,
    codec_budget,
    name_context,
    transport_budget,
  )
end

private def w186_write_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 128_u64
    io.write_byte(((remaining & 127_u64) | 128_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w186_write_string(io : IO, value : String) : Nil
  w186_write_varuint(io, value.bytesize.to_u64)
  io.write(value.to_slice)
end

private def w186_with_part(files : CrystalClick::ObjectDocumentColumnFiles, &)
  path = File.tempname("crystal-click-w186-object-site")
  Dir.mkdir(path)
  begin
    files.file_names.each do |name|
      File.open(File.join(path, name), "wb") { |io| io.write(files.file_bytes(name)) }
    end

    payload = IO::Memory.new
    w186_write_varuint(payload, files.file_names.size.to_u64)
    files.file_names.each do |name|
      bytes = files.file_bytes(name)
      w186_write_string(payload, name)
      w186_write_varuint(payload, bytes.size.to_u64)
      payload.write(Bytes.new(16, 0_u8))
      payload.write_byte(0_u8)
    end
    checksums_frame = CrystalClick::CompressedMarkWriter.encode_all(payload.to_slice)
    File.open(File.join(path, "checksums.txt"), "wb") do |io|
      io << CrystalClick::PartChecksums::CHECKSUMS_HEADER
      io.write(checksums_frame)
    end

    yield CrystalClick::PartStreamSource.new(path)
  ensure
    FileUtils.rm_rf(path)
  end
end

private def w186_read_site(
  source : CrystalClick::PartStreamSource,
  first_mark : Int = 0,
  mark_count : Int? = nil,
  expected_rows : Array(UInt64)? = nil,
  codec_budget : CrystalClick::BinaryCodecBudget = CrystalClick::BinaryCodecBudget.new(w186_site_limits),
  name_context : CrystalClick::PhysicalStreamPlanContext = CrystalClick::PhysicalStreamPlanContext.new(w186_site_limits),
  transport_budget : CrystalClick::CompressedStreamBudget = CrystalClick::CompressedStreamBudget.read_default,
) : Array(Array(CrystalClick::ObjectDocument))
  CrystalClick::ObjectDocumentFileReader.read_at_site(
    source,
    "pair%2Eleft",
    {"v" => CrystalClick::BinaryDataType.primitive("UInt64")},
    codec_budget,
    name_context,
    transport_budget,
    first_mark: first_mark,
    mark_count: mark_count,
    expected_mark_row_counts: expected_rows,
  )
end

describe "W186 escaped-prefix Object site composition" do
  it "rejects empty, lowercase-escape, and noncanonical prefixes" do
    {"", "pair%2eleft", "pair%2E%6Ce"}.each do |prefix|
      expect_raises(ArgumentError) { w186_site_files(prefix: prefix) }
    end
    CrystalClick::PhysicalStreamName.validate_canonical_escaped_prefix("pair%2Eleft").should be_nil
  end

  it "matches every consistently qualified root lane for a Tuple field prefix" do
    site = w186_site_files
    flattened_root = CrystalClick::ObjectDocumentColumnWriter.encode("pair.left", w186_site_plan, w186_site_documents)

    site.stream_names.should eq(flattened_root.stream_names)
    site.file_names.should eq(flattened_root.file_names)
    site.stream_names.each do |name|
      name.starts_with?("pair%2Eleft").should be_true
      site.pair_for(name).data.should eq(flattened_root.pair_for(name).data)
      site.pair_for(name).marks.should eq(flattened_root.pair_for(name).marks)
    end
    site.stream_names.should contain("pair%2Eleft.object_structure")
    site.stream_names.should contain("pair%2Eleft.v")
    site.stream_names.should contain("pair%2Eleft.d.variant_discr")
  end

  it "reads full and middle mark windows and rejects a bad parent grid before an empty result" do
    files = w186_site_files
    w186_with_part(files) do |source|
      full = w186_read_site(source)
      full.map(&.size).should eq([1, 2, 1])
      full[1][1].value_for("v").as_uint64.should eq(3_u64)
      full[1][1].value_for("d").as_string.should eq("three")

      middle = w186_read_site(source, first_mark: 1, mark_count: 1)
      middle.map(&.size).should eq([2])
      middle[0][0].value_for("v").as_uint64.should eq(2_u64)
      middle[0][1].value_for("d").as_string.should eq("three")

      expect_raises(CrystalClick::CorruptPartError) do
        # Same total rows as the actual [1, 2, 1] grid, but redistributed.
        w186_read_site(source, first_mark: 1, mark_count: 0, expected_rows: [2_u64, 1_u64, 1_u64])
      end
    end
  end

  it "rejects wrong budget directions and a name context with different logical limits" do
    limits = w186_site_limits
    write_transport = CrystalClick::CompressedStreamBudget.write_default
    read_transport = CrystalClick::CompressedStreamBudget.read_default
    good_names = CrystalClick::PhysicalStreamPlanContext.new(limits)

    expect_raises(ArgumentError) do
      w186_site_files(codec_budget: CrystalClick::BinaryCodecBudget.new(limits),
        name_context: good_names, transport_budget: write_transport)
    end
    expect_raises(ArgumentError) do
      w186_site_files(codec_budget: CrystalClick::BinaryCodecBudget.new(limits, true),
        name_context: good_names, transport_budget: read_transport)
    end

    other_limits = CrystalClick::BinaryCodecLimits.new(
      max_depth: limits.max_depth,
      max_nodes: limits.max_nodes - 1,
      max_elements: limits.max_elements,
      max_bytes: limits.max_bytes,
    )
    expect_raises(ArgumentError) do
      w186_site_files(codec_budget: CrystalClick::BinaryCodecBudget.new(limits, true),
        name_context: CrystalClick::PhysicalStreamPlanContext.new(other_limits),
        transport_budget: write_transport)
    end

    files = w186_site_files
    w186_with_part(files) do |source|
      expect_raises(ArgumentError) do
        w186_read_site(source, codec_budget: CrystalClick::BinaryCodecBudget.new(limits, true))
      end
      expect_raises(ArgumentError) do
        w186_read_site(source, transport_budget: write_transport)
      end
      expect_raises(ArgumentError) do
        w186_read_site(source,
          name_context: CrystalClick::PhysicalStreamPlanContext.new(other_limits))
      end
    end
  end
end
