require "./spec_helper"

module W159TypedDynamicPlanDecodeProbe
  class_property enabled = false
  class_property site_counts = [] of Int32

  def self.begin : Nil
    self.site_counts = [] of Int32
    self.enabled = true
  end

  def self.finish : Nil
    self.enabled = false
  end
end

class CrystalClick::BinaryDynamicBulkPlan
  def self.decode_structure_streams(
    type : BinaryDataType,
    streams : BinaryDynamicStructureStreams,
    budget : BinaryCodecBudget,
    profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
  ) : BinaryDynamicBulkPlan
    W159TypedDynamicPlanDecodeProbe.site_counts << streams.site_count if W159TypedDynamicPlanDecodeProbe.enabled
    previous_def(type, streams, budget, profile)
  end
end

private def w159a_pair_fixture : Tuple(String, CrystalClick::ObjectDocumentSchema, CrystalClick::ObjectDocumentPlan)
  dynamic = CrystalClick::BinaryDataType.dynamic(1)
  pair_type = CrystalClick::BinaryDataType.tuple(
    [dynamic, dynamic] of CrystalClick::BinaryDataType,
    ["left", "right"] of String,
  )
  schema = CrystalClick::ObjectDocumentSchema.new({"pair" => pair_type})
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new([] of String),
    {} of String => CrystalClick::DynamicStructure,
  )
  sites = {
    "pair" => {
      "root.field.0" => CrystalClick::DynamicStructure.new([
        CrystalClick::BinaryDataType.primitive("UInt64"),
      ] of CrystalClick::BinaryDataType),
      "root.field.1" => CrystalClick::DynamicStructure.new([
        CrystalClick::BinaryDataType.primitive("String"),
      ] of CrystalClick::BinaryDataType),
    },
  }
  plan = CrystalClick::ObjectDocumentPlan.new(
    structures,
    schema.typed_paths,
    typed_dynamic_sites: sites,
  )

  parent = File.tempname("crystal-click-w159-recursive-dynamic-adversary-")
  Dir.mkdir(parent)
  part = File.join(parent, "all_1_1_0")
  rows = Array(Array(CrystalClick::ObjectDocument)).new
  keys = [] of UInt64
  3.times do |index|
    value = (index + 1).to_u64 * 10_u64
    rows << [CrystalClick::ObjectDocument.new({
      "pair" => CrystalClick::BinaryValue.tuple(pair_type, [
        CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.uint64(value)),
        CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.string("r#{index}")),
      ] of CrystalClick::BinaryValue),
    })] of CrystalClick::ObjectDocument
    keys << value
  end
  CrystalClick::WidePartWriter.write_uint64_object_pair(
    part,
    "pk",
    Slice(UInt64).new(keys.size) { |index| keys[index] },
    "payload",
    schema,
    plan,
    rows,
    rows_per_mark: 1,
    mode: 0_u64,
    frame_bytes: 64,
  )
  {parent, schema, plan}
end

private def w159a_with_pair_fixture(&)
  parent, schema, plan = w159a_pair_fixture
  begin
    yield File.join(parent, "all_1_1_0"), schema, plan
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w159a_pair_literals(rows : Array(Array(CrystalClick::ObjectDocument))) : Array(Array(Tuple(UInt64, String)))
  rows.map do |mark|
    mark.map do |document|
      pair = document.value_for("pair")
      pair.type.tag.should eq(CrystalClick::BinaryDataType::TAG_NAMED_TUPLE)
      left = pair.child_at(0)
      right = pair.child_at(1)
      left.type.tag.should eq(CrystalClick::BinaryDataType::TAG_DYNAMIC)
      right.type.tag.should eq(CrystalClick::BinaryDataType::TAG_DYNAMIC)
      {left.child_at(0).as_uint64, right.child_at(0).as_string}
    end
  end
end

private def w159a_read_counted(
  part : String,
  schema : CrystalClick::ObjectDocumentSchema,
  first_mark : Int,
  mark_count : Int,
) : Array(Array(CrystalClick::ObjectDocument))
  W159TypedDynamicPlanDecodeProbe.begin
  rows = begin
    CrystalClick::ObjectDocumentFileReader.read(
      part,
      "payload",
      schema.typed_paths,
      first_mark: first_mark,
      mark_count: mark_count,
      hashed: true,
    )
  ensure
    W159TypedDynamicPlanDecodeProbe.finish
  end
  # A single typed composite child owns two Dynamic sites. The metadata parse
  # is once per child and returns the complete two-site plan, independent of
  # the selected value window.
  W159TypedDynamicPlanDecodeProbe.site_counts.should eq([2])
  rows
end

private def w159a_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times do |index|
    bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8
  end
end

private def w159a_write_u64_file(path : String, offset : Int, value : UInt64) : Nil
  bytes = Bytes.new(8)
  w159a_write_u64(bytes, 0, value)
  File.open(path, "r+b") do |io|
    io.seek(offset)
    io.write(bytes)
  end
end

private def w159a_corrupt_frame_raw_byte(path : String, raw_offset : Int, value : UInt8) : Nil
  File.size(path).should be < 8 * 1024 * 1024
  frame = File.read(path).to_slice.dup
  CrystalClick::CompressedBlock::METHOD_LZ4.should eq(frame[16])
  compressed_size = frame[17].to_u32 |
                    (frame[18].to_u32 << 8) |
                    (frame[19].to_u32 << 16) |
                    (frame[20].to_u32 << 24)
  raw_size = frame[21].to_u32 |
             (frame[22].to_u32 << 8) |
             (frame[23].to_u32 << 16) |
             (frame[24].to_u32 << 24)
  raw_offset.should be < raw_size
  compressed_size.to_i.should eq(frame.size - CrystalClick::CompressedBlock::CHECKSUM_SIZE)

  cursor = CrystalClick::CompressedBlock::FRAME_HEADER_SIZE
  token = frame[cursor]
  literal_count = (token >> 4).to_i
  cursor += 1
  if literal_count == 15
    loop do
      extension = frame[cursor]
      cursor += 1
      literal_count += extension.to_i
      break if extension < 255
    end
  end
  literal_count.should eq(raw_size)
  frame[cursor + raw_offset] = value

  checksum = CrystalClick::CityHashV1.hash128(
    frame[CrystalClick::CompressedBlock::CHECKSUM_SIZE, compressed_size.to_i]
  )
  w159a_write_u64(frame, 0, checksum[0])
  w159a_write_u64(frame, 8, checksum[1])
  File.write(path, frame)
