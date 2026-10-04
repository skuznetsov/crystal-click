require "./spec_helper"

module W158TypedDynamicPlanDecodeProbe
  class_property enabled = false
  class_property calls = 0

  def self.begin : Nil
    self.calls = 0
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
    W158TypedDynamicPlanDecodeProbe.calls += 1 if W158TypedDynamicPlanDecodeProbe.enabled
    previous_def(type, streams, budget, profile)
  end
end

private def w158a_fixture : Tuple(String, CrystalClick::ObjectDocumentSchema, CrystalClick::ObjectDocumentPlan)
  dynamic = CrystalClick::BinaryDataType.dynamic(1)
  uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
  schema = CrystalClick::ObjectDocumentSchema.new({"value" => dynamic})
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new([] of String),
    {} of String => CrystalClick::DynamicStructure,
  )
  plan = CrystalClick::ObjectDocumentPlan.new(
    structures,
    schema.typed_paths,
    {"value" => CrystalClick::DynamicStructure.new([uint64])},
  )
  parent = File.tempname("crystal-click-w158-declared-dynamic-adversary-")
  Dir.mkdir(parent)
  part = File.join(parent, "all_1_1_0")
  documents = Array(Array(CrystalClick::ObjectDocument)).new
  keys = [] of UInt64
  value = 10_u64
  3.times do
    documents << [
      CrystalClick::ObjectDocument.new({
        "value" => CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.uint64(value)),
      }),
    ] of CrystalClick::ObjectDocument
    keys << value
    value += 10_u64
  end
  CrystalClick::WidePartWriter.write_uint64_object_pair(
    part,
    "pk",
    Slice(UInt64).new(keys.size) { |index| keys[index] },
    "payload",
    schema,
    plan,
    documents,
    rows_per_mark: 1,
    mode: 0_u64,
    frame_bytes: 64,
  )
  {parent, schema, plan}
end

private def w158a_with_fixture(&)
  parent, schema, plan = w158a_fixture
  begin
    yield File.join(parent, "all_1_1_0"), schema, plan
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w158a_with_shared_path_collision_fixture(&)
  dynamic = CrystalClick::BinaryDataType.dynamic(1)
  uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
  schema = CrystalClick::ObjectDocumentSchema.new({"value" => dynamic})
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new([] of String),
    {} of String => CrystalClick::DynamicStructure,
  )
  plan = CrystalClick::ObjectDocumentPlan.new(
    structures,
    schema.typed_paths,
    {"value" => CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType)},
  )
  parent = File.tempname("crystal-click-w158-typed-dynamic-shared-collision-")
  Dir.mkdir(parent)
  part = File.join(parent, "all_1_1_0")
  begin
    document = CrystalClick::ObjectDocument.new({
      "other" => CrystalClick::BinaryValue.string("shared"),
      "value" => CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.uint64(42_u64)),
    } of String => CrystalClick::BinaryValue)
    CrystalClick::WidePartWriter.write_uint64_object_pair(
      part,
      "pk",
      Slice(UInt64).new(1) { 1_u64 },
      "payload",
      schema,
      plan,
      [[document] of CrystalClick::ObjectDocument],
      rows_per_mark: 1,
      mode: 0_u64,
      frame_bytes: 64,
    )
    physical = CrystalClick::ObjectDocumentPhysicalPlan.new("payload", plan)
    shared_path_stream = physical.shared.stream_name_for("root.elements.field.0.data")
    yield part, schema, shared_path_stream
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w158a_literal_values(rows : Array(Array(CrystalClick::ObjectDocument))) : Array(Array(UInt64))
  rows.map do |mark|
    mark.map do |document|
      value = document.value_for("value")
      value.type.tag.should eq(CrystalClick::BinaryDataType::TAG_DYNAMIC)
      value.child_at(0).as_uint64
    end
  end
end

