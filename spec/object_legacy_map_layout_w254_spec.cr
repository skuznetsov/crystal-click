require "./spec_helper"

private def w254_legacy_plan(version : UInt64, legacy_max : UInt64? = nil) : CrystalClick::ObjectDocumentPlan
  stats = CrystalClick::StructureStatistics.new(
    [2_u64] of UInt64,
    [] of CrystalClick::StructureStatistic,
  )
  uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
  object = CrystalClick::ObjectStructure.new(
    ["d"] of String,
    version: version,
    shared_data_version: 0_u64,
    bucket_count: 1_u64,
    legacy_max_dynamic_paths: legacy_max,
    statistics: stats,
  )
  CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      object,
      {"d" => CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType)},
    ),
    {"id" => CrystalClick::BinaryDataType.primitive("UInt64")},
  )
end

private def w254_schema : CrystalClick::ObjectDocumentSchema
  CrystalClick::ObjectDocumentSchema.new(
    {"id" => CrystalClick::BinaryDataType.primitive("UInt64")},
  )
end

private def w254_v3_structure_header(shared_data_version : UInt8, bucket_count : Bytes? = nil) : Bytes
  # Empty V3 roster followed by the shared-data version and optional bucket
  # count. The fixture stops before statistics because every invalid case is
  # rejected while parsing this header.
  bytes = Bytes[4_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, shared_data_version]
  if count = bucket_count
    joined = Bytes.new(bytes.size + count.size)
    bytes.each_with_index { |byte, index| joined[index] = byte }
    count.each_with_index { |byte, index| joined[bytes.size + index] = byte }
    joined
  else
    bytes
  end
end

private def w254_descendant_inline_fixture
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  json_type = CrystalClick::BinaryDataType.json(
    max_dynamic_paths: 0,
    max_dynamic_types: 0,
    typed_paths: {"v" => uint8} of String => CrystalClick::BinaryDataType,
  )
  actuals = CrystalClick::DynamicStructure.new([json_type] of CrystalClick::BinaryDataType)
  json_key = CrystalClick::BinaryDynamicJsonLeafKey.new(
    "root", actuals.canonical_index_for(json_type), [] of Int32,
  )
  legacy_child_object = CrystalClick::ObjectStructure.new(
    [] of String,
    version: 0_u64,
    legacy_max_dynamic_paths: 0_u64,
    statistics: CrystalClick::StructureStatistics.new(
      [] of UInt64,
      [] of CrystalClick::StructureStatistic,
    ),
  )
  child_plan = CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      legacy_child_object,
      {} of String => CrystalClick::DynamicStructure,
    ),
    json_type.json_type.not_nil!.typed_paths,
  )
  root_plan = CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(
        ["payload"] of String,
        version: 4_u64,
        shared_data_version: 0_u64,
        bucket_count: 1_u64,
        statistics: CrystalClick::StructureStatistics.new(
          [1_u64] of UInt64,
          [] of CrystalClick::StructureStatistic,
        ),
      ),
      {"payload" => actuals} of String => CrystalClick::DynamicStructure,
    ),
    {} of String => CrystalClick::BinaryDataType,
    root_dynamic_json_object_leaf_plans: {
      "payload" => [{json_key, child_plan}] of Tuple(
        CrystalClick::BinaryDynamicJsonLeafKey,
        CrystalClick::ObjectDocumentPlan,
      ),
    } of String => Array(Tuple(
      CrystalClick::BinaryDynamicJsonLeafKey,
      CrystalClick::ObjectDocumentPlan,
    )),
  )

  json_value = CrystalClick::BinaryValue.json(
    json_type,
    CrystalClick::BinaryJsonRow.new(
      json_type,
      [{"v", CrystalClick::BinaryValue.fixed(uint8, Bytes[7_u8])}] of Tuple(
        String,
        CrystalClick::BinaryValue,
      ),
    ),
  )
  parent_row = CrystalClick::ObjectDocument.new({
    # Inferred Object Dynamic paths carry their runtime actual directly; the
    # declared typed-path form uses a Dynamic wrapper instead.
    "payload" => json_value,
  } of String => CrystalClick::BinaryValue)
  granules = [[parent_row] of CrystalClick::ObjectDocument] of Array(CrystalClick::ObjectDocument)
  budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true)
  grid = CrystalClick::StorageOccurrenceGrid.new([1_u64], [1_u64], budget)
  streams = CrystalClick::ObjectDocumentCodec.encode_child_site_with_budget(
    root_plan,
    granules,
    grid,
    budget,
  )
  profile = CrystalClick::BinaryBulkProfile.single_stream
  physical = CrystalClick::ObjectDocumentPhysicalPlan.from_escaped_prefix(
    ".root",
    root_plan,
    profile,
  )
  nested_context = CrystalClick::ObjectSharedNestedSerializationContext.for_write(
    0_u64,
    2_i32,
    profile,
  )
  {root_plan, streams, grid, budget, physical, nested_context}
