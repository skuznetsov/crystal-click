require "./spec_helper"

# Test-only observation of the existing private facade. These wrappers must
# continue to see the public encode path after the binder has a new owner.
module CrystalClick::ObjectColumnLaneBinderProbe
  class_property enabled = false
  class_property events = [] of String
  class_property stat_budgets = [] of BinaryCodecBudget
  class_property codec_budgets = [] of BinaryCodecBudget
  class_property preflight_arguments = [] of Tuple(ObjectDocumentPhysicalPlan, ObjectDocumentPlan, ObjectDocumentStreams, BinaryCodecBudget)
  class_property bind_arguments = [] of Tuple(ObjectDocumentPhysicalPlan, ObjectDocumentPlan, ObjectDocumentStreams)
  class_property prefix_budget_deltas = [] of Tuple(Int64, Int64, Int64)
  class_property bound_lanes = [] of Array(ObjectDocumentColumnLane)

  def self.begin : Nil
    self.events = [] of String
    self.stat_budgets = [] of BinaryCodecBudget
    self.codec_budgets = [] of BinaryCodecBudget
    self.preflight_arguments = [] of Tuple(ObjectDocumentPhysicalPlan, ObjectDocumentPlan, ObjectDocumentStreams, BinaryCodecBudget)
    self.bind_arguments = [] of Tuple(ObjectDocumentPhysicalPlan, ObjectDocumentPlan, ObjectDocumentStreams)
    self.prefix_budget_deltas = [] of Tuple(Int64, Int64, Int64)
    self.bound_lanes = [] of Array(ObjectDocumentColumnLane)
    self.enabled = true
  end
end

module CrystalClick::ObjectDocumentStatistics
  def self.recompute_with_budget(
    plan : ObjectDocumentPlan,
    granules : Array(Array(ObjectDocument)),
    budget : BinaryCodecBudget,
  ) : ObjectDocumentPlan
    if ObjectColumnLaneBinderProbe.enabled
      ObjectColumnLaneBinderProbe.stat_budgets << budget
    end
    previous_def
  end
end

module CrystalClick::ObjectDocumentCodec
  def self.encode_with_budget(
    plan : ObjectDocumentPlan,
    granules : Array(Array(ObjectDocument)),
    budget : BinaryCodecBudget,
    mode : UInt64 = DEFAULT_MODE,
    profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
    shared_profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
  ) : ObjectDocumentStreams
    if ObjectColumnLaneBinderProbe.enabled
      ObjectColumnLaneBinderProbe.codec_budgets << budget
    end
    previous_def(plan, granules, budget, mode: mode, profile: profile, shared_profile: shared_profile)
  end
end

module CrystalClick::ObjectDocumentColumnWriter
  private def self.preflight_variant_prefixes!(
    physical_plan : ObjectDocumentPhysicalPlan,
    plan : ObjectDocumentPlan,
    streams : ObjectDocumentStreams,
    budget : BinaryCodecBudget,
  ) : Nil
    if ObjectColumnLaneBinderProbe.enabled
      ObjectColumnLaneBinderProbe.events << "preflight"
      ObjectColumnLaneBinderProbe.preflight_arguments << {physical_plan, plan, streams, budget}
    end
    before_bytes = budget.wire_byte_count
    before_elements = budget.element_count
    before_nodes = budget.node_count
    previous_def
    if ObjectColumnLaneBinderProbe.enabled
      ObjectColumnLaneBinderProbe.prefix_budget_deltas << {
        budget.wire_byte_count - before_bytes,
        budget.element_count - before_elements,
        budget.node_count - before_nodes,
      }
    end
    nil
  end

  private def self.bind_lanes(
    physical_plan : ObjectDocumentPhysicalPlan,
    plan : ObjectDocumentPlan,
    streams : ObjectDocumentStreams,
  ) : Array(ObjectDocumentColumnLane)
    if ObjectColumnLaneBinderProbe.enabled
      ObjectColumnLaneBinderProbe.events << "bind"
      ObjectColumnLaneBinderProbe.bind_arguments << {physical_plan, plan, streams}
    end
    lanes = previous_def
    if ObjectColumnLaneBinderProbe.enabled
      ObjectColumnLaneBinderProbe.bound_lanes << lanes
    end
    lanes
  end

  # Only the boundary test uses this bridge; production still enters preflight
  # through encode before the facade binds any lane.
  def self.lane_binder_test_preflight(
    physical_plan : ObjectDocumentPhysicalPlan,
    plan : ObjectDocumentPlan,
    streams : ObjectDocumentStreams,
    budget : BinaryCodecBudget,
  ) : Nil
    preflight_variant_prefixes!(physical_plan, plan, streams, budget)
  end
