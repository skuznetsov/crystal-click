require "./spec_helper"

private class W127BudgetOrderProbe < CrystalClick::ObjectDocument
  def path_count : Int32
    raise "statistics sizing descended into a document before budget admission"
  end
end

private class W127RosterSizeProbe < CrystalClick::ObjectStructure
  def dynamic_path_byte_size(index : Int) : Int32
    raise "statistics sizing queried a roster name before budget admission"
  end
end

describe "W127 Object statistics recomputation" do
  it "installs fresh zero counts while preserving the explicit rosters" do
    old_object = CrystalClick::StructureStatistics.new([41_u64], [] of CrystalClick::StructureStatistic)
    old_dynamic = CrystalClick::StructureStatistics.new([42_u64, 43_u64], [] of CrystalClick::StructureStatistic)
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["dynamic.path"], statistics: old_object),
      {"dynamic.path" => CrystalClick::DynamicStructure.new(
        [CrystalClick::BinaryDataType.primitive("String")],
        statistics: old_dynamic
      )}
    )
    typed = {"typed.path" => CrystalClick::BinaryDataType.primitive("UInt64")}
    plan = CrystalClick::ObjectDocumentPlan.new(structures, typed)

    fresh = CrystalClick::ObjectDocumentStatistics.recompute(
      plan,
      [] of Array(CrystalClick::ObjectDocument)
    )

    fresh.structures.object.version.should eq(4_u64)
    fresh.structures.object.shared_data_version.should eq(0_u64)
    fresh.structures.object.bucket_count.should eq(1_u64)
    fresh.structures.object.dynamic_paths.should eq(["dynamic.path"] of String)
    fresh.typed_paths.should eq(typed)
    fresh.structures.object.statistics.not_nil!.counts.should eq([0_u64])
    fresh.structures.object.statistics.not_nil!.shared.should be_empty
    fresh.structures.dynamic_for("dynamic.path").statistics.not_nil!.counts.should eq([0_u64, 0_u64])
    fresh.structures.dynamic_for("dynamic.path").statistics.not_nil!.shared.should be_empty

    plan.structures.object.statistics.not_nil!.count_at(0).should eq(41_u64)
    plan.structures.dynamic_for("dynamic.path").statistics.not_nil!.count_at(0).should eq(42_u64)
    typed.should eq({"typed.path" => CrystalClick::BinaryDataType.primitive("UInt64")})
  end

  it "admits the grid budget before querying descendant path metadata" do
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure
    )
    plan = CrystalClick::ObjectDocumentPlan.new(structures, {} of String => CrystalClick::BinaryDataType)
    probe = W127BudgetOrderProbe.new({} of String => CrystalClick::BinaryValue)
    rows = [probe] of CrystalClick::ObjectDocument
    granules = [rows] of Array(CrystalClick::ObjectDocument)
    limits = CrystalClick::BinaryCodecLimits.new(max_depth: 64, max_nodes: 0, max_elements: 16, max_bytes: 256)

    error = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentStatistics.recompute(plan, granules, limits)
    end
    error.message.should eq("binary codec node limit exceeded")
  end

  it "admits roster work before querying dynamic path byte sizes" do
    object = W127RosterSizeProbe.new(["dynamic.path"])
    dynamics = {"dynamic.path" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)}
    structures = CrystalClick::ObjectDynamicStructureSet.new(object, dynamics)
    plan = CrystalClick::ObjectDocumentPlan.new(structures, {} of String => CrystalClick::BinaryDataType)
    limits = CrystalClick::BinaryCodecLimits.new(max_depth: 64, max_nodes: 0, max_elements: 16, max_bytes: 256)

    error = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentStatistics.recompute(plan, [] of Array(CrystalClick::ObjectDocument), limits)
    end
    error.message.should eq("binary codec node limit exceeded")
  end

  it "admits roster edges before querying dynamic path byte sizes" do
    object = W127RosterSizeProbe.new(["dynamic.path"])
    dynamics = {"dynamic.path" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)}
    structures = CrystalClick::ObjectDynamicStructureSet.new(object, dynamics)
    plan = CrystalClick::ObjectDocumentPlan.new(structures, {} of String => CrystalClick::BinaryDataType)
    limits = CrystalClick::BinaryCodecLimits.new(max_depth: 64, max_nodes: 16, max_elements: 0, max_bytes: 256)

    error = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentStatistics.recompute(plan, [] of Array(CrystalClick::ObjectDocument), limits)
    end
    error.message.should eq("binary codec element limit exceeded")
  end
end