end

private def w254_rows : Array(Array(CrystalClick::ObjectDocument))
  [
    [
      CrystalClick::ObjectDocument.new({
        "id" => CrystalClick::BinaryValue.uint64(1_u64),
        "d"  => CrystalClick::BinaryValue.uint64(100_u64),
      } of String => CrystalClick::BinaryValue),
      CrystalClick::ObjectDocument.new({
        "id" => CrystalClick::BinaryValue.uint64(2_u64),
        "d"  => CrystalClick::BinaryValue.string("map-spill"),
      } of String => CrystalClick::BinaryValue),
    ] of CrystalClick::ObjectDocument,
  ] of Array(CrystalClick::ObjectDocument)
end

private def w254_write_and_read_structure(
  version : UInt64,
  legacy_max : UInt64?,
) : Tuple(CrystalClick::ObjectStructure, Array(Array(CrystalClick::ObjectDocument)))
  parent = File.tempname("crystal-click-w254-object-map-")
  Dir.mkdir(parent)
  part = File.join(parent, "part")
  begin
    keys = [1_u64, 2_u64]
    CrystalClick::WidePartWriter.write_uint64_object_pair(
      part,
      "pk",
      keys.to_unsafe.to_slice(keys.size),
      "payload",
      w254_schema,
      w254_legacy_plan(version, legacy_max),
      w254_rows,
      rows_per_mark: 2,
      frame_bytes: 64,
    )
    descriptor = CrystalClick::ObjectDocumentFileReader.inspect(
      part,
      "payload",
      w254_schema.typed_paths,
      hashed: true,
    )
    rows = CrystalClick::ObjectDocumentFileReader.read(
      part,
      "payload",
      w254_schema.typed_paths,
      hashed: true,
    )
    {descriptor.plan.structures.object, rows}
  ensure
    FileUtils.rm_rf(parent)
  end
end

