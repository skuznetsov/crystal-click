require "./spec_helper"

private def w190sb_plan(bucket_count : UInt64 = 2_u64) : CrystalClick::ObjectDocumentPlan
  uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
  object = CrystalClick::ObjectStructure.new(
    [] of String,
    4_u64,
    1_u64,
    bucket_count,
  )
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    object,
    {} of String => CrystalClick::DynamicStructure,
  )
  CrystalClick::ObjectDocumentPlan.new(structures, {"id" => uint64})
end

private def w190sb_document(id : UInt64, left : String, right : Int64) : CrystalClick::ObjectDocument
  CrystalClick::ObjectDocument.new({
    "id"    => CrystalClick::BinaryValue.uint64(id),
    "left"  => CrystalClick::BinaryValue.string(left),
    "right" => CrystalClick::BinaryValue.int64(right),
  } of String => CrystalClick::BinaryValue)
end

private def w190sb_granules : Array(Array(CrystalClick::ObjectDocument))
  [
    [
      w190sb_document(10_u64, "red", 100_i64),
      w190sb_document(11_u64, "blue", 101_i64),
    ] of CrystalClick::ObjectDocument,
    [w190sb_document(12_u64, "green", 102_i64)] of CrystalClick::ObjectDocument,
  ] of Array(CrystalClick::ObjectDocument)
end

private def w190sb_values(
  granules : Array(Array(CrystalClick::ObjectDocument)),
) : Array(Array(Tuple(UInt64, String, Int64)))
  granules.map do |mark|
    mark.map do |document|
      {
        document.value_for("id").as_uint64,
        document.value_for("left").as_string,
        document.value_for("right").as_int64,
      }
    end
  end
end

private def w190sb_rebuild_streams(
  source : CrystalClick::ObjectDocumentStreams,
  buckets : Array(CrystalClick::BinaryBulkStreams),
) : CrystalClick::ObjectDocumentStreams
  typed = {"id" => source.typed_for("id")} of String => CrystalClick::BinaryBulkStreams
  CrystalClick::ObjectDocumentStreams.new(
    source.structures,
    source.rows_per_mark,
    typed,
    {} of String => CrystalClick::DynamicValueStreams,
    buckets,
  )
end

private def w190sb_limits(
  max_nodes : Int = 4_096,
  max_elements : Int = 1_000_000,
  max_bytes : Int = 64 * 1024 * 1024,
) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: 64,
    max_nodes: max_nodes,
    max_elements: max_elements,
    max_bytes: max_bytes,
  )
end

