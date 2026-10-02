require "./spec_helper"

private class W127PoisonedPhysicalPlan < CrystalClick::ObjectDocumentPhysicalPlan
  def stream_count : Int32
    CrystalClick::PartChecksums::MAX_ENTRIES // 2 + 1
  end

  def stream_names : Array(String)
    raise "detached physical roster was requested before the entry-count preflight"
  end
end

module CrystalClick
  module ObjectDocumentColumnWriter
    # Test-only bridge to the private preflight so a poisoned plan can prove
    # that the entry cap rejects before its detached-name getter is called.
    def self.preflight_file_roster_for_spec(
      physical_plan : ObjectDocumentPhysicalPlan,
      hashed : Bool,
    ) : Hash(String, Tuple(String, String))
      preflight_file_roster(physical_plan, hashed)
    end
  end
end

private def w127_owner_empty_plan : CrystalClick::ObjectDocumentPlan
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new([] of String),
    {} of String => CrystalClick::DynamicStructure
  )
  CrystalClick::ObjectDocumentPlan.new(structures, {} of String => CrystalClick::BinaryDataType)
end

describe CrystalClick::ObjectDocumentColumnFiles do
  it "requires exact physical stream keys and detaches caller-owned rosters" do
    plan = w127_owner_empty_plan
    physical = CrystalClick::ObjectDocumentPhysicalPlan.new("payload", plan)
    names = physical.stream_names
    physical.stream_count.should eq(names.size)
    pairs = Hash(String, CrystalClick::CompressedMarkFiles).new
    file_roster = Hash(String, Tuple(String, String)).new
    names.each do |name|
      pairs[name] = CrystalClick::CompressedMarkFiles.new(Bytes[1], Bytes[2])
      file_roster[name] = {name + ".bin", name + ".mrk2"}
    end

    files = CrystalClick::ObjectDocumentColumnFiles.new(plan, physical, pairs, file_roster)
    pairs.clear
    file_roster.clear

    files.plan.should be(plan)
    files.physical.stream_names.should eq(names)
    files.stream_names.should eq(names)
    files.file_names.should eq(names.flat_map { |name| [name + ".bin", name + ".mrk2"] }.sort)

    wrong_pairs = Hash(String, CrystalClick::CompressedMarkFiles).new
    wrong_roster = Hash(String, Tuple(String, String)).new
    wrong_pairs["not-a-physical-stream"] = CrystalClick::CompressedMarkFiles.new(Bytes[1], Bytes[2])
    wrong_roster["not-a-physical-stream"] = {"not-a-physical-stream.bin", "not-a-physical-stream.mrk2"}
    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentColumnFiles.new(plan, physical, wrong_pairs, wrong_roster)
    end
  end
end

describe CrystalClick::ObjectDocumentColumnWriter do
  it "rejects an oversized scalar roster before requesting detached names" do
    physical = W127PoisonedPhysicalPlan.new("payload", w127_owner_empty_plan)
    error = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentColumnWriter.preflight_file_roster_for_spec(physical, false)
    end
    error.message.should eq("Object column file roster exceeds checksums entry limit")
  end
end
