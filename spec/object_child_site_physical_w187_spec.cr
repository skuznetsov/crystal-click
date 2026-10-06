require "./spec_helper"
require "file_utils"

private def w187_object_limits : CrystalClick::BinaryCodecLimits
  CrystalClick::ObjectDocumentCodec::DEFAULT_LIMITS
end

private def w187_object_plan : CrystalClick::ObjectDocumentPlan
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new(["d"]),
    {"d" => CrystalClick::DynamicStructure.new([CrystalClick::BinaryDataType.primitive("String")])},
  )
  CrystalClick::ObjectDocumentPlan.new(
    structures,
    {"v" => CrystalClick::BinaryDataType.primitive("UInt64")},
  )
end

private def w187_document(value : UInt64, dynamic : String) : CrystalClick::ObjectDocument
  CrystalClick::ObjectDocument.new({
    "v" => CrystalClick::BinaryValue.uint64(value),
    "d" => CrystalClick::BinaryValue.string(dynamic),
  })
end

private def w187_occurrence_grid(
  budget : CrystalClick::BinaryCodecBudget,
  logical : Array(UInt64) = [0_u64, 1_u64, 3_u64],
) : CrystalClick::StorageOccurrenceGrid
  CrystalClick::StorageOccurrenceGrid.new([2_u64, 2_u64, 2_u64], logical, budget)
end

private def w187_child_files(
  codec_budget : CrystalClick::BinaryCodecBudget = CrystalClick::BinaryCodecBudget.new(w187_object_limits, true),
  logical : Array(UInt64) = [0_u64, 1_u64, 3_u64],
  mode : UInt64 = CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
  array_level : UInt64 = 0_u64,
) : CrystalClick::ObjectDocumentColumnFiles
  grid = w187_occurrence_grid(codec_budget, logical)
  plan = w187_object_plan
  prefix = "pair%2Eleft"
  names = CrystalClick::PhysicalStreamPlanContext.new(w187_object_limits)
  physical = CrystalClick::ObjectDocumentPhysicalPlan.from_escaped_prefix(
    prefix,
    plan,
    CrystalClick::BinaryBulkProfile.single_stream,
    CrystalClick::BinaryBulkProfile.single_stream,
    w187_object_limits,
    array_level,
    names,
  )
  values = [7_u64, 11_u64, 13_u64, 17_u64]
  labels = ["seven", "eleven", "thirteen", "seventeen"]
  next_value = 0
  documents = Array(Array(CrystalClick::ObjectDocument)).new(logical.size)
  logical.each do |count|
    mark_rows = Array(CrystalClick::ObjectDocument).new(count.to_i)
    count.to_i.times do
      mark_rows << w187_document(values[next_value], labels[next_value])
      next_value += 1
    end
    documents << mark_rows
  end
  CrystalClick::ObjectDocumentColumnWriter.encode_child_at_physical_site(
    prefix,
    plan,
    physical,
    grid,
    documents,
    codec_budget,
    CrystalClick::CompressedStreamBudget.write_default,
    mode: mode,
    frame_bytes: 64,
    initial_array_level: array_level,
  )
end