describe "W190 Object MAP_WITH_BUCKETS shared lanes" do
  it "preflights bucket binding records against the borrowed codec and name owners" do
    plan = w190sb_plan(2_u64)
    physical = CrystalClick::ObjectDocumentPhysicalPlan.new("payload", plan)
    binding_count = physical.shared_bucket(0).stream_count.to_u64 * 2_u64
    limits = w190sb_limits(
      # A fresh owner would fit exactly; the borrowed owner's prior charge
      # must make this preflight fail without consuming any further budget.
      max_nodes: binding_count.to_i,
      max_elements: binding_count.to_i,
    )
    budget = CrystalClick::BinaryCodecBudget.new(limits)
    budget.charge_node
    before = {budget.node_count, budget.element_count, budget.wire_byte_count}

    expect_raises(CrystalClick::CorruptPartError) do
      physical.preflight_shared_bucket_bindings!(false, budget)
    end
    {budget.node_count, budget.element_count, budget.wire_byte_count}.should eq(before)

    ample_budget = CrystalClick::BinaryCodecBudget.new(
      w190sb_limits(
        max_nodes: binding_count.to_i + 1,
        max_elements: binding_count.to_i,
      )
    )
    ample_budget.charge_node
    physical.preflight_shared_bucket_bindings!(false, ample_budget)
    ample_budget.node_count.should eq((binding_count + 1_u64).to_i64)
    ample_budget.element_count.should eq(binding_count.to_i64)
    ample_budget.wire_byte_count.should eq(0_i64)

    # MAP-0 remains outside the new bucket binding charge, even with no room
    # left in the borrowed codec budget.
    map0_object = CrystalClick::ObjectStructure.new([] of String, 4_u64, 0_u64, 1_u64)
    map0_structures = CrystalClick::ObjectDynamicStructureSet.new(
      map0_object,
      {} of String => CrystalClick::DynamicStructure,
    )
    map0_plan = CrystalClick::ObjectDocumentPlan.new(
      map0_structures,
      {"id" => CrystalClick::BinaryDataType.primitive("UInt64")},
    )
    map0_physical = CrystalClick::ObjectDocumentPhysicalPlan.new("payload", map0_plan)
    map0_budget = CrystalClick::BinaryCodecBudget.new(w190sb_limits(max_nodes: 1))
    map0_budget.charge_node
    map0_before = {map0_budget.node_count, map0_budget.element_count, map0_budget.wire_byte_count}
    map0_physical.preflight_shared_bucket_bindings!(false, map0_budget)
    {map0_budget.node_count, map0_budget.element_count, map0_budget.wire_byte_count}.should eq(map0_before)
  end

  it "round trips root rows, selections, and explicit one- versus multi-bucket metadata" do
    plan = w190sb_plan(2_u64)
    documents = w190sb_granules
    schema = CrystalClick::ObjectDocumentSchema.new({
      "id" => CrystalClick::BinaryDataType.primitive("UInt64"),
    })
    schema.validate_plan(plan).should be_nil

    fresh = CrystalClick::ObjectDocumentStatistics.recompute_with_budget(
      plan,
      documents,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::ObjectDocumentCodec::DEFAULT_LIMITS, true),
    )
    fresh.structures.object.shared_data_version.should eq(1_u64)
    fresh.structures.object.bucket_count.should eq(2_u64)

    streams = CrystalClick::ObjectDocumentCodec.encode(fresh, documents)
    encoded_structures = CrystalClick::ObjectDynamicStructureCodec.decode(streams.structures)
    encoded_structures.object.shared_data_version.should eq(1_u64)
    encoded_structures.object.bucket_count.should eq(2_u64)
    streams.shared_bucket_count.should eq(2)
    2.times do |index|
      streams.shared_bucket(index).mark_count.should eq(2)
    end
    expect_raises(ArgumentError) { streams.shared }

    decoded = CrystalClick::ObjectDocumentCodec.decode({
      "id" => CrystalClick::BinaryDataType.primitive("UInt64"),
    }, streams)
    w190sb_values(decoded).should eq([
      [{10_u64, "red", 100_i64}, {11_u64, "blue", 101_i64}],
      [{12_u64, "green", 102_i64}],
    ])

    middle = CrystalClick::ObjectDocumentCodec.decode(
      {"id" => CrystalClick::BinaryDataType.primitive("UInt64")},
      streams,
      first_mark: 1,
      mark_count: 1,
    )
    w190sb_values(middle).should eq([[{12_u64, "green", 102_i64}]])
    CrystalClick::ObjectDocumentCodec.decode(
      {"id" => CrystalClick::BinaryDataType.primitive("UInt64")},
      streams,
      first_mark: 2,
      mark_count: 0,
    ).should be_empty

    # Identical nominal typed schemas retain their caller-authored bucket
    # rosters independently; one-bucket MAP_WITH_BUCKETS is not MAP-0.
    one_bucket = w190sb_plan(1_u64)
    many_buckets = w190sb_plan(32_u64)
    one_physical = CrystalClick::ObjectDocumentPhysicalPlan.new("payload", one_bucket)
    many_physical = CrystalClick::ObjectDocumentPhysicalPlan.new("payload", many_buckets)
    one_physical.shared_bucket_count.should eq(1)
    many_physical.shared_bucket_count.should eq(32)
    one_names = one_physical.stream_names
    one_names.includes?("payload.object_shared_data.0.size0").should be_true
    many_names = many_physical.stream_names
    many_names.includes?("payload.object_shared_data.0.size0").should be_true
    many_names.includes?("payload.object_shared_data.31.size0").should be_true

    map_zero = CrystalClick::ObjectDocumentPlan.new(
      CrystalClick::ObjectDynamicStructureSet.new(
        CrystalClick::ObjectStructure.new([] of String),
        {} of String => CrystalClick::DynamicStructure,
      ),
      {"id" => CrystalClick::BinaryDataType.primitive("UInt64")},
    )
    legacy_names = CrystalClick::ObjectDocumentPhysicalPlan.new("payload", map_zero).stream_names
    legacy_names.includes?("payload.object_shared_data.size0").should be_true
    legacy_names.includes?("payload.object_shared_data.0.size0").should be_false
  end

  it "binds bucket components before map substreams without advancing the inherited Array level" do
    plan = w190sb_plan(2_u64)
    physical = CrystalClick::ObjectDocumentPhysicalPlan.from_escaped_prefix(
      "pair%2Eleft",
      plan,
      initial_array_level: 4_u64,
    )

    bucket_zero_names = physical.shared_bucket(0).stream_names.values
    bucket_one_names = physical.shared_bucket(1).stream_names.values
    bucket_zero_names.any? { |name| name.includes?(".object_shared_data.0") && name.ends_with?("size4") }.should be_true
    bucket_one_names.any? { |name| name.includes?(".object_shared_data.1") && name.ends_with?("size4") }.should be_true
    bucket_zero_names.any? { |name| name.ends_with?("size5") }.should be_false
    bucket_one_names.any? { |name| name.ends_with?("size5") }.should be_false
  end

  it "rejects swapped, missing, and complete-grid-drifted buckets even for a zero selection" do
    plan = w190sb_plan(2_u64)
    streams = CrystalClick::ObjectDocumentCodec.encode(plan, w190sb_granules)
    schema = {"id" => CrystalClick::BinaryDataType.primitive("UInt64")}

    swapped = w190sb_rebuild_streams(streams, [
      streams.shared_bucket(1),
      streams.shared_bucket(0),
    ] of CrystalClick::BinaryBulkStreams)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectDocumentCodec.decode(schema, swapped)
    end

    missing = w190sb_rebuild_streams(streams, [streams.shared_bucket(0)] of CrystalClick::BinaryBulkStreams)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectDocumentCodec.decode(schema, missing, first_mark: 2, mark_count: 0)
    end

    original_bucket = streams.shared_bucket(1)
    wrong_grid_roles = Hash(String, CrystalClick::BinaryBulkStream).new
    original_bucket.roles.each do |role|
      wrong_grid_roles[role] = original_bucket.stream(role)
    end
    wrong_grid = CrystalClick::BinaryBulkStreams.new(original_bucket.mark_count + 1, wrong_grid_roles)
    drifted = w190sb_rebuild_streams(streams, [streams.shared_bucket(0), wrong_grid] of CrystalClick::BinaryBulkStreams)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectDocumentCodec.decode(schema, drifted, first_mark: 2, mark_count: 0)
    end
  end

  it "preserves physical-parent and logical-child grids, including all-empty child marks" do
    plan = w190sb_plan(3_u64)
    limits = CrystalClick::ObjectDocumentCodec::DEFAULT_LIMITS
    write_budget = CrystalClick::BinaryCodecBudget.new(limits, true)
    grid = CrystalClick::StorageOccurrenceGrid.new(
      [2_u64, 3_u64, 2_u64],
      [0_u64, 2_u64, 0_u64],
      write_budget,
    )
    empty = [] of CrystalClick::ObjectDocument
    granules = [
      empty,
      [w190sb_document(20_u64, "middle-a", 200_i64), w190sb_document(21_u64, "middle-b", 201_i64)] of CrystalClick::ObjectDocument,
      empty,
    ] of Array(CrystalClick::ObjectDocument)
    fresh = CrystalClick::ObjectDocumentStatistics.recompute_child_site_with_budget(
      plan, granules, grid, write_budget
    )
    fresh.structures.object.shared_data_version.should eq(1_u64)
    fresh.structures.object.bucket_count.should eq(3_u64)
    streams = CrystalClick::ObjectDocumentCodec.encode_child_site_with_budget(
      fresh,
      granules,
      grid,
      write_budget,
    )
    streams.rows_per_mark.should eq([0_u64, 2_u64, 0_u64])
    streams.shared_bucket_count.should eq(3)
    3.times do |index|
      streams.shared_bucket(index).mark_count.should eq(3)
    end

    read_grid = CrystalClick::StorageOccurrenceGrid.new(
      [2_u64, 3_u64, 2_u64],
      [0_u64, 2_u64, 0_u64],
      CrystalClick::BinaryCodecBudget.new(limits, true),
    )
    decoded = CrystalClick::ObjectDocumentCodec.decode_child_site_with_budget(
      {"id" => CrystalClick::BinaryDataType.primitive("UInt64")},
      streams,
      read_grid,
      CrystalClick::BinaryCodecBudget.new(limits),
    )
    decoded.map(&.size).should eq([0, 2, 0])
    w190sb_values([decoded[1]] of Array(CrystalClick::ObjectDocument)).should eq([
      [{20_u64, "middle-a", 200_i64}, {21_u64, "middle-b", 201_i64}],
    ])

    all_empty_grid = CrystalClick::StorageOccurrenceGrid.new(
      [2_u64, 2_u64],
      [0_u64, 0_u64],
      CrystalClick::BinaryCodecBudget.new(limits, true),
    )
    all_empty = [empty, empty] of Array(CrystalClick::ObjectDocument)
    empty_streams = CrystalClick::ObjectDocumentCodec.encode_child_site_with_budget(
      plan,
      all_empty,
      all_empty_grid,
      CrystalClick::BinaryCodecBudget.new(limits, true),
    )
    empty_decoded = CrystalClick::ObjectDocumentCodec.decode_child_site_with_budget(
      {"id" => CrystalClick::BinaryDataType.primitive("UInt64")},
      empty_streams,
      all_empty_grid,
      CrystalClick::BinaryCodecBudget.new(limits),
      first_mark: 2,
      mark_count: 0,
    )
    empty_decoded.should be_empty
    3.times do |index|
      empty_streams.shared_bucket(index).mark_count.should eq(2)
    end
  end

  it "charges aggregate fanout for bucket-derived rows and respects codec limits" do
    plan = w190sb_plan(256_u64)
    documents = [[w190sb_document(30_u64, "fanout", 300_i64)]] of Array(CrystalClick::ObjectDocument)
    ample_limits = w190sb_limits(max_nodes: 100_000, max_elements: 100_000)
    streams = CrystalClick::ObjectDocumentCodec.encode(plan, documents, limits: ample_limits)
    streams.shared_bucket_count.should eq(256)
    decoded = CrystalClick::ObjectDocumentCodec.decode(
      {"id" => CrystalClick::BinaryDataType.primitive("UInt64")},
      streams,
      limits: ample_limits,
    )
    w190sb_values(decoded).should eq([[{30_u64, "fanout", 300_i64}]])

    too_few_elements = w190sb_limits(max_elements: 128)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentCodec.encode(
        plan,
        documents,
        limits: too_few_elements,
      )
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectDocumentCodec.decode(
        {"id" => CrystalClick::BinaryDataType.primitive("UInt64")},
        streams,
        limits: too_few_elements,
      )
    end
  end
end
