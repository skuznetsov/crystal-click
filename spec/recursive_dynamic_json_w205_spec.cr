require "./spec_helper"
require "file_utils"

private def w205_schema(
  limits : CrystalClick::BinaryCodecLimits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
) : CrystalClick::StorageColumnSchema
  CrystalClick::StorageColumnSchema.parse(
    "Array(Tuple(doc JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8), " +
    "d Dynamic(max_types=1)))",
    limits,
  )
end

private def w205_json_schema(
  limits : CrystalClick::BinaryCodecLimits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
) : CrystalClick::ObjectDocumentSchema
  CrystalClick::ObjectDocumentSchema.parse_declaration(
    "JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8)", limits
  )
end

private def w205_object_plan(schema : CrystalClick::ObjectDocumentSchema) : CrystalClick::ObjectDocumentPlan
  CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    ),
    schema.typed_paths,
  )
end

private def w205_dynamic_plan(
  limits : CrystalClick::BinaryCodecLimits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
  profile : CrystalClick::BinaryBulkProfile = CrystalClick::BinaryBulkProfile.single_stream,
) : CrystalClick::BinaryDynamicBulkPlan
  dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
  low_cardinality_string = CrystalClick::BinaryDataType.low_cardinality(
    CrystalClick::BinaryDataType.primitive("String")
  )
  CrystalClick::BinaryDynamicBulkPlan.new(
    dynamic,
    {"root" => CrystalClick::DynamicStructure.new(
      [low_cardinality_string] of CrystalClick::BinaryDataType
    )},
    profile,
    limits: limits,
  )
end

private def w205_dynamic_plans(
  plan : CrystalClick::BinaryDynamicBulkPlan,
) : Hash(String, CrystalClick::BinaryDynamicBulkPlan)
  {"root/array[0]/tuple[1]" => plan}
end

private def w205_empty_granules : Array(Array(CrystalClick::StorageColumnValue))
  empty = CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue)
  Array(Array(CrystalClick::StorageColumnValue)).new(4) do
    [empty, empty] of CrystalClick::StorageColumnValue
  end
end

private def w205_with_parent(label : String, & : String ->)
  parent = File.tempname("crystal-click-w205-#{label}-")
  Dir.mkdir(parent)
  yield parent
ensure
  FileUtils.rm_rf(parent) if parent && Dir.exists?(parent)
end

describe "W205 whole-part zero-occurrence JSON/Dynamic boundary" do
  it "round-trips an unused LC actual roster through the public recursive part reader and table" do
    limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
    schema = w205_schema(limits)
    json_schema = w205_json_schema(limits)
    dynamic_plan = w205_dynamic_plan(limits)
    object_plans = {"root/array[0]/tuple[0]" => w205_object_plan(json_schema)}
    dynamic_plans = w205_dynamic_plans(dynamic_plan)
    write_plan = CrystalClick::RecursiveStorageColumnPlan.for_column(
      "payload", schema, object_plans, hashed: true, dynamic_plans: dynamic_plans
    )

    dynamic_site = write_plan.dynamic_site_at(0)
    dynamic_site.key.should eq("root/array[0]/tuple[1]")
    dynamic_site.plan.low_cardinality_schedule_grid_count.should eq(1_u64)
    dynamic_site.plan.structure_for("root").canonical_variant_names.should eq(
      ["LowCardinality(String)", "SharedVariant"] of String
    )
    dynamic_site.plan.shared_index("root").should eq(1)
    dynamic_site.physical.stream_names.should eq({
      "root.arm.0.dictionary" => "payload%2Ed.LowCardinality%28String%29.dict",
      "root.arm.0.indexes"    => "payload%2Ed.LowCardinality%28String%29",
      "root.arm.1.data"       => "payload%2Ed.SharedVariant",
      "root.discriminators"   => "payload%2Ed.variant_discr",
      "root.dynamic_structure" => "payload%2Ed.dynamic_structure",
    })

    object_site = write_plan.object_site_at(0)
    object_site.key.should eq("root/array[0]/tuple[0]")
    object_site.physical.stream_names.includes?("payload%2Edoc.object_structure").should be_true
    object_site.physical.stream_names.includes?("payload%2Edoc.t").should be_true
    object_site.physical.stream_names.includes?(
      "payload%2Edoc.object_shared_data.size1"
    ).should be_true
    object_site.physical.stream_names.includes?(
      "payload%2Edoc.object_shared_data%2Epaths"
    ).should be_true
    object_site.physical.stream_names.includes?(
      "payload%2Edoc.object_shared_data%2Evalues"
    ).should be_true

    keys = Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64, 8_u64]
    w205_with_parent("unused-lc-whole-part") do |parent|
      part = File.join(parent, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_recursive_pair(
        part, "pk", keys, "payload", schema, object_plans, w205_empty_granules,
        rows_per_mark: 2,
        limits: limits,
        dynamic_plans: dynamic_plans,
      )

      expected_names = write_plan.physical_stream_names.sort!
      File.read(File.join(part, "columns_substreams.txt")).lines.any? { |line|
        line.strip == "#{expected_names.size} substreams for column `payload`:"
      }.should be_true
      write_plan.file_names.each do |name|
        File.file?(File.join(part, name)).should be_true
      end

      reader = CrystalClick::RecursiveStorageColumnReader.open(part, "payload", schema)
      reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])
      reader.physical_stream_names.sort!.should eq(expected_names)
      full = reader.read_marks(0, reader.mark_count)
      full.size.should eq(4)
      full.each do |mark_rows|
        mark_rows.size.should eq(2)
        mark_rows.each do |row|
          row.array?.should be_true
          row.child_count.should eq(0)
        end
      end
      reader.read_marks(1, 2).flatten.size.should eq(4)
      reader.read_marks(3, 1).flatten.size.should eq(2)

      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      observed_keys = [] of UInt64
      callbacks = 0
      table.scan_typed_candidate_marks([[0, 1, 2, 3]]) do |batch|
        callbacks += 1
        observed_keys.concat(batch.values_for("pk", UInt64))
        rows = batch.recursive_values_for("payload")
        rows.size.should eq(2)
        rows.each do |row|
          row.array?.should be_true
          row.child_count.should eq(0)
        end
      end
      callbacks.should eq(4)
      observed_keys.should eq(keys.to_a)

      ending = [] of UInt64
      table.scan_typed_window(6_u64, 2) do |batch|
        ending.concat(batch.values_for("pk", UInt64))
        batch.recursive_values_for("payload").each do |row|
          row.array?.should be_true
          row.child_count.should eq(0)
        end
      end
      ending.should eq([7_u64, 8_u64])
    end
  end
end