end

private def object_column_lane_binder_type : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.variant([
    CrystalClick::BinaryDataType.primitive("Bool"),
    CrystalClick::BinaryDataType.primitive("String"),
  ] of CrystalClick::BinaryDataType)
end

private def object_column_lane_binder_plan(type : CrystalClick::BinaryDataType) : CrystalClick::ObjectDocumentPlan
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new([] of String),
    {} of String => CrystalClick::DynamicStructure,
  )
  CrystalClick::ObjectDocumentPlan.new(structures, {"v" => type})
end

private def object_column_lane_binder_granules(
  type : CrystalClick::BinaryDataType,
) : Array(Array(CrystalClick::ObjectDocument))
  [
    [
      CrystalClick::ObjectDocument.new({"v" => CrystalClick::BinaryValue.variant(type, 0, CrystalClick::BinaryValue.bool(true))}),
      CrystalClick::ObjectDocument.new({"v" => CrystalClick::BinaryValue.variant(type, 1, CrystalClick::BinaryValue.string("a"))}),
    ],
    [
      CrystalClick::ObjectDocument.new({"v" => CrystalClick::BinaryValue.variant(type, 1, CrystalClick::BinaryValue.string("bc"))}),
      CrystalClick::ObjectDocument.new({"v" => CrystalClick::BinaryValue.variant(type, 0, CrystalClick::BinaryValue.bool(false))}),
    ],
  ]
end

private def with_object_column_lane_binder_part(&)
  parent = File.tempname("crystal-click-object-column-lane-binder-")
  Dir.mkdir(parent)
  begin
    yield parent
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def object_column_lane_binder_write_u64(io : IO, value : UInt64) : Nil
  8.times { |index| io.write_byte(((value >> (index * 8)) & 255_u64).to_u8) }
end