describe "W254 complete legacy JSON Object MAP layouts" do
  it "admits complete V2 MAP metadata through schema and physical planning" do
    plan = w254_legacy_plan(2_u64)
    schema = w254_schema

    schema.validate_plan(plan).should be_nil
    physical = CrystalClick::ObjectDocumentPhysicalPlan.new("payload", plan)
    physical.shared_bucket_count.should eq(1)
  end

  it "keeps the explicit V1 version while recomputing its legacy field from actual paths" do
    supplied = w254_legacy_plan(0_u64, 9_u64).structures.object
    decoded_supplied = CrystalClick::ObjectStructureCodec.decode(
      CrystalClick::ObjectStructureCodec.encode(supplied),
    )
    decoded_supplied.legacy_max_dynamic_paths.should eq(9_u64)
    decoded_supplied.should eq(supplied)

    written = w254_write_and_read_structure(0_u64, 9_u64)
    structure = written[0]

    structure.version.should eq(0_u64)
    structure.shared_data_version.should eq(0_u64)
    structure.bucket_count.should eq(1_u64)
    # ClickHouse's V1 writer serializes the actual path count in this legacy
    # slot; the configured cap (9 in the input plan) is not persisted.
    structure.legacy_max_dynamic_paths.should eq(1_u64)
    structure.dynamic_paths.should eq(["d"] of String)
    structure.statistics.not_nil!.counts.should eq([2_u64] of UInt64)
    written[1][0][0].value_for("d").as_uint64.should eq(100_u64)
    written[1][0][1].value_for("d").as_string.should eq("map-spill")
  end

  it "keeps the explicit V2 version through public writer statistics recomputation" do
    written = w254_write_and_read_structure(2_u64, nil)
    structure = written[0]

    structure.version.should eq(2_u64)
    structure.shared_data_version.should eq(0_u64)
    structure.bucket_count.should eq(1_u64)
    structure.legacy_max_dynamic_paths.should be_nil
    structure.dynamic_paths.should eq(["d"] of String)
    structure.statistics.not_nil!.counts.should eq([2_u64] of UInt64)
    written[1][0][0].value_for("d").as_uint64.should eq(100_u64)
    written[1][0][1].value_for("d").as_string.should eq("map-spill")
  end

  it "rejects native-only versions, non-MAP legacy descriptors, and invalid V3 MAP headers" do
    [1_u64, 3_u64].each do |version|
      header = Bytes.new(8) { |index| ((version >> (index * 8)) & 0xff_u64).to_u8 }
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::ObjectStructureCodec.decode(header)
      end
      expect_raises(ArgumentError) do
        CrystalClick::ObjectStructure.new([] of String, version: version)
      end
    end

    empty_stats = CrystalClick::StructureStatistics.new(
      [] of UInt64,
      [] of CrystalClick::StructureStatistic,
    )
    expect_raises(ArgumentError, /require MAP with one bucket/) do
      CrystalClick::ObjectStructure.new(
        [] of String,
        version: 0_u64,
        shared_data_version: 1_u64,
        legacy_max_dynamic_paths: 0_u64,
        statistics: empty_stats,
      )
    end
    expect_raises(ArgumentError, /require MAP with one bucket/) do
      CrystalClick::ObjectStructure.new(
        [] of String,
        version: 2_u64,
        bucket_count: 2_u64,
        statistics: empty_stats,
      )
    end

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectStructureCodec.decode(w254_v3_structure_header(4_u8))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectStructureCodec.decode(w254_v3_structure_header(1_u8, Bytes[0_u8]))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectStructureCodec.decode(w254_v3_structure_header(1_u8, Bytes[0x81_u8, 0x02_u8]))
    end
  end

  it "rejects missing mandatory V1/V2 statistics and malformed legacy fields" do
    [0_u64, 2_u64].each do |version|
      object = w254_legacy_plan(version, version == 0_u64 ? 9_u64 : nil).structures.object
      complete = CrystalClick::ObjectStructureCodec.encode(object)
      truncated = Bytes.new(complete.size - 1) { |index| complete[index] }
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::ObjectStructureCodec.decode(truncated)
      end
    end

    expect_raises(ArgumentError, /requires its legacy maximum-path field/) do
      CrystalClick::ObjectStructure.new(
        [] of String,
        version: 0_u64,
        statistics: CrystalClick::StructureStatistics.new(
          [] of UInt64,
          [] of CrystalClick::StructureStatistic,
        ),
      )
    end
    expect_raises(ArgumentError, /has no legacy maximum-path field/) do
      CrystalClick::ObjectStructure.new(
        [] of String,
        version: 2_u64,
        legacy_max_dynamic_paths: 9_u64,
        statistics: CrystalClick::StructureStatistics.new(
          [] of UInt64,
          [] of CrystalClick::StructureStatistic,
        ),
      )
    end
    expect_raises(ArgumentError, /requires complete legacy statistics/) do
      CrystalClick::ObjectStructure.new(
        [] of String,
        version: 2_u64,
      )
    end
    expect_raises(ArgumentError, /statistics count does not match/) do
      CrystalClick::ObjectStructure.new(
        ["d"] of String,
        version: 2_u64,
        statistics: CrystalClick::StructureStatistics.new(
          [] of UInt64,
          [] of CrystalClick::StructureStatistic,
        ),
      )
    end
  end

  it "refuses V1/V2 root Object metadata from both public inline exporters" do
    [0_u64, 2_u64].each do |version|
      legacy_max = version == 0_u64 ? 9_u64 : nil
      plan = w254_legacy_plan(version, legacy_max)
      profile = CrystalClick::BinaryBulkProfile.single_stream
      budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true)
      grid = CrystalClick::StorageOccurrenceGrid.new([2_u64], [2_u64], budget)
      streams = CrystalClick::ObjectDocumentCodec.encode_child_site_with_budget(
        plan,
        w254_rows,
        grid,
        budget,
        profile: profile,
      )
      physical = CrystalClick::ObjectDocumentPhysicalPlan.from_escaped_prefix(".legacy", plan, profile)

      expect_raises(CrystalClick::UnsupportedFormatError, /inline child Object prefixes require Object V3 metadata/) do
        CrystalClick::ObjectDocumentColumnWriter.inline_fragments_at_child_site(
          physical, plan, streams, grid, budget, profile,
        )
      end
      nested_context = CrystalClick::ObjectSharedNestedSerializationContext.for_write(
        0_u64,
        2_i32,
        profile,
      )
      expect_raises(CrystalClick::UnsupportedFormatError, /inline child Object prefixes require Object V3 metadata/) do
        CrystalClick::ObjectDocumentColumnWriter.inline_raw_layout_at_child_site(
          physical,
          plan,
          streams,
          grid,
          budget,
          nested_context,
          nil,
          ".legacy",
        )
      end
    end
  end

  it "refuses a legacy JSON child beneath a V3 root before returning any inline layout" do
    plan, streams, grid, budget, physical, nested_context = w254_descendant_inline_fixture

    expect_raises(CrystalClick::UnsupportedFormatError, /inline child Object prefixes require Object V3 metadata/) do
      CrystalClick::ObjectDocumentColumnWriter.inline_raw_layout_at_child_site(
        physical,
        plan,
        streams,
        grid,
        budget,
        nested_context,
        nil,
        ".root",
      )
    end
  end
end
