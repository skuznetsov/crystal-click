require "./spec_helper"

describe "W157 Dynamic structure statistics offsets" do
  it "matches literal structure boundaries for empty, scalar, array, and statistics-bearing blobs" do
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    array_uint64 = CrystalClick::BinaryDataType.array(uint64)
    empty_statistics = CrystalClick::StructureStatistics.new([4_u64], [] of CrystalClick::StructureStatistic)
    cases = [
      {
        CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType),
        Bytes[0x04_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8],
        9_i32,
      },
      {
        CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType),
        Bytes[0x04_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 1_u8, 0x04_u8, 0_u8],
        10_i32,
      },
      {
        CrystalClick::DynamicStructure.new([array_uint64] of CrystalClick::BinaryDataType),
        Bytes[0x04_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 1_u8, 0x1e_u8, 0x04_u8, 0_u8],
        11_i32,
      },
      {
        CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType, empty_statistics),
        Bytes[0x04_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 1_u8, 4_u8, 0_u8],
        9_i32,
      },
    ] of Tuple(CrystalClick::DynamicStructure, Bytes, Int32)
    declared = CrystalClick::BinaryDataType.dynamic(max_types: 0)

    cases.each do |structure, literal, expected_offset|
      plan = CrystalClick::BinaryDynamicBulkPlan.new(declared, {"root" => structure})
      plan.statistics_offset_for("root").should eq(expected_offset)

      encoded = plan.encode_structure_streams(CrystalClick::BinaryCodecBudget.new(
        CrystalClick::BinaryCodecLimits.default, true,
      ))
      encoded.structure_bytes_for("root").should eq(literal)

      supplied = CrystalClick::BinaryDynamicStructureStreams.new({"root" => literal})
      decoded = CrystalClick::BinaryDynamicBulkPlan.decode_structure_streams(
        declared,
        supplied,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
      )
      decoded.statistics_offset_for("root").should eq(expected_offset)
    end
  end

  it "retains the literal pre-statistics boundary when decoding one site" do
    declared = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    literal = Bytes[0x04_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 1_u8, 0x04_u8, 0_u8]
    streams = CrystalClick::BinaryDynamicStructureStreams.new({"root" => literal})
    decoded = CrystalClick::BinaryDynamicBulkPlan.decode_structure_streams(
      declared,
      streams,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
    )

    decoded.structure_for("root").types.should eq([
      CrystalClick::BinaryDataType.primitive("UInt64"),
    ] of CrystalClick::BinaryDataType)
    decoded.statistics_offset_for("root").should eq(10_i32)
  end

  it "keeps occurrence-local offsets through nested actual Array(Dynamic) under both profiles" do
    nominal_left = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    nominal_right = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    declared = CrystalClick::BinaryDataType.tuple(
      [nominal_left, nominal_right] of CrystalClick::BinaryDataType,
    )
    array_dynamic = CrystalClick::BinaryDataType.array(
      CrystalClick::BinaryDataType.dynamic(max_types: 0),
    )
    array_uint64 = CrystalClick::BinaryDataType.array(
      CrystalClick::BinaryDataType.primitive("UInt64"),
    )
    nested_path = "root.field.0.arm.0.elements"
    structures = {
      "root.field.0" => CrystalClick::DynamicStructure.new([array_dynamic] of CrystalClick::BinaryDataType),
      nested_path    => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType),
      "root.field.1" => CrystalClick::DynamicStructure.new([array_uint64] of CrystalClick::BinaryDataType),
    }
    literal_streams = {
      "root.field.0" => Bytes[0x04_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 1_u8, 0x1e_u8, 0x2b_u8, 0_u8, 0_u8],
      nested_path    => Bytes[0x04_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8],
      "root.field.1" => Bytes[0x04_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 1_u8, 0x1e_u8, 0x04_u8, 0_u8],
    }
    expected_offsets = {
      "root.field.0" => 12_i32,
      nested_path    => 9_i32,
      "root.field.1" => 11_i32,
    }
    paths = ["root.field.0", nested_path, "root.field.1"] of String
    nominal_left.should eq(nominal_right)
    plan_streams = CrystalClick::BinaryDynamicStructureStreams.new(literal_streams)

    profiles = [
      CrystalClick::BinaryBulkProfile.single_stream,
      CrystalClick::BinaryBulkProfile.with_size_stream,
    ] of CrystalClick::BinaryBulkProfile
    profiles.each do |profile|
      plan = CrystalClick::BinaryDynamicBulkPlan.new(declared, structures, profile)
      paths.each do |path|
        plan.statistics_offset_for(path).should eq(expected_offsets[path])
      end
      encoded = plan.encode_structure_streams(CrystalClick::BinaryCodecBudget.new(
        CrystalClick::BinaryCodecLimits.default, true,
      ))
      paths.each do |path|
        encoded.structure_bytes_for(path).should eq(literal_streams[path])
      end

      decoded = CrystalClick::BinaryDynamicBulkPlan.decode_structure_streams(
        declared,
        plan_streams,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
        profile,
      )
      paths.each do |path|
        decoded.statistics_offset_for(path).should eq(expected_offsets[path])
      end
    end
  end

  it "keeps the retained offset independent of caller-mutated site snapshots" do
    declared = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    plan = CrystalClick::BinaryDynamicBulkPlan.new(declared, {
      "root" => CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType),
    })

    path_snapshot = plan.site_paths
    path_snapshot[0] = "changed"
    type_snapshot = plan.structure_for("root").types
    type_snapshot.clear

    plan.statistics_offset_for("root").should eq(10_i32)
    plan.site_paths.should eq(["root"] of String)
    plan.structure_for("root").types.should eq([uint64] of CrystalClick::BinaryDataType)
  end

  it "raises KeyError for an unknown site path" do
    declared = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    empty = CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)
    plan = CrystalClick::BinaryDynamicBulkPlan.new(declared, {"root" => empty})

    error = expect_raises(KeyError) do
      plan.statistics_offset_for("missing")
    end
    error.message.should eq("Dynamic site not found: \"missing\"")
  end
end