end

private def w159a_mutate_lane(part : String, logical_name : String, raw_offset : Int, value : UInt8) : Nil
  path = File.join(part, CrystalClick::StreamName.hash(logical_name) + ".bin")
  w159a_corrupt_frame_raw_byte(path, raw_offset, value)
end

private def w159a_budget_counts(budget : CrystalClick::BinaryCodecBudget) : Tuple(Int64, Int64, Int64)
  {budget.node_count, budget.element_count, budget.wire_byte_count}
end

private def w159a_limits(nodes : Int, elements : Int, bytes : Int, depth : Int = 64) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: depth,
    max_nodes: nodes,
    max_elements: elements,
    max_bytes: bytes,
  )
end

private def w159a_nested_array_case(
  arm : CrystalClick::BinaryDataType?,
  depth : Int,
) : CrystalClick::ObjectDocumentStreams
  dynamic = CrystalClick::BinaryDataType.dynamic(1)
  outer = CrystalClick::BinaryDataType.array(dynamic)
  nested = CrystalClick::BinaryDataType.array(
    CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.primitive("UInt64"))
  )
  roster = arm ? CrystalClick::DynamicStructure.new([arm] of CrystalClick::BinaryDataType) : CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new([] of String),
    {} of String => CrystalClick::DynamicStructure,
  )
  schema = CrystalClick::ObjectDocumentSchema.new({"value" => outer})
  plan = CrystalClick::ObjectDocumentPlan.new(
    structures,
    schema.typed_paths,
    typed_dynamic_sites: {"value" => {"root.elements" => roster}},
  )
  nested_value = CrystalClick::BinaryValue.array(nested, [
    CrystalClick::BinaryValue.array(nested.child_at(0), [CrystalClick::BinaryValue.uint64(1_u64)] of CrystalClick::BinaryValue),
  ] of CrystalClick::BinaryValue)
  value = CrystalClick::BinaryValue.array(outer, [
    CrystalClick::BinaryValue.dynamic(dynamic, nested_value),
  ] of CrystalClick::BinaryValue)
  rows = [[CrystalClick::ObjectDocument.new({"value" => value})] of CrystalClick::ObjectDocument]
  CrystalClick::ObjectDocumentCodec.encode(
    plan,
    rows,
    mode: 0_u64,
    limits: w159a_limits(4_096, 1_000_000, 64 * 1024 * 1024, depth),
  )
end

private def w159a_rebuild_streams_with_typed_dynamic(
  source : CrystalClick::ObjectDocumentStreams,
  field : String,
  replacement : CrystalClick::BinaryDynamicBulkStreams,
) : CrystalClick::ObjectDocumentStreams
  typed = Hash(String, CrystalClick::BinaryBulkStreams).new
  source.typed_path_count.times do |index|
    path = source.typed_path_at(index)
    typed[path] = source.typed_for(path)
  end
  dynamics = Hash(String, CrystalClick::DynamicValueStreams).new
  source.dynamic_path_count.times do |index|
    path = source.dynamic_path_at(index)
    dynamics[path] = source.dynamic_for(path)
  end
  typed_dynamic = Hash(String, CrystalClick::BinaryDynamicBulkStreams).new
  source.typed_dynamic_path_count.times do |index|
    path = source.typed_dynamic_path_at(index)
    typed_dynamic[path] = source.typed_dynamic_for(path)
  end
  typed_dynamic[field] = replacement
  CrystalClick::ObjectDocumentStreams.new(
    source.structures,
    source.rows_per_mark,
    typed,
    dynamics,
    source.shared,
    typed_dynamic,
  )
end

private def w159a_replace_site_blobs(
  source : CrystalClick::ObjectDocumentStreams,
  field : String,
  blobs : Hash(String, Bytes),
) : CrystalClick::ObjectDocumentStreams
  data = source.typed_dynamic_for(field).data
  replacement = CrystalClick::BinaryDynamicBulkStreams.new(
    CrystalClick::BinaryDynamicStructureStreams.new(blobs),
    data,
  )
  w159a_rebuild_streams_with_typed_dynamic(source, field, replacement)
end

private def w159a_pair_streams : Tuple(
  CrystalClick::ObjectDocumentSchema,
  CrystalClick::ObjectDocumentStreams,
)
  dynamic = CrystalClick::BinaryDataType.dynamic(1)
  pair = CrystalClick::BinaryDataType.tuple(
    [dynamic, dynamic] of CrystalClick::BinaryDataType,
    ["left", "right"] of String,
  )
  schema = CrystalClick::ObjectDocumentSchema.new({"pair" => pair})
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new([] of String),
    {} of String => CrystalClick::DynamicStructure,
  )
  plan = CrystalClick::ObjectDocumentPlan.new(
    structures,
    schema.typed_paths,
    typed_dynamic_sites: {"pair" => {
      "root.field.0" => CrystalClick::DynamicStructure.new([
        CrystalClick::BinaryDataType.primitive("UInt64"),
      ] of CrystalClick::BinaryDataType),
      "root.field.1" => CrystalClick::DynamicStructure.new([
        CrystalClick::BinaryDataType.primitive("String"),
      ] of CrystalClick::BinaryDataType),
    }},
  )
  documents = [
    [CrystalClick::ObjectDocument.new({
      "pair" => CrystalClick::BinaryValue.tuple(pair, [
        CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.uint64(10_u64)),
        CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.string("x")),
      ] of CrystalClick::BinaryValue),
    })] of CrystalClick::ObjectDocument,
    [CrystalClick::ObjectDocument.new({
      "pair" => CrystalClick::BinaryValue.tuple(pair, [
        CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.uint64(20_u64)),
        CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.string("y")),
      ] of CrystalClick::BinaryValue),
    })] of CrystalClick::ObjectDocument,
    [CrystalClick::ObjectDocument.new({
      "pair" => CrystalClick::BinaryValue.tuple(pair, [
        CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.uint64(30_u64)),
        CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.string("z")),
      ] of CrystalClick::BinaryValue),
    })] of CrystalClick::ObjectDocument,
  ] of Array(CrystalClick::ObjectDocument)
  {schema, CrystalClick::ObjectDocumentCodec.encode(plan, documents, mode: 0_u64)}