private def object_column_lane_binder_write_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 128_u64
    io.write_byte(((remaining & 127_u64) | 128_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def object_column_lane_binder_write_string(io : IO, value : String) : Nil
  object_column_lane_binder_write_varuint(io, value.bytesize.to_u64)
  io.write(value.to_slice)
end

# Literal-only LZ4 frame for the independent v4 size-checking sidecar.
private def object_column_lane_binder_frame(raw : Bytes) : Bytes
  raise "empty literal frame" if raw.empty?
  compressed = IO::Memory.new
  compressed.write_byte((Math.min(raw.size, 15) << 4).to_u8)
  if raw.size >= 15
    remaining = raw.size - 15
    while remaining >= 255
      compressed.write_byte(255_u8)
      remaining -= 255
    end
    compressed.write_byte(remaining.to_u8)
  end
  compressed.write(raw)

  payload = IO::Memory.new
  payload.write_byte(0x82_u8)
  payload.write_bytes((9 + compressed.size).to_u32, IO::ByteFormat::LittleEndian)
  payload.write_bytes(raw.size.to_u32, IO::ByteFormat::LittleEndian)
  payload.write(compressed.to_slice)
  hash = CrystalClick::CityHashV1.hash128(payload.to_slice)
  framed = IO::Memory.new
  object_column_lane_binder_write_u64(framed, hash[0])
  object_column_lane_binder_write_u64(framed, hash[1])
  framed.write(payload.to_slice)
  framed.to_slice
end

private def object_column_lane_binder_ensure_checksums(part : String) : Nil
  return if File.exists?(File.join(part, "checksums.txt"))

  physical = Hash(String, Bytes).new
  Dir.children(part).each do |name|
    next if name == "checksums.txt"
    physical[name] = File.read(File.join(part, name)).to_slice
  end
  raise "Object writer fixture emitted no physical files" if physical.empty?

  payload = IO::Memory.new
  object_column_lane_binder_write_varuint(payload, physical.size.to_u64)
  physical.keys.sort.each do |name|
    bytes = physical[name]
    object_column_lane_binder_write_string(payload, name)
    object_column_lane_binder_write_varuint(payload, bytes.size.to_u64)
    payload.write(Bytes.new(16, 0_u8))
    payload.write_byte(0_u8)
  end
  File.open(File.join(part, "checksums.txt"), "wb") do |io|
    io << "checksums format version: 4\n"
    io.write(object_column_lane_binder_frame(payload.to_slice))
  end
  nil
end

private def object_column_lane_binder_assert_rows(
  actual : Array(Array(CrystalClick::ObjectDocument)),
  expected_indexes : Array(Array(UInt8)),
  expected_texts : Array(Array(String?)),
  expected_bools : Array(Array(Bool?)),
) : Nil
  actual.size.should eq(expected_indexes.size)
  actual.each_with_index do |mark, mark_index|
    mark.size.should eq(expected_indexes[mark_index].size)
    mark.each_with_index do |document, row_index|
      value = document.value_for("v")
      value.variant_index?.should eq(expected_indexes[mark_index][row_index])
      child = value.variant_child?.not_nil!
      if text = expected_texts[mark_index][row_index]
        child.as_string.should eq(text)
      else
        child.as_bool.should eq(expected_bools[mark_index][row_index].not_nil!)
      end
    end
  end
end

private def object_column_lane_binder_mark_triples(marks : Bytes) : Array(Tuple(UInt64, UInt64, UInt64))
  raise "misaligned Variant mark grid" unless marks.size % 24 == 0
  Array(Tuple(UInt64, UInt64, UInt64)).new(marks.size // 24) do |record|
    words = StaticArray(UInt64, 3).new(0_u64)
    3.times do |word|
      8.times do |byte|
        words[word] |= marks[record * 24 + word * 8 + byte].to_u64 << (8 * byte)
      end
    end
    {words[0], words[1], words[2]}
  end
end

describe "Object column lane binder extraction characterization" do
  it "keeps the real facade order, object identities, shared budget, and public files" do
    type = object_column_lane_binder_type
    plan = object_column_lane_binder_plan(type)
    schema = {"v" => type}
    granules = object_column_lane_binder_granules(type)
    CrystalClick::ObjectColumnLaneBinderProbe.begin
    files = begin
      CrystalClick::ObjectDocumentColumnWriter.encode("payload", plan, granules)
    ensure
      CrystalClick::ObjectColumnLaneBinderProbe.enabled = false
    end

    expected_streams = [
      "payload.object_structure",
      "payload.object_shared_data.size0",
      "payload.object_shared_data%2Epaths",
      "payload.object_shared_data%2Evalues",
      "payload.v.variant_discr",
      "payload.v.Bool",
      "payload.v.String",
    ].sort
    files.stream_names.should eq(expected_streams)
    files.file_names.should eq(expected_streams.flat_map { |name| [name + ".bin", name + ".mrk2"] }.sort)

    discriminator = files.pair_for("payload.v.variant_discr")
    with_object_column_lane_binder_part do |part|
      files.file_names.each do |name|
        File.write(File.join(part, name), files.file_bytes(name))
      end
      object_column_lane_binder_ensure_checksums(part)

      CrystalClick::ObjectColumnLaneBinderProbe.events.should eq(["preflight", "bind"])
      CrystalClick::ObjectColumnLaneBinderProbe.stat_budgets.size.should eq(1)
      CrystalClick::ObjectColumnLaneBinderProbe.codec_budgets.size.should eq(1)
      CrystalClick::ObjectColumnLaneBinderProbe.preflight_arguments.size.should eq(1)
      CrystalClick::ObjectColumnLaneBinderProbe.bind_arguments.size.should eq(1)
      CrystalClick::ObjectColumnLaneBinderProbe.bound_lanes.size.should eq(1)

      physical, fresh, streams, budget = CrystalClick::ObjectColumnLaneBinderProbe.preflight_arguments[0]
      bind_physical, bind_plan, bind_streams = CrystalClick::ObjectColumnLaneBinderProbe.bind_arguments[0]
      physical.same?(bind_physical).should be_true
      fresh.same?(bind_plan).should be_true
      streams.same?(bind_streams).should be_true
      fresh.same?(files.plan).should be_true
      CrystalClick::ObjectColumnLaneBinderProbe.stat_budgets[0].same?(budget).should be_true
      CrystalClick::ObjectColumnLaneBinderProbe.codec_budgets[0].same?(budget).should be_true
      CrystalClick::ObjectColumnLaneBinderProbe.prefix_budget_deltas.should eq([{8_i64, 3_i64, 0_i64}])
      CrystalClick::ObjectColumnLaneBinderProbe.bound_lanes[0].map(&.name).sort.should eq(files.stream_names)

      data_name = "payload.v.variant_discr.bin"
      marks_name = "payload.v.variant_discr.mrk2"
      data = File.read(File.join(part, data_name)).to_slice
      marks = File.read(File.join(part, marks_name)).to_slice
      data.should eq(discriminator.data)
      marks.should eq(discriminator.marks)
      grid = CrystalClick::CompressedMarkReader.inspect(
        File.join(part, data_name),
        File.join(part, marks_name),
        data.size.to_i64,
        marks.size.to_i64,
        prefix_size: 8,
      )
      grid.mark_count.should eq(2)
      grid.rows_per_mark.should eq([2_u64, 2_u64])
      grid.positions.should eq([8_i64, 10_i64, 12_i64])
      CrystalClick::CompressedBlock.decode_all(data).should eq(
        Bytes[0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0]
      )
      object_column_lane_binder_mark_triples(marks).should eq([
        {0_u64, 8_u64, 2_u64},
        {0_u64, 10_u64, 2_u64},
        {data.size.to_u64, 0_u64, 0_u64},
      ])

      object_column_lane_binder_assert_rows(
        CrystalClick::ObjectDocumentFileReader.read(part, "payload", schema),
        [[0_u8, 1_u8], [1_u8, 0_u8]],
        [[nil, "a"], ["bc", nil]],
        [[true, nil], [nil, false]],
      )
      object_column_lane_binder_assert_rows(
        CrystalClick::ObjectDocumentFileReader.read(
          part, "payload", schema, first_mark: 1, mark_count: 1
        ),
        [[1_u8, 0_u8]],
        [["bc", nil]],
        [[nil, false]],
      )
    end
  end

  it "admits exactly the discriminator header and K+1 coordinate-copy budget before binding" do
    type = object_column_lane_binder_type
    original = object_column_lane_binder_plan(type)
    granules = object_column_lane_binder_granules(type)
    fresh = CrystalClick::ObjectDocumentStatistics.recompute(original, granules)
    streams = CrystalClick::ObjectDocumentCodec.encode(fresh, granules)
    physical = CrystalClick::ObjectDocumentPhysicalPlan.new("payload", fresh)

    exact_limits = CrystalClick::BinaryCodecLimits.new(max_depth: 64, max_nodes: 8, max_elements: 8, max_bytes: 17)
    exact = CrystalClick::BinaryCodecBudget.new(exact_limits, true)
    exact.charge_node
    exact.charge_elements(5_u64)
    exact.charge_wire_bytes(9_u64)
    CrystalClick::ObjectDocumentColumnWriter.lane_binder_test_preflight(physical, fresh, streams, exact)
    exact.node_count.should eq(1_i64)
    exact.element_count.should eq(8_i64)
    exact.wire_byte_count.should eq(17_i64)

    byte_short = CrystalClick::BinaryCodecBudget.new(
      CrystalClick::BinaryCodecLimits.new(max_depth: 64, max_nodes: 8, max_elements: 8, max_bytes: 16), true
    )
    byte_short.charge_elements(5_u64)
    byte_short.charge_wire_bytes(9_u64)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentColumnWriter.lane_binder_test_preflight(physical, fresh, streams, byte_short)
    end
    {byte_short.element_count, byte_short.wire_byte_count}.should eq({5_i64, 9_i64})

    coordinate_short = CrystalClick::BinaryCodecBudget.new(
      CrystalClick::BinaryCodecLimits.new(max_depth: 64, max_nodes: 8, max_elements: 7, max_bytes: 17), true
    )
    coordinate_short.charge_elements(5_u64)
    coordinate_short.charge_wire_bytes(9_u64)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentColumnWriter.lane_binder_test_preflight(physical, fresh, streams, coordinate_short)
    end
    {coordinate_short.element_count, coordinate_short.wire_byte_count}.should eq({5_i64, 9_i64})
  end

  it "requires an explicit site roster for a declared recursive Dynamic field" do
    array_dynamic = CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.dynamic)
    schema = CrystalClick::ObjectDocumentSchema.new({"v" => array_dynamic})
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    )

    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentPlan.new(structures, schema.typed_paths)
    end

    roster = CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)
    plan = CrystalClick::ObjectDocumentPlan.new(
      structures,
      schema.typed_paths,
      typed_dynamic_sites: {"v" => {"root.elements" => roster}},
    )
    physical = CrystalClick::ObjectDocumentPhysicalPlan.new("payload", plan)
    physical.typed_dynamic("v").structure_name_for("root.elements").should end_with(".dynamic_structure")
  end
end