private def w158a_read_counted(
  part : String,
  schema : CrystalClick::ObjectDocumentSchema,
  first_mark : Int,
  mark_count : Int,
) : Array(Array(CrystalClick::ObjectDocument))
  W158TypedDynamicPlanDecodeProbe.begin
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
    W158TypedDynamicPlanDecodeProbe.finish
  end
  W158TypedDynamicPlanDecodeProbe.calls.should eq(1)
  rows
end

private def w158a_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times do |index|
    bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8
  end
end

private def w158a_write_u64_file(path : String, offset : Int, value : UInt64) : Nil
  bytes = Bytes.new(8)
  w158a_write_u64(bytes, 0, value)
  File.open(path, "r+b") do |io|
    io.seek(offset)
    io.write(bytes)
  end
end

private def w158a_corrupt_frame_raw_byte(path : String, raw_offset : Int, value : UInt8) : Nil
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
  w158a_write_u64(frame, 0, checksum[0])
  w158a_write_u64(frame, 8, checksum[1])
  File.write(path, frame)
end

private def w158a_mutate_lane(part : String, logical_name : String, raw_offset : Int, value : UInt8) : Nil
  path = File.join(part, CrystalClick::StreamName.hash(logical_name) + ".bin")
  w158a_corrupt_frame_raw_byte(path, raw_offset, value)
end

private def w158a_codec_input(
  structure : CrystalClick::DynamicStructure,
  child : CrystalClick::BinaryValue,
  max_types : Int = 1,
) : Tuple(CrystalClick::ObjectDocumentSchema, CrystalClick::ObjectDocumentPlan, Array(Array(CrystalClick::ObjectDocument)))
  dynamic = CrystalClick::BinaryDataType.dynamic(max_types)
  schema = CrystalClick::ObjectDocumentSchema.new({"value" => dynamic})
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new([] of String),
    {} of String => CrystalClick::DynamicStructure,
  )
  plan = CrystalClick::ObjectDocumentPlan.new(structures, schema.typed_paths, {"value" => structure})
  rows = Array(Array(CrystalClick::ObjectDocument)).new
  rows << [CrystalClick::ObjectDocument.new({
    "value" => CrystalClick::BinaryValue.dynamic(dynamic, child),
  })] of CrystalClick::ObjectDocument
  {schema, plan, rows}
end

private def w158a_budget_counts(budget : CrystalClick::BinaryCodecBudget) : Tuple(Int64, Int64, Int64)
  {budget.node_count, budget.element_count, budget.wire_byte_count}
end

private def w158a_limits(nodes : Int, elements : Int, bytes : Int) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: 64,
    max_nodes: nodes,
    max_elements: elements,
    max_bytes: bytes,
  )
end

private def w158a_forbidden_recursive_types : Array(CrystalClick::BinaryDataType)
  dynamic = CrystalClick::BinaryDataType.dynamic(0)
  variant = CrystalClick::BinaryDataType.variant([
    CrystalClick::BinaryDataType.primitive("UInt64"),
    CrystalClick::BinaryDataType.primitive("String"),
  ] of CrystalClick::BinaryDataType)
  low_cardinality = CrystalClick::BinaryDataType.low_cardinality(
    CrystalClick::BinaryDataType.primitive("String")
  )
  [
    CrystalClick::BinaryDataType.array(dynamic),
    CrystalClick::BinaryDataType.array(variant),
    CrystalClick::BinaryDataType.array(low_cardinality),
  ] of CrystalClick::BinaryDataType
end