end

private def w159a_expect_corrupt_windows(
  schema : CrystalClick::ObjectDocumentSchema,
  streams : CrystalClick::ObjectDocumentStreams,
) : Nil
  [{0, 3}, {1, 1}, {3, 0}].each do |first_mark, mark_count|
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectDocumentCodec.decode(
        schema.typed_paths,
        streams,
        first_mark: first_mark,
        mark_count: mark_count,
      )
    end
  end
end

describe "W159 recursive declared Dynamic adversaries" do
  it "requires exact site keys and caps without using a root-only roster" do
    dynamic = CrystalClick::BinaryDataType.dynamic(1)
    pair = CrystalClick::BinaryDataType.tuple(
      [dynamic, dynamic] of CrystalClick::BinaryDataType,
      ["left", "right"] of String,
    )
    typed = {"pair" => pair}
    empty = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    )
    u64 = CrystalClick::BinaryDataType.primitive("UInt64")
    text = CrystalClick::BinaryDataType.primitive("String")
    left = CrystalClick::DynamicStructure.new([u64] of CrystalClick::BinaryDataType)
    right = CrystalClick::DynamicStructure.new([text] of CrystalClick::BinaryDataType)
    exact = {"pair" => {"root.field.0" => left, "root.field.1" => right}}

    plan = CrystalClick::ObjectDocumentPlan.new(empty, typed, typed_dynamic_sites: exact)
    plan.typed_dynamic_site_count_for("pair").should eq(2)
    plan.typed_dynamic_site_path_at("pair", 0).should eq("root.field.0")
    plan.typed_dynamic_site_path_at("pair", 1).should eq("root.field.1")
    plan.typed_dynamic_site_type_for("pair", "root.field.0").should eq(dynamic)
    detached = plan.typed_dynamic_sites_for("pair")
    detached.clear
    plan.typed_dynamic_site_count_for("pair").should eq(2)

    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentPlan.new(empty, typed, typed_dynamic_sites: {
        "pair" => {"root.field.0" => left},
      })
    end
    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentPlan.new(empty, typed, typed_dynamic_sites: {
        "pair" => {"root.field.0" => left, "root.field.1" => right, "root.field.2" => left},
      })
    end
    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentPlan.new(empty, typed, typed_dynamic_sites: {
        "pair" => {"root.field.0" => CrystalClick::DynamicStructure.new([u64, text]), "root.field.1" => right},
      })
    end
    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentPlan.new(
        empty,
        typed,
        {"pair" => left},
        typed_dynamic_sites: exact,
      )
    end
  end

  it "retains full descriptor depth for an actual roster arm under Array(Dynamic)" do
    dynamic = CrystalClick::BinaryDataType.dynamic(1)
    nested = CrystalClick::BinaryDataType.array(
      CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.primitive("UInt64"))
    )
    actual_depth_five = w159a_limits(4_096, 1_000_000, 64 * 1024 * 1024, 5)
    actual_depth_six = w159a_limits(4_096, 1_000_000, 64 * 1024 * 1024, 6)
    CrystalClick::ObjectRecursiveDeclaration.measure_descriptor(dynamic, actual_depth_five, 3).should_not be_nil
    CrystalClick::ObjectRecursiveDeclaration.measure_descriptor(nested, actual_depth_six, 4).not_nil!.max_depth.should eq(6)

    # Isolate roster preparation from selected-value validation: either guard
    # must retain the Object depth even when no rows will be encoded.
    wrapper = CrystalClick::BinaryDataType.array(dynamic)
    roster = {"root.elements" => CrystalClick::DynamicStructure.new([nested] of CrystalClick::BinaryDataType)}
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDeclaredDynamicDeclaration.prepare_write_sites_plan(
        wrapper, roster, CrystalClick::BinaryCodecBudget.new(actual_depth_five, true),
        CrystalClick::BinaryBulkProfile.single_stream,
      )
    end
    CrystalClick::ObjectDeclaredDynamicDeclaration.prepare_write_sites_plan(
      wrapper, roster, CrystalClick::BinaryCodecBudget.new(actual_depth_six, true),
      CrystalClick::BinaryBulkProfile.single_stream,
    ).site_count.should eq(1)

    expect_raises(CrystalClick::UnsupportedFormatError) do
      w159a_nested_array_case(nested, 5)
    end
    streams = w159a_nested_array_case(nested, 6)
    streams.typed_dynamic_path_count.should eq(1)
  end

  it "retains full descriptor depth for a selected SharedVariant spill under Array(Dynamic)" do
    actual_depth_five = w159a_limits(4_096, 1_000_000, 64 * 1024 * 1024, 5)
    actual_depth_six = w159a_limits(4_096, 1_000_000, 64 * 1024 * 1024, 6)
    # Confirm the nominal wrapper fits at depth five while the actual nested
    # type is measured from the true site depth, not from dotted path segments.
    dynamic = CrystalClick::BinaryDataType.dynamic(1)
    wrapper = CrystalClick::BinaryDataType.array(dynamic)
    CrystalClick::ObjectRecursiveDeclaration.measure_descriptor(wrapper, actual_depth_five, 2).should_not be_nil

    expect_raises(CrystalClick::UnsupportedFormatError) do
      w159a_nested_array_case(nil, 5)
    end
    streams = w159a_nested_array_case(nil, 6)
    streams.typed_dynamic_path_count.should eq(1)
  end

  it "records the statistics offset for each exact site and drops stale supplied statistics" do
    dynamic = CrystalClick::BinaryDataType.dynamic(1)
    pair = CrystalClick::BinaryDataType.tuple(
      [dynamic, dynamic] of CrystalClick::BinaryDataType,
      ["left", "right"] of String,
    )
    stale = CrystalClick::StructureStatistics.new(
      [999_u64, 888_u64],
      [CrystalClick::StructureStatistic.new("stale", 123_u64)],
    )
    left = CrystalClick::DynamicStructure.new(
      [CrystalClick::BinaryDataType.primitive("UInt64")] of CrystalClick::BinaryDataType,
      stale,
    )
    right = CrystalClick::DynamicStructure.new(
      [CrystalClick::BinaryDataType.primitive("String")] of CrystalClick::BinaryDataType,
    )
    schema = CrystalClick::ObjectDocumentSchema.new({"pair" => pair})
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    )
    plan = CrystalClick::ObjectDocumentPlan.new(
      structures,
      schema.typed_paths,
      typed_dynamic_sites: {"pair" => {"root.field.0" => left, "root.field.1" => right}},
    )
    documents = [[CrystalClick::ObjectDocument.new({
      "pair" => CrystalClick::BinaryValue.tuple(pair, [
        CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.uint64(10_u64)),
        CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.string("x")),
      ] of CrystalClick::BinaryValue),
    })] of CrystalClick::ObjectDocument]

    streams = CrystalClick::ObjectDocumentCodec.encode(plan, documents, mode: 0_u64)
    left_bytes = streams.typed_dynamic_for("pair").structures.structure_bytes_for("root.field.0")
    left_bytes.should eq(Bytes[0x04_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 1_u8, 0x04_u8, 0_u8])
    streams.typed_dynamic_site_statistics_offset("pair", "root.field.0").not_nil!.should eq(10)
    CrystalClick::DynamicStructureCodec.decode(left_bytes).statistics.should be_nil
    stale.count_at(0).should eq(999_u64)
    streams.typed_dynamic_site_statistics_offset("pair", "root.field.1").not_nil!.should be >= 0
  end

  it "enforces exact aggregate budget dimensions and read/write direction for two sites" do
    dynamic = CrystalClick::BinaryDataType.dynamic(1)
    pair = CrystalClick::BinaryDataType.tuple(
      [dynamic, dynamic] of CrystalClick::BinaryDataType,
      ["left", "right"] of String,
    )
    schema = CrystalClick::ObjectDocumentSchema.new({"pair" => pair})
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    )
    plan = CrystalClick::ObjectDocumentPlan.new(
      structures,
      schema.typed_paths,
      typed_dynamic_sites: {"pair" => {
        "root.field.0" => CrystalClick::DynamicStructure.new([
          CrystalClick::BinaryDataType.primitive("UInt64"),
        ] of CrystalClick::BinaryDataType),
        "root.field.1" => CrystalClick::DynamicStructure.new([
          CrystalClick::BinaryDataType.primitive("String"),
        ] of CrystalClick::BinaryDataType),
      }},
    )
    documents = [[CrystalClick::ObjectDocument.new({
      "pair" => CrystalClick::BinaryValue.tuple(pair, [
        CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.uint64(10_u64)),
        CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.string("r0")),
      ] of CrystalClick::BinaryValue),
    })] of CrystalClick::ObjectDocument]

    write_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true)
    streams = CrystalClick::ObjectDocumentCodec.encode_with_budget(plan, documents, write_budget, mode: 0_u64)
    write_counts = w159a_budget_counts(write_budget)
    write_counts.each { |count| count.should be > 0_i64 }
    exact_write = CrystalClick::BinaryCodecBudget.new(
      w159a_limits(write_counts[0].to_i, write_counts[1].to_i, write_counts[2].to_i), true
    )
    CrystalClick::ObjectDocumentCodec.encode_with_budget(plan, documents, exact_write, mode: 0_u64)
    w159a_budget_counts(exact_write).should eq(write_counts)

    [
      {write_counts[0].to_i - 1, write_counts[1].to_i, write_counts[2].to_i},
      {write_counts[0].to_i, write_counts[1].to_i - 1, write_counts[2].to_i},
      {write_counts[0].to_i, write_counts[1].to_i, write_counts[2].to_i - 1},
    ].each do |short|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        budget = CrystalClick::BinaryCodecBudget.new(w159a_limits(short[0], short[1], short[2]), true)
        CrystalClick::ObjectDocumentCodec.encode_with_budget(plan, documents, budget, mode: 0_u64)
      end
    end

    read_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
    CrystalClick::ObjectDocumentCodec.decode_with_budget(schema.typed_paths, streams, read_budget)
    read_counts = w159a_budget_counts(read_budget)
    exact_read = CrystalClick::BinaryCodecBudget.new(
      w159a_limits(read_counts[0].to_i, read_counts[1].to_i, read_counts[2].to_i)
    )
    CrystalClick::ObjectDocumentCodec.decode_with_budget(schema.typed_paths, streams, exact_read)
    w159a_budget_counts(exact_read).should eq(read_counts)
    [
      {read_counts[0].to_i - 1, read_counts[1].to_i, read_counts[2].to_i},
      {read_counts[0].to_i, read_counts[1].to_i - 1, read_counts[2].to_i},
      {read_counts[0].to_i, read_counts[1].to_i, read_counts[2].to_i - 1},
    ].each do |short|
      expect_raises(CrystalClick::CorruptPartError) do
        budget = CrystalClick::BinaryCodecBudget.new(w159a_limits(short[0], short[1], short[2]))
        CrystalClick::ObjectDocumentCodec.decode_with_budget(schema.typed_paths, streams, budget)
      end
    end

    wrong_read_direction = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentCodec.encode_with_budget(plan, documents, wrong_read_direction, mode: 0_u64)
    end
    w159a_budget_counts(wrong_read_direction).should eq({0_i64, 0_i64, 0_i64})
    wrong_write_direction = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true)
    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentCodec.decode_with_budget(schema.typed_paths, streams, wrong_write_direction)
    end
    w159a_budget_counts(wrong_write_direction).should eq({0_i64, 0_i64, 0_i64})
  end

  it "rejects Object-forbidden actual arms and SharedVariant spills at recursive sites" do
    dynamic = CrystalClick::BinaryDataType.dynamic(1)
    outer = CrystalClick::BinaryDataType.array(dynamic)
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    variant = CrystalClick::BinaryDataType.variant([
      uint64,
      CrystalClick::BinaryDataType.primitive("String"),
    ] of CrystalClick::BinaryDataType)
    low_cardinality = CrystalClick::BinaryDataType.low_cardinality(
      CrystalClick::BinaryDataType.primitive("String")
    )
    forbidden = [
      CrystalClick::BinaryDataType.array(dynamic),
      CrystalClick::BinaryDataType.array(variant),
      CrystalClick::BinaryDataType.array(low_cardinality),
    ] of CrystalClick::BinaryDataType
    empty = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    )
    schema = CrystalClick::ObjectDocumentSchema.new({"value" => outer})

    forbidden.each do |actual_type|
      error = expect_raises(ArgumentError) do
        CrystalClick::ObjectDocumentPlan.new(
          empty,
          schema.typed_paths,
          typed_dynamic_sites: {"value" => {"root.elements" => CrystalClick::DynamicStructure.new([actual_type])}},
        )
      end
      error.message.not_nil!.should contain("actual arms exclude")

      empty_roster = CrystalClick::ObjectDocumentPlan.new(
        empty,
        schema.typed_paths,
        typed_dynamic_sites: {"value" => {"root.elements" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)}},
      )
      forbidden_value = CrystalClick::BinaryValue.array(actual_type, [] of CrystalClick::BinaryValue)
      value = CrystalClick::BinaryValue.array(outer, [
        CrystalClick::BinaryValue.dynamic(dynamic, forbidden_value),
      ] of CrystalClick::BinaryValue)
      rows = [[CrystalClick::ObjectDocument.new({"value" => value})] of CrystalClick::ObjectDocument]
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentCodec.encode(empty_roster, rows, mode: 0_u64)
      end
    end

    spill_dynamic = CrystalClick::BinaryDataType.dynamic(0)
    spill_outer = CrystalClick::BinaryDataType.array(spill_dynamic)
    spill_schema = CrystalClick::ObjectDocumentSchema.new({"value" => spill_outer})
    spill_plan = CrystalClick::ObjectDocumentPlan.new(
      empty,
      spill_schema.typed_paths,
      typed_dynamic_sites: {"value" => {"root.elements" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)}},
    )
    forbidden.each do |actual_type|
      forbidden_value = CrystalClick::BinaryValue.array(actual_type, [] of CrystalClick::BinaryValue)
      value = CrystalClick::BinaryValue.array(spill_outer, [
        CrystalClick::BinaryValue.dynamic(spill_dynamic, forbidden_value),
      ] of CrystalClick::BinaryValue)
      rows = [[CrystalClick::ObjectDocument.new({"value" => value})] of CrystalClick::ObjectDocument]
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentCodec.encode(spill_plan, rows, mode: 0_u64)
      end
    end
  end

  it "proves a generic-admitted recursive spill is rejected by Object decode" do
    dynamic = CrystalClick::BinaryDataType.dynamic(0)
    map_type = CrystalClick::BinaryDataType.map(
      CrystalClick::BinaryDataType.primitive("String"), dynamic
    )
    empty = CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)
    schema = CrystalClick::ObjectDocumentSchema.new({"value" => map_type})
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    )
    plan = CrystalClick::ObjectDocumentPlan.new(
      structures,
      schema.typed_paths,
      typed_dynamic_sites: {"value" => {"root.elements.field.1" => empty}},
    )
    valid_value = CrystalClick::BinaryValue.map(map_type, [] of CrystalClick::BinaryValue)
    valid_streams = CrystalClick::ObjectDocumentCodec.encode(plan, [[
      CrystalClick::ObjectDocument.new({"value" => valid_value}),
    ] of CrystalClick::ObjectDocument], mode: 0_u64)

    forbidden_type = CrystalClick::BinaryDataType.map(
      CrystalClick::BinaryDataType.primitive("UInt64"),
      CrystalClick::BinaryDataType.primitive("UInt64"),
    )
    forbidden_value = CrystalClick::BinaryValue.map(forbidden_type, [
      CrystalClick::BinaryValue.uint64(1_u64),
      CrystalClick::BinaryValue.uint64(2_u64),
    ] of CrystalClick::BinaryValue)
    generic_value = CrystalClick::BinaryValue.map(map_type, [
      CrystalClick::BinaryValue.string("k"),
      CrystalClick::BinaryValue.dynamic(dynamic, forbidden_value),
    ] of CrystalClick::BinaryValue)
    generic_lanes = CrystalClick::BinaryDynamicBulkCodec.encode(
      map_type,
      {"root.elements.field.1" => empty},
      [[generic_value] of CrystalClick::BinaryValue],
    )
    generic_read = CrystalClick::BinaryDynamicBulkCodec.decode(map_type, generic_lanes, [1_u64])
    generic_read[0][0].child_at(1).child_at(0).type.should eq(forbidden_type)

    offset = valid_streams.typed_dynamic_site_statistics_offset("value", "root.elements.field.1").not_nil!
    hostile = CrystalClick::ObjectDocumentStreams.new(
      valid_streams.structures,
      valid_streams.rows_per_mark,
      Hash(String, CrystalClick::BinaryBulkStreams).new,
      Hash(String, CrystalClick::DynamicValueStreams).new,
      valid_streams.shared,
      {"value" => generic_lanes},
      Hash(String, Int32).new,
      {"value" => {"root.elements.field.1" => offset}},
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectDocumentCodec.decode(schema.typed_paths, hostile)
    end
  end

  it "parses one complete two-site metadata plan for full, middle, and zero file windows" do
    w159a_with_pair_fixture do |part, schema, _plan|
      w159a_pair_literals(w159a_read_counted(part, schema, 0, 3)).should eq([
        [{10_u64, "r0"}], [{20_u64, "r1"}], [{30_u64, "r2"}],
      ])
      w159a_pair_literals(w159a_read_counted(part, schema, 1, 1)).should eq([[{20_u64, "r1"}]])
      w159a_read_counted(part, schema, 3, 0).should be_empty
    end
  end

  it "rejects checksummed corruption in an unselected non-root structure site" do
    w159a_with_pair_fixture do |part, schema, plan|
      physical = CrystalClick::ObjectDocumentPhysicalPlan.new("payload", plan)
      structure = physical.typed_dynamic("pair").structure_name_for("root.field.1")
      w159a_mutate_lane(part, structure, 0, 5_u8)
      [{1, 1}, {3, 0}].each do |first_mark, mark_count|
        expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::ObjectDocumentFileReader.read(
            part,
            "payload",
            schema.typed_paths,
            first_mark: first_mark,
            mark_count: mark_count,
            hashed: true,
          )
        end
      end
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::ObjectDocumentFileReader.inspect(part, "payload", schema.typed_paths, hashed: true)
      end
    end
  end

  it "rejects a nested typed Dynamic discriminator with an unknown mode header" do
    w159a_with_pair_fixture do |part, schema, plan|
      physical = CrystalClick::ObjectDocumentPhysicalPlan.new("payload", plan)
      discriminator = physical.typed_dynamic("pair").stream_name_for("root.field.1.discriminators")
      w159a_mutate_lane(part, discriminator, 0, 2_u8)

      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::ObjectDocumentFileReader.read(
          part,
          "payload",
          schema.typed_paths,
          first_mark: 1,
          mark_count: 1,
          hashed: true,
        )
      end
      error.message.not_nil!.should contain("unknown typed Dynamic discriminator mode")
      zero_error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::ObjectDocumentFileReader.read(
          part,
          "payload",
          schema.typed_paths,
          first_mark: 3,
          mark_count: 0,
          hashed: true,
        )
      end
      zero_error.message.not_nil!.should contain("unknown typed Dynamic discriminator mode")
      inspect_error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::ObjectDocumentFileReader.inspect(part, "payload", schema.typed_paths, hashed: true)
      end
      inspect_error.message.not_nil!.should contain("unknown typed Dynamic discriminator mode")
    end
  end

  it "rejects missing, extra, and misnamed per-site structure metadata" do
    schema, valid = w159a_pair_streams
    field = "pair"
    original = valid.typed_dynamic_for(field).structures
    clean = Hash(String, Bytes).new
    original.site_paths.each do |site|
      clean[site] = original.structure_bytes_for(site)
    end

    missing = clean.dup
    missing.delete("root.field.1")
    missing_streams = w159a_replace_site_blobs(valid, field, missing)
    w159a_expect_corrupt_windows(schema, missing_streams)

    extra = clean.dup
    extra["root.field.2"] = original.structure_bytes_for("root.field.0")
    extra_streams = w159a_replace_site_blobs(valid, field, extra)
    w159a_expect_corrupt_windows(schema, extra_streams)

    wrong_role = Hash(String, Bytes).new
    clean.each do |site, bytes|
      wrong_role[site == "root.field.1" ? "root.field.9" : site] = bytes
    end
    wrong_role_streams = w159a_replace_site_blobs(valid, field, wrong_role)
    w159a_expect_corrupt_windows(schema, wrong_role_streams)

    clean_data = valid.typed_dynamic_for(field).data
    wrong_data_roles = Hash(String, CrystalClick::BinaryBulkStream).new
    clean_data.roles.each do |role|
      wrong_data_roles[role == "root.field.1.discriminators" ? "root.field.1.unknown" : role] = clean_data.stream(role)
    end
    wrong_data = CrystalClick::BinaryBulkStreams.new(clean_data.mark_count, wrong_data_roles)
    wrong_data_plan = CrystalClick::BinaryDynamicBulkStreams.new(original, wrong_data)
    wrong_data_streams = w159a_rebuild_streams_with_typed_dynamic(valid, field, wrong_data_plan)
    w159a_expect_corrupt_windows(schema, wrong_data_streams)
  end

  it "rejects an exact per-site V3 statistics suffix with trailing bytes" do
    schema, valid = w159a_pair_streams
    original = valid.typed_dynamic_for("pair").structures
    blobs = Hash(String, Bytes).new
    original.site_paths.each do |site|
      bytes = original.structure_bytes_for(site)
      if site == "root.field.1"
        bytes = Bytes.new(bytes.size + 1) { |index| index < bytes.size ? bytes[index] : 0xff_u8 }
      end
      blobs[site] = bytes
    end
    malformed = w159a_replace_site_blobs(valid, "pair", blobs)
    w159a_expect_corrupt_windows(schema, malformed)
  end

  it "rejects an invalid non-root value K+1 grid before a middle or zero-window read" do
    w159a_with_pair_fixture do |part, schema, plan|
      physical = CrystalClick::ObjectDocumentPhysicalPlan.new("payload", plan)
      role = "root.field.1.discriminators"
      marks = File.join(part, physical.typed_dynamic("pair").marks_file_for(role, hashed: true))
      File.size(marks).should eq(4 * CrystalClick::CompressedMarkReader::MARK_RECORD_SIZE)
      # The last record is the K+1 terminal coordinate. Giving it a nonzero
      # row count is invalid even when only an earlier mark or no mark is read.
      w159a_write_u64_file(marks, 3 * CrystalClick::CompressedMarkReader::MARK_RECORD_SIZE + 16, 1_u64)
      [{1, 1}, {3, 0}].each do |first_mark, mark_count|
        expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::ObjectDocumentFileReader.read(
            part,
            "payload",
            schema.typed_paths,
            first_mark: first_mark,
            mark_count: mark_count,
            hashed: true,
          )
        end
      end
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::ObjectDocumentFileReader.inspect(part, "payload", schema.typed_paths, hashed: true)
      end
    end
  end

  it "accounts for every decimal digit in generated unnamed Tuple site keys" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    dynamic = CrystalClick::BinaryDataType.dynamic(0)
    fields = Array(CrystalClick::BinaryDataType).new(1_001, uint8)
    fields[1_000] = dynamic
    tuple = CrystalClick::BinaryDataType.tuple(fields)
    empty = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    )
    site = "root.field.1000"
    site.bytesize.should eq(15)
    plan = CrystalClick::ObjectDocumentPlan.new(
      empty,
      {"wide" => tuple},
      typed_dynamic_sites: {"wide" => {site => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)}},
    )
    shape = CrystalClick::ObjectDeclaredDynamicSites.shape_for(tuple)
    shape.count.should eq(1_u64)
    shape.path_bytes.should eq(15_u64)
    plan.typed_dynamic_site_count_for("wide").should eq(1)
    plan.typed_dynamic_site_path_at("wide", 0).should eq(site)
  end

  it "budgets repeated nested physical prefixes before name materialization" do
    type = CrystalClick::BinaryDataType.dynamic(1)
    8.times do
      type = CrystalClick::BinaryDataType.tuple(
        [type] of CrystalClick::BinaryDataType,
        ["x"] of String,
      )
    end
    site = "root.field.0.field.0.field.0.field.0.field.0.field.0.field.0.field.0"
    column = "c" * 512
    expected_name = column + ".payload" + ("%2Ex" * 8) + ".dynamic_structure"

    names = CrystalClick::ObjectDocumentPhysicalPlan.typed_dynamic_structure_names(
      column,
      "payload",
      type,
    )
    names.should eq({site => expected_name})

    low_limits = CrystalClick::BinaryCodecLimits.new(
      max_depth: 16,
      max_nodes: 256,
      max_elements: 256,
      max_bytes: 3_072,
    )
    CrystalClick::ObjectRecursiveDeclaration.measure_descriptor(type, low_limits, 2).should_not be_nil
    expected_name.bytesize.should be < low_limits.max_bytes
    low_budget = CrystalClick::BinaryCodecBudget.new(low_limits)
    error = expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectDocumentPhysicalPlan.typed_dynamic_structure_names(
        column,
        "payload",
        type,
        low_budget,
      )
    end
    error.message.not_nil!.should contain("byte limit exceeded")
    low_budget.wire_byte_count.should eq(0_i64)

    shared_limits = CrystalClick::BinaryCodecLimits.new(
      max_depth: 16,
      max_nodes: 256,
      max_elements: 256,
      max_bytes: 10_000,
    )
    shorter_column = "s" * 200
    first_field = "first"
    second_field = "other"
    {first_field, second_field}.each do |field|
      individual = CrystalClick::BinaryCodecBudget.new(shared_limits)
      CrystalClick::ObjectDocumentPhysicalPlan.typed_dynamic_structure_names(
        shorter_column,
        field,
        type,
        individual,
      ).size.should eq(1)
    end

    shared_budget = CrystalClick::BinaryCodecBudget.new(shared_limits)
    CrystalClick::ObjectDocumentPhysicalPlan.typed_dynamic_structure_names(
      shorter_column,
      first_field,
      type,
      shared_budget,
    ).size.should eq(1)
    first_charge = shared_budget.wire_byte_count
    first_charge.should be > 0_i64
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectDocumentPhysicalPlan.typed_dynamic_structure_names(
        shorter_column,
        second_field,
        type,
        shared_budget,
      )
    end
    shared_budget.wire_byte_count.should eq(first_charge)
  end

  it "refuses maximal Int32 depth by byte budget without overflowing" do
    limits = CrystalClick::BinaryCodecLimits.new(
      max_depth: Int32::MAX,
      max_nodes: 8,
      max_elements: 8,
      max_bytes: 32,
    )
    type = CrystalClick::BinaryDataType.dynamic(0)
    CrystalClick::ObjectRecursiveDeclaration.measure_descriptor(type, limits, 2).should_not be_nil
    "c.v.dynamic_structure".bytesize.to_i64.should be < limits.max_bytes
    budget = CrystalClick::BinaryCodecBudget.new(limits)

    error = expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectDocumentPhysicalPlan.typed_dynamic_structure_names(
        "c",
        "v",
        type,
        budget,
      )
    end
    error.message.not_nil!.should contain("byte limit exceeded")
    budget.wire_byte_count.should eq(0_i64)
  end

  it "preflights recursive selected Dynamic values against a borrowed budget" do
    dynamic = CrystalClick::BinaryDataType.dynamic(0)
    array_type = CrystalClick::BinaryDataType.array(dynamic)
    value = CrystalClick::BinaryValue.array(
      array_type,
      Array(CrystalClick::BinaryValue).new(12) { CrystalClick::BinaryValue.dynamic(dynamic) },
    )

    generous = CrystalClick::BinaryCodecLimits.default
    shallow_limits = CrystalClick::BinaryCodecLimits.new(
      max_depth: 3,
      max_nodes: 128,
      max_elements: 128,
      max_bytes: 1_024,
    )
    shallow_budget = CrystalClick::BinaryCodecBudget.new(shallow_limits, true)
    CrystalClick::ObjectDeclaredDynamicDeclaration.validate_selected_values!(
      value,
      array_type,
      shallow_budget,
      true,
    )

    measured = CrystalClick::BinaryCodecBudget.new(generous, true)
    CrystalClick::ObjectDeclaredDynamicDeclaration.validate_selected_values!(
      value,
      array_type,
      measured,
      true,
    )
    measured.node_count.should be > 0_i64
    measured.element_count.should be > 0_i64

    exact_limits = CrystalClick::BinaryCodecLimits.new(
      max_depth: generous.max_depth,
      max_nodes: measured.node_count,
      max_elements: measured.element_count,
      max_bytes: generous.max_bytes,
    )
    shared = CrystalClick::BinaryCodecBudget.new(exact_limits, true)
    CrystalClick::ObjectDeclaredDynamicDeclaration.validate_selected_values!(value, array_type, shared, true)
    w159a_budget_counts(shared).should eq(w159a_budget_counts(measured))
    shared_counts = w159a_budget_counts(shared)
    second_field = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDeclaredDynamicDeclaration.validate_selected_values!(value, array_type, shared, true)
    end
    second_field.message.not_nil!.should contain("node limit exceeded")
    w159a_budget_counts(shared).should eq(shared_counts)

    element_short = CrystalClick::BinaryCodecLimits.new(
      max_depth: generous.max_depth,
      max_nodes: measured.node_count,
      max_elements: measured.element_count - 1_i64,
      max_bytes: generous.max_bytes,
    )
    preflight = CrystalClick::BinaryCodecBudget.new(element_short, true)
    forbidden_actual = CrystalClick::BinaryDataType.array(
      CrystalClick::BinaryDataType.variant([CrystalClick::BinaryDataType.primitive("UInt64")] of CrystalClick::BinaryDataType)
    )
    poison = CrystalClick::BinaryValue.dynamic(
      dynamic,
      CrystalClick::BinaryValue.array(forbidden_actual, [] of CrystalClick::BinaryValue),
    )
    preflight_values = Array(CrystalClick::BinaryValue).new(12) { CrystalClick::BinaryValue.dynamic(dynamic) }
    preflight_values[0] = poison
    preflight_value = CrystalClick::BinaryValue.array(array_type, preflight_values)
    invalid_value_budget = CrystalClick::BinaryCodecBudget.new(generous, true)
    invalid_value = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDeclaredDynamicDeclaration.validate_selected_values!(
        preflight_value,
        array_type,
        invalid_value_budget,
        true,
      )
    end
    invalid_value.message.not_nil!.should contain("outside the Object recursive arm domain")

    error = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDeclaredDynamicDeclaration.validate_selected_values!(
        preflight_value,
        array_type,
        preflight,
        true,
      )
    end
    error.message.not_nil!.should contain("element limit exceeded")
    preflight.element_count.should eq(0_i64)
  end

  it "charges nested selected values during Object statistics recomputation" do
    dynamic = CrystalClick::BinaryDataType.dynamic(0)
    array_type = CrystalClick::BinaryDataType.array(dynamic)
    schema = CrystalClick::ObjectDocumentSchema.new({"items" => array_type})
    empty = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    )
    plan = CrystalClick::ObjectDocumentPlan.new(
      empty,
      schema.typed_paths,
      typed_dynamic_sites: {
        "items" => {
          "root.elements" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType),
        },
      },
    )
    empty_value = CrystalClick::BinaryValue.array(array_type, [] of CrystalClick::BinaryValue)
    full_value = CrystalClick::BinaryValue.array(
      array_type,
      Array(CrystalClick::BinaryValue).new(12) { CrystalClick::BinaryValue.dynamic(dynamic) },
    )
    empty_rows = [[CrystalClick::ObjectDocument.new({"items" => empty_value})] of CrystalClick::ObjectDocument]
    full_rows = [[CrystalClick::ObjectDocument.new({"items" => full_value})] of CrystalClick::ObjectDocument]

    generous = CrystalClick::BinaryCodecLimits.new(
      max_depth: 64,
      max_nodes: 100_000,
      max_elements: 100_000,
      max_bytes: 1_000_000,
    )
    empty_measure = CrystalClick::BinaryCodecBudget.new(generous, true)
    CrystalClick::ObjectDocumentStatistics.recompute_with_budget(plan, empty_rows, empty_measure)
    empty_counts = w159a_budget_counts(empty_measure)
    full_measure = CrystalClick::BinaryCodecBudget.new(generous, true)
    CrystalClick::ObjectDocumentStatistics.recompute_with_budget(plan, full_rows, full_measure)
    full_counts = w159a_budget_counts(full_measure)
    full_counts[0].should be > empty_counts[0]
    full_counts[1].should be > empty_counts[1]

    exact_empty_limits = CrystalClick::BinaryCodecLimits.new(
      max_depth: generous.max_depth,
      max_nodes: empty_counts[0],
      max_elements: empty_counts[1],
      max_bytes: generous.max_bytes,
    )
    empty_control = CrystalClick::BinaryCodecBudget.new(exact_empty_limits, true)
    CrystalClick::ObjectDocumentStatistics.recompute_with_budget(plan, empty_rows, empty_control)
    w159a_budget_counts(empty_control).should eq(empty_counts)

    nested_budget = CrystalClick::BinaryCodecBudget.new(exact_empty_limits, true)
    error = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentStatistics.recompute_with_budget(plan, full_rows, nested_budget)
    end
    error.message.not_nil!.should contain("limit exceeded")
  end

  it "rejects typed lane names that collide with the generated Object shared roster" do
    string = CrystalClick::BinaryDataType.primitive("String")
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    map = CrystalClick::BinaryDataType.map(string, uint64)
    dynamic = CrystalClick::BinaryDataType.dynamic(0)
    nested = CrystalClick::BinaryDataType.array(dynamic)
    schema = CrystalClick::ObjectDocumentSchema.new({
      "object_shared_data" => map,
      "value"              => nested,
    })
    empty = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    )
    plan = CrystalClick::ObjectDocumentPlan.new(
      empty,
      schema.typed_paths,
      typed_dynamic_sites: {"value" => {"root.elements" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)}},
    )
    error = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentPhysicalPlan.new("payload", plan)
    end
    error.message.not_nil!.should contain("collid")
  end
end