private def w187_write_varuint(io, value : UInt64) : Nil
  remaining = value
  while remaining >= 128_u64
    io.write_byte(((remaining & 127_u64) | 128_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w187_write_string(io, value : String) : Nil
  w187_write_varuint(io, value.bytesize.to_u64)
  io.write(value.to_slice)
end

private def w187_with_part(files : CrystalClick::ObjectDocumentColumnFiles, &)
  path = File.tempname("crystal-click-w187-object-child")
  Dir.mkdir(path)
  begin
    files.file_names.each do |name|
      File.open(File.join(path, name), "wb") { |io| io.write(files.file_bytes(name)) }
    end

    payload = IO::Memory.new
    w187_write_varuint(payload, files.file_names.size.to_u64)
    files.file_names.each do |name|
      bytes = files.file_bytes(name)
      w187_write_string(payload, name)
      w187_write_varuint(payload, bytes.size.to_u64)
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

private def w187_read_child(
  source : CrystalClick::PartStreamSource,
  logical : Array(UInt64) = [0_u64, 1_u64, 3_u64],
  first_mark : Int = 0,
  mark_count : Int? = nil,
  array_level : UInt64 = 0_u64,
) : Array(Array(CrystalClick::ObjectDocument))
  limits = w187_object_limits
  budget = CrystalClick::BinaryCodecBudget.new(limits)
  grid = w187_occurrence_grid(budget, logical)
  CrystalClick::ObjectDocumentFileReader.read_child_at_site(
    source,
    "pair%2Eleft",
    {"v" => CrystalClick::BinaryDataType.primitive("UInt64")},
    grid,
    budget,
    CrystalClick::PhysicalStreamPlanContext.new(limits),
    CrystalClick::CompressedStreamBudget.read_default,
    first_mark: first_mark,
    mark_count: mark_count,
    initial_array_level: array_level,
  )
end

describe "W187 explicit-grid Object child-site composition" do
  it "emits parent mark rows while encoding mixed and repeated empty child occurrences" do
    files = w187_child_files
    files.stream_names.includes?("pair%2Eleft.size0").should be_false
    files.physical.initial_array_level.should eq(0_u64)

    logical_name = "pair%2Eleft.v"
    data_name = logical_name + ".bin"
    marks_name = logical_name + ".mrk2"
    w187_with_part(files) do |source|
      physical = source.inspect_grid(data_name, marks_name)
      physical.rows_per_mark.should eq([2_u64, 2_u64, 2_u64])
      files.stream_names.each do |stream_name|
        lane_grid = source.inspect_grid(stream_name + ".bin", stream_name + ".mrk2")
        lane_grid.rows_per_mark.should eq([2_u64, 2_u64, 2_u64])
      end

      descriptor_budget = CrystalClick::BinaryCodecBudget.new(w187_object_limits)
      descriptor_grid = w187_occurrence_grid(descriptor_budget)
      descriptor = CrystalClick::ObjectDocumentFileReader.inspect_child_at_site(
        source,
        "pair%2Eleft",
        {"v" => CrystalClick::BinaryDataType.primitive("UInt64")},
        descriptor_grid,
        descriptor_budget,
        CrystalClick::PhysicalStreamPlanContext.new(w187_object_limits),
        CrystalClick::CompressedStreamBudget.read_default,
      )
      descriptor.mark_row_counts.should eq([2_u64, 2_u64, 2_u64])
      descriptor.child_occurrence_row_counts(0, 3).should eq([0_u64, 1_u64, 3_u64])

      full = w187_read_child(source)
      full.map(&.size).should eq([0, 1, 3])
      full[1][0].value_for("v").as_uint64.should eq(7_u64)
      full[2].map { |document| document.value_for("v").as_uint64 }.should eq([11_u64, 13_u64, 17_u64])

      middle = w187_read_child(source, first_mark: 1, mark_count: 1)
      middle.map(&.size).should eq([1])
      middle[0][0].value_for("d").as_string.should eq("seven")
    end
  end

  it "rejects a same-total per-mark redistribution and a wrong physical grid even for an empty selection" do
    files = w187_child_files
    w187_with_part(files) do |source|
      expect_raises(CrystalClick::CorruptPartError) do
        # Same total C=4, but does not match the authored [0,1,3] lane extents.
        w187_read_child(source, logical: [0_u64, 3_u64, 1_u64])
      end

      expect_raises(CrystalClick::CorruptPartError) do
        # Parent mark rows must match the complete Object physical grid before
        # an empty selected window can be returned.
        limits = w187_object_limits
        budget = CrystalClick::BinaryCodecBudget.new(limits)
        bad_grid = CrystalClick::StorageOccurrenceGrid.new(
          [2_u64, 3_u64, 1_u64], [0_u64, 1_u64, 3_u64], budget
        )
        CrystalClick::ObjectDocumentFileReader.read_child_at_site(
          source,
          "pair%2Eleft",
          {"v" => CrystalClick::BinaryDataType.primitive("UInt64")},
          bad_grid,
          budget,
          CrystalClick::PhysicalStreamPlanContext.new(limits),
          CrystalClick::CompressedStreamBudget.read_default,
          first_mark: 1,
          mark_count: 0,
        )
      end
    end
  end

  it "supports COMPACT child marks and nonzero Array-level naming" do
    files = w187_child_files(
      mode: CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE,
      array_level: 2_u64,
    )
    files.physical.initial_array_level.should eq(2_u64)
    files.stream_names.includes?("pair%2Eleft.size2").should be_false
    files.stream_names.includes?("pair%2Eleft.object_shared_data.size2").should be_true
    w187_with_part(files) do |source|
      full = w187_read_child(source, array_level: 2_u64)
      full.map(&.size).should eq([0, 1, 3])
    end
  end

  it "keeps a fully empty child site readable without any inferred size stream" do
    empty = w187_child_files(logical: [0_u64, 0_u64, 0_u64])
    empty.stream_names.includes?("pair%2Eleft.size0").should be_false
    empty.stream_names.includes?("pair%2Eleft.object_shared_data.size0").should be_true
    w187_with_part(empty) do |source|
      all = w187_read_child(source, logical: [0_u64, 0_u64, 0_u64])
      all.map(&.size).should eq([0, 0, 0])
    end
  end
end