describe "W158 direct declared Dynamic physical read adversaries" do
  it "retains the COMPACT policy guard for declared Dynamic fields" do
    CrystalClick::ObjectDocumentCodec::DEFAULT_MODE.should eq(CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE)
    structure = CrystalClick::DynamicStructure.new([
      CrystalClick::BinaryDataType.primitive("UInt64"),
    ] of CrystalClick::BinaryDataType)
    _schema, plan, rows = w158a_codec_input(structure, CrystalClick::BinaryValue.uint64(10_u64))

    error = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentCodec.encode(
        plan,
        rows,
        mode: CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE,
      )
    end
    error.message.not_nil!.should contain("BASIC Dynamic profile")
  end

  it "drops supplied Dynamic statistics and emits a V3 child with the absent-statistics flag" do
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    stale_statistics = CrystalClick::StructureStatistics.new(
      [999_u64, 777_u64],
      [CrystalClick::StructureStatistic.new("stale", 123_u64)],
    )
    supplied = CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType, stale_statistics)
    supplied.statistics.not_nil!.count_at(0).should eq(999_u64)
    schema, plan, rows = w158a_codec_input(supplied, CrystalClick::BinaryValue.uint64(10_u64))

    streams = CrystalClick::ObjectDocumentCodec.encode(plan, rows, mode: 0_u64)
    child = streams.typed_dynamic_for("value").structures.structure_bytes_for("root")
    child.should eq(Bytes[0x04_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 1_u8, 0x04_u8, 0_u8])
    streams.typed_dynamic_statistics_offset("value").should eq(10)
    CrystalClick::DynamicStructureCodec.decode(child).statistics.should be_nil
    decoded = CrystalClick::ObjectDocumentCodec.decode(schema.typed_paths, streams)
    w158a_literal_values(decoded).should eq([[10_u64]])
    supplied.statistics.not_nil!.count_at(0).should eq(999_u64)
  end

  it "enforces exact shared Object Dynamic budgets, one-short dimensions, and direction" do
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    structure = CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType)
    schema, plan, rows = w158a_codec_input(structure, CrystalClick::BinaryValue.uint64(10_u64))

    write_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true)
    streams = CrystalClick::ObjectDocumentCodec.encode_with_budget(plan, rows, write_budget, mode: 0_u64)
    write_counts = w158a_budget_counts(write_budget)
    write_counts.each { |count| count.should be > 0_i64 }
    exact_write_limits = w158a_limits(write_counts[0].to_i, write_counts[1].to_i, write_counts[2].to_i)
    exact_write = CrystalClick::BinaryCodecBudget.new(exact_write_limits, true)
    CrystalClick::ObjectDocumentCodec.encode_with_budget(plan, rows, exact_write, mode: 0_u64)
    w158a_budget_counts(exact_write).should eq(write_counts)

    [
      {write_counts[0].to_i - 1, write_counts[1].to_i, write_counts[2].to_i},
      {write_counts[0].to_i, write_counts[1].to_i - 1, write_counts[2].to_i},
      {write_counts[0].to_i, write_counts[1].to_i, write_counts[2].to_i - 1},
    ].each do |short_counts|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        short_budget = CrystalClick::BinaryCodecBudget.new(
          w158a_limits(short_counts[0], short_counts[1], short_counts[2]), true
        )
        CrystalClick::ObjectDocumentCodec.encode_with_budget(plan, rows, short_budget, mode: 0_u64)
      end
    end

    read_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
    CrystalClick::ObjectDocumentCodec.decode_with_budget(schema.typed_paths, streams, read_budget)
    read_counts = w158a_budget_counts(read_budget)
    read_counts.each { |count| count.should be > 0_i64 }
    exact_read = CrystalClick::BinaryCodecBudget.new(
      w158a_limits(read_counts[0].to_i, read_counts[1].to_i, read_counts[2].to_i)
    )
    CrystalClick::ObjectDocumentCodec.decode_with_budget(schema.typed_paths, streams, exact_read)
    w158a_budget_counts(exact_read).should eq(read_counts)

    [
      {read_counts[0].to_i - 1, read_counts[1].to_i, read_counts[2].to_i},
      {read_counts[0].to_i, read_counts[1].to_i - 1, read_counts[2].to_i},
      {read_counts[0].to_i, read_counts[1].to_i, read_counts[2].to_i - 1},
    ].each do |short_counts|
      expect_raises(CrystalClick::CorruptPartError) do
        short_budget = CrystalClick::BinaryCodecBudget.new(
          w158a_limits(short_counts[0], short_counts[1], short_counts[2])
        )
        CrystalClick::ObjectDocumentCodec.decode_with_budget(schema.typed_paths, streams, short_budget)
      end
    end

    wrong_read_direction = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentCodec.encode_with_budget(plan, rows, wrong_read_direction, mode: 0_u64)
    end
    w158a_budget_counts(wrong_read_direction).should eq({0_i64, 0_i64, 0_i64})
    wrong_write_direction = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true)
    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentCodec.decode_with_budget(schema.typed_paths, streams, wrong_write_direction)
    end
    w158a_budget_counts(wrong_write_direction).should eq({0_i64, 0_i64, 0_i64})
  end

  it "rejects recursive Dynamic, Variant, and LowCardinality actual arms and SharedVariant spills" do
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    declared = CrystalClick::BinaryDataType.dynamic(0)
    schema = CrystalClick::ObjectDocumentSchema.new({
      "ordinary" => uint64,
      "value"    => declared,
    })
    empty_roster = CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)
    object_structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["inferred"] of String),
      {"inferred" => CrystalClick::DynamicStructure.new([
        CrystalClick::BinaryDataType.primitive("String"),
      ] of CrystalClick::BinaryDataType)},
    )
    parent_plan = CrystalClick::ObjectDocumentPlan.new(
      object_structures,
      schema.typed_paths,
      {"value" => empty_roster},
    )
    parent_rows = [[CrystalClick::ObjectDocument.new({
      "ordinary" => CrystalClick::BinaryValue.uint64(20_u64),
      "value"    => CrystalClick::BinaryValue.dynamic(declared, CrystalClick::BinaryValue.uint64(10_u64)),
      "inferred" => CrystalClick::BinaryValue.string("inferred"),
    })] of CrystalClick::ObjectDocument]
    parent_streams = CrystalClick::ObjectDocumentCodec.encode(parent_plan, parent_rows, mode: 0_u64)

    w158a_forbidden_recursive_types.each do |forbidden_type|
      invalid_roster = CrystalClick::DynamicStructure.new([forbidden_type] of CrystalClick::BinaryDataType)
      _schema, invalid_plan, _rows = w158a_codec_input(
        invalid_roster, CrystalClick::BinaryValue.uint64(10_u64)
      )
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentCodec.encode(
          invalid_plan, [] of Array(CrystalClick::ObjectDocument), mode: 0_u64
        )
      end

      empty_roster = CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)
      forbidden_value = CrystalClick::BinaryValue.array(forbidden_type, [] of CrystalClick::BinaryValue)
      _schema, spill_plan, spill_rows = w158a_codec_input(empty_roster, forbidden_value, 0)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentCodec.encode(spill_plan, spill_rows, mode: 0_u64)
      end
    end

    # Generic Dynamic already refuses recursive Dynamic/Variant/LC descriptors
    # at its own boundary. Map(UInt64, UInt64) is instead generic-admitted but
    # outside Object's narrower Map(String, ...) recursive grammar. Prove the
    # generic codec round-trips that spill, then submit those lanes to Object.
    forbidden_type = CrystalClick::BinaryDataType.map(uint64, uint64)
    forbidden_value = CrystalClick::BinaryValue.map(
      forbidden_type,
      [CrystalClick::BinaryValue.uint64(1_u64), CrystalClick::BinaryValue.uint64(2_u64)] of CrystalClick::BinaryValue,
    )
    dynamic = CrystalClick::BinaryDataType.dynamic(0)
    generic_spill = CrystalClick::BinaryValue.dynamic(dynamic, forbidden_value)
    generic_lanes = CrystalClick::BinaryDynamicBulkCodec.encode(
      dynamic,
      {"root" => empty_roster},
      [[generic_spill] of CrystalClick::BinaryValue],
    )
    generic_read = CrystalClick::BinaryDynamicBulkCodec.decode(dynamic, generic_lanes, [1_u64])
    generic_read[0][0].child_at(0).type.should eq(forbidden_type)

    hostile_streams = CrystalClick::ObjectDocumentStreams.new(
      parent_streams.structures,
      parent_streams.rows_per_mark,
      {"ordinary" => parent_streams.typed_for("ordinary")},
      {"inferred" => parent_streams.dynamic_for("inferred")},
      parent_streams.shared,
      {"value" => generic_lanes},
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectDocumentCodec.decode(schema.typed_paths, hostile_streams)
    end
  end

  it "decodes one retained typed-Dynamic structure plan for full, middle, and zero windows" do
    w158a_with_fixture do |part, schema, _plan|
      w158a_literal_values(w158a_read_counted(part, schema, 0, 3)).should eq([[10_u64], [20_u64], [30_u64]])
      w158a_literal_values(w158a_read_counted(part, schema, 1, 1)).should eq([[20_u64]])
      w158a_read_counted(part, schema, 3, 0).should be_empty
    end
  end

  it "rejects an invalid Dynamic discriminator header before returning selected values" do
    w158a_with_fixture do |part, schema, plan|
      physical = CrystalClick::ObjectDocumentPhysicalPlan.new("payload", plan)
      discriminator = physical.typed_dynamic("value").stream_name_for("root.discriminators")
      w158a_mutate_lane(part, discriminator, 0, 2_u8)

      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::ObjectDocumentFileReader.read(
          part, "payload", schema.typed_paths,
          first_mark: 1, mark_count: 1, hashed: true
        )
      end
      error.message.not_nil!.should contain("nonzero BASIC mode header")
    end
  end

  it "rejects a checksummed selected shared path that aliases a declared Dynamic field" do
    w158a_with_shared_path_collision_fixture do |part, schema, shared_path_stream|
      # A one-entry String lane is [varuint length][path bytes]. Both names
      # have five bytes, so replacing the complete path preserves every lane
      # coordinate while the helper rebuilds the compressed-frame checksum.
      "value".to_slice.each_with_index do |byte, index|
        w158a_mutate_lane(part, shared_path_stream, index + 1, byte)
      end

      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::ObjectDocumentFileReader.read(
          part,
          "payload",
          schema.typed_paths,
          first_mark: 0,
          mark_count: 1,
          hashed: true,
        )
      end
      error.message.not_nil!.should contain("collid")
    end
  end

  it "validates corrupted unselected typed-Dynamic metadata for middle and zero windows" do
    w158a_with_fixture do |part, schema, plan|
      physical = CrystalClick::ObjectDocumentPhysicalPlan.new("payload", plan)
      structure = physical.typed_dynamic("value").structure_name_for("root")
      w158a_mutate_lane(part, structure, 0, 5_u8)

      [{1, 1}, {3, 0}].each do |first_mark, mark_count|
        expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::ObjectDocumentFileReader.read(
            part, "payload", schema.typed_paths,
            first_mark: first_mark, mark_count: mark_count, hashed: true
          )
        end
      end
    end
  end

  it "validates an unselected typed-Dynamic value grid for middle and zero windows" do
    w158a_with_fixture do |part, schema, plan|
      physical = CrystalClick::ObjectDocumentPhysicalPlan.new("payload", plan)
      value_role = "root.arm.1.data"
      marks = File.join(part, physical.typed_dynamic("value").marks_file_for(value_role, hashed: true))
      w158a_write_u64_file(marks, 16, 2_u64)

      [{1, 1}, {3, 0}].each do |first_mark, mark_count|
        expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::ObjectDocumentFileReader.read(
            part, "payload", schema.typed_paths,
            first_mark: first_mark, mark_count: mark_count, hashed: true
          )
        end
      end
    end
  end
end
