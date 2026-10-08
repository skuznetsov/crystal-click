require "./spec_helper"

module W184ChildOccurrenceProbe
  class_property enabled = false
  class_property budget_events = [] of Tuple(String, CrystalClick::BinaryCodecBudget, Int64)
  class_property prefix_adapter_calls = 0

  def self.begin : Nil
    self.budget_events = [] of Tuple(String, CrystalClick::BinaryCodecBudget, Int64)
    self.prefix_adapter_calls = 0
    self.enabled = true
  end

  def self.finish : Nil
    self.enabled = false
  end

  def self.observe_budget(layer : String, budget : CrystalClick::BinaryCodecBudget) : Nil
    budget_events << {layer, budget, budget.node_count} if enabled
  end
end

# Test-only identity observations prove the explicit Object -> Dynamic value
# -> discriminator child route keeps one aggregate budget object.
module CrystalClick::ObjectDocumentCodec
  def self.encode_child_site_with_budget(
    plan : ObjectDocumentPlan,
    granules : Array(Array(ObjectDocument)),
    grid : StorageOccurrenceGrid,
    budget : BinaryCodecBudget,
    mode : UInt64 = DynamicDiscriminatorCodec::BASIC_MODE,
    profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
    shared_profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
    typed_descriptor_root_depth : Int32 = 2,
    inferred_actual_root_depth : Int32? = nil,
  ) : ObjectDocumentStreams
    W184ChildOccurrenceProbe.observe_budget("object", budget)
    previous_def(
      plan, granules, grid, budget, mode: mode, profile: profile,
      shared_profile: shared_profile, typed_descriptor_root_depth: typed_descriptor_root_depth,
      inferred_actual_root_depth: inferred_actual_root_depth,
    )
  end
end

class CrystalClick::DynamicValueCodec
  def self.encode_child_site_with_budget(
    structure : DynamicStructure,
    granules : Array(Array(BinaryValue)),
    grid : StorageOccurrenceGrid,
    budget : BinaryCodecBudget,
    mode : UInt64 = DynamicDiscriminatorCodec::BASIC_MODE,
    profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
    json_object_leaf_plans : Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan)) = [] of Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan),
    inferred_actual_root_depth : Int32 = 1_i32,
    child_shared_profile : BinaryBulkProfile = profile,
  ) : DynamicValueStreams
    W184ChildOccurrenceProbe.observe_budget("dynamic", budget)
    previous_def(
      structure, granules, grid, budget, mode: mode, profile: profile,
      json_object_leaf_plans: json_object_leaf_plans,
      inferred_actual_root_depth: inferred_actual_root_depth,
      child_shared_profile: child_shared_profile,
    )
  end
end

class CrystalClick::DynamicDiscriminatorCodec
  def self.encode_child_site_with_budget(
    structure : DynamicStructure,
    tags : Array(Array(UInt8)),
    grid : StorageOccurrenceGrid,
    budget : BinaryCodecBudget,
    mode : UInt64 = BASIC_MODE,
  ) : DynamicDiscriminatorStream
    W184ChildOccurrenceProbe.observe_budget("discriminator", budget)
    previous_def(structure, tags, grid, budget, mode: mode)
  end
end

class CrystalClick::BinaryBulkPhysicalPrefixAdapter
  def self.write_lane(
    role : String,
    stream : BinaryBulkStream,
    prefix_size : Int,
  ) : Tuple(Bytes, Array(UInt64), Int32)
    W184ChildOccurrenceProbe.prefix_adapter_calls += 1 if W184ChildOccurrenceProbe.enabled
    previous_def(role, stream, prefix_size)
  end
end

private def w184c_binary_budget(writing : Bool) : CrystalClick::BinaryCodecBudget
  CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, writing)
end

private def w184c_fixture : Tuple(
  Hash(String, CrystalClick::BinaryDataType),
  CrystalClick::ObjectDocumentPlan,
  CrystalClick::StorageOccurrenceGrid,
  CrystalClick::BinaryCodecBudget,
  Array(Array(CrystalClick::ObjectDocument)),
)
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  dynamic_type = CrystalClick::BinaryDataType.dynamic(1)
  string = CrystalClick::BinaryDataType.primitive("String")
  runtime_structure = CrystalClick::DynamicStructure.new([string] of CrystalClick::BinaryDataType)
  declared_structure = CrystalClick::DynamicStructure.new([string] of CrystalClick::BinaryDataType)

  structures = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new(["d"] of String),
    {"d" => runtime_structure},
  )
  typed_schema = Hash(String, CrystalClick::BinaryDataType).new
  typed_schema["t"] = uint8
  typed_schema["td"] = dynamic_type
  typed_dynamics = {"td" => declared_structure}
  plan = CrystalClick::ObjectDocumentPlan.new(structures, typed_schema, typed_dynamics)

  empty_mark = [] of CrystalClick::ObjectDocument
  one_mark = [
    w184c_document(7_u8, nil, CrystalClick::BinaryValue.string("td1")),
  ] of CrystalClick::ObjectDocument
  three_mark = [
    w184c_document(11_u8, CrystalClick::BinaryValue.string("a"), CrystalClick::BinaryValue.string("x")),
    w184c_document(13_u8, nil, nil, extra: true),
    w184c_document(17_u8, CrystalClick::BinaryValue.string("b"), CrystalClick::BinaryValue.string("y")),
  ] of CrystalClick::ObjectDocument
  granules = [empty_mark, one_mark, three_mark, empty_mark] of Array(CrystalClick::ObjectDocument)

  budget = w184c_binary_budget(true)
  grid = CrystalClick::StorageOccurrenceGrid.new(
    [2_u64, 2_u64, 2_u64, 2_u64],
    [0_u64, 1_u64, 3_u64, 0_u64],
    budget,
  )
  {typed_schema, plan, grid, budget, granules}
end

private def w184c_document(
  byte : UInt8,
  runtime_child : CrystalClick::BinaryValue?,
  declared_child : CrystalClick::BinaryValue?,
  extra : Bool = false,
) : CrystalClick::ObjectDocument
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  dynamic_type = CrystalClick::BinaryDataType.dynamic(1)
  fields = {
    "t"  => CrystalClick::BinaryValue.fixed(uint8, Bytes[byte]),
    "td" => CrystalClick::BinaryValue.dynamic(dynamic_type, declared_child),
    "d"  => runtime_child || CrystalClick::BinaryValue.null,
  } of String => CrystalClick::BinaryValue
  fields["extra"] = CrystalClick::BinaryValue.string("spill") if extra
  CrystalClick::ObjectDocument.new(fields)
end

private def w184c_dynamic_text(value : CrystalClick::BinaryValue) : String
  return "NULL" if value.is_null?
  value.child_at(0).as_string
end

private def w184c_with_parent(&)
  parent = File.tempname("crystal-click-w184-child-lanes-")
  Dir.mkdir(parent)
  begin
    yield parent
  ensure
    FileUtils.rm_rf(parent)
  end
end

describe "W184 paired recursive child occurrences" do
  it "round trips empty marks separately from positive NULL Dynamic occurrences and preserves nonzero-origin windows" do
    typed_schema, plan, grid, write_budget, granules = w184c_fixture
    streams = CrystalClick::ObjectDocumentCodec.encode_child_site_with_budget(
      plan,
      granules,
      grid,
      write_budget,
    )

    streams.rows_per_mark.should eq([0_u64, 1_u64, 3_u64, 0_u64])
    typed_source = streams.typed_for("t").stream("root.data")
    typed_source.bytes.should eq(Bytes[7_u8, 11_u8, 13_u8, 17_u8])
    typed_source.offsets.should eq([0_u64, 0_u64, 1_u64, 4_u64, 4_u64])
    streams.row_count_at(0).should eq(0_u64)
    streams.row_count_at(1).should eq(1_u64)
    streams.row_count_at(2).should eq(3_u64)
    streams.row_count_at(3).should eq(0_u64)

    runtime_discriminator = streams.dynamic_for("d").discriminators
    runtime_discriminator.marks.map(&.offset).should eq([8_u64, 8_u64, 9_u64, 12_u64, 12_u64])
    runtime_discriminator.marks.map(&.rows).should eq([0_u64, 1_u64, 3_u64, 0_u64, 0_u64])
    string_tag = plan.structures.dynamic_for("d").canonical_index_for(
      CrystalClick::BinaryDataType.primitive("String")
    ).to_u8

    schedules = CrystalClick::DynamicDiscriminatorCodec.decode_child_site_with_budget(
      plan.structures.dynamic_for("d"),
      runtime_discriminator,
      grid,
      w184c_binary_budget(false),
      first_mark: 2,
      mark_count: 2,
    )
    schedules.size.should eq(2)
    schedules[0].mark_index.should eq(2)
    schedules[0].first_row.should eq(1_u64)
    schedules[0].tags.should eq([string_tag, CrystalClick::DynamicDiscriminatorCodec::NULL_TAG, string_tag])
    schedules[1].mark_index.should eq(3)
    schedules[1].first_row.should eq(4_u64)
    schedules[1].row_count.should eq(0)

    selected = CrystalClick::ObjectDocumentCodec.decode_child_site_with_budget(
      typed_schema,
      streams,
      grid,
      w184c_binary_budget(false),
      first_mark: 2,
      mark_count: 2,
    )
    selected.size.should eq(2)
    selected[0].map { |document| document.value_for("t").byte_at(0) }.should eq([11_u8, 13_u8, 17_u8])
    selected[0].map do |document|
      document.has_path?("d") ? document.value_for("d").as_string : "NULL"
    end.should eq(["a", "NULL", "b"])
    selected[0].map { |document| w184c_dynamic_text(document.value_for("td")) }.should eq(["x", "NULL", "y"])
    selected[0][1].has_path?("extra").should be_true
    selected[0][1].value_for("extra").as_string.should eq("spill")
    selected[0][0].has_path?("extra").should be_false
    selected[1].should be_empty

    full = CrystalClick::ObjectDocumentCodec.decode_child_site_with_budget(
      typed_schema, streams, grid, w184c_binary_budget(false)
    )
    full.map(&.size).should eq([0, 1, 3, 0])
    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentCodec.encode_child_site_with_budget(
        plan, granules, grid, w184c_binary_budget(false)
      )
    end
    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentCodec.decode_child_site_with_budget(
        typed_schema, streams, grid, w184c_binary_budget(true)
      )
    end
  end

  it "distinguishes equal-total redistributed child counts and validates the complete grid on empty selections" do
    typed_schema, plan, object_grid, _write_budget, object_granules = w184c_fixture
    structure = plan.structures.dynamic_for("d")
    string_tag = structure.canonical_index_for(CrystalClick::BinaryDataType.primitive("String")).to_u8
    null_tag = CrystalClick::DynamicDiscriminatorCodec::NULL_TAG
    tags = [
      [] of UInt8,
      [string_tag],
      [string_tag, null_tag, string_tag],
      [] of UInt8,
    ] of Array(UInt8)
    original_grid = CrystalClick::StorageOccurrenceGrid.new(
      [2_u64, 2_u64, 2_u64, 2_u64],
      [0_u64, 1_u64, 3_u64, 0_u64],
      w184c_binary_budget(true),
    )
    original = CrystalClick::DynamicDiscriminatorCodec.encode_child_site_with_budget(
      structure, tags, original_grid, w184c_binary_budget(true)
    )

    shifted_grid = CrystalClick::StorageOccurrenceGrid.new(
      [2_u64, 2_u64, 2_u64, 2_u64],
      [0_u64, 3_u64, 1_u64, 0_u64],
      w184c_binary_budget(true),
    )
    shifted_tags = [
      [] of UInt8,
      [string_tag, string_tag, string_tag],
      [null_tag],
      [] of UInt8,
    ] of Array(UInt8)
    shifted = CrystalClick::DynamicDiscriminatorCodec.encode_child_site_with_budget(
      structure, shifted_tags, shifted_grid, w184c_binary_budget(true)
    )
    original.marks.map(&.offset).should eq([8_u64, 8_u64, 9_u64, 12_u64, 12_u64])
    shifted.marks.map(&.offset).should eq([8_u64, 8_u64, 11_u64, 12_u64, 12_u64])
    original.marks[1].rows.should eq(1_u64)
    original.marks[2].rows.should eq(3_u64)
    shifted.marks[1].rows.should eq(3_u64)
    shifted.marks[2].rows.should eq(1_u64)

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicDiscriminatorCodec.decode_child_site_with_budget(
        structure,
        original,
        shifted_grid,
        w184c_binary_budget(false),
        first_mark: 0,
        mark_count: 0,
      )
    end

    object_streams = CrystalClick::ObjectDocumentCodec.encode_child_site_with_budget(
      plan,
      object_granules,
      object_grid,
      w184c_binary_budget(true),
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectDocumentCodec.decode_child_site_with_budget(
        typed_schema,
        object_streams,
        shifted_grid,
        w184c_binary_budget(false),
        first_mark: 0,
        mark_count: 0,
      )
    end

    zero_grid = CrystalClick::StorageOccurrenceGrid.new(
      [1_u64, 1_u64], [0_u64, 0_u64], w184c_binary_budget(true)
    )
    header_only = CrystalClick::DynamicDiscriminatorCodec.encode_child_site_with_budget(
      structure,
      [[] of UInt8, [] of UInt8] of Array(UInt8),
      zero_grid,
      w184c_binary_budget(true),
    )
    header_only.byte_size.should eq(8)
    header_only.marks.map(&.offset).should eq([8_u64, 8_u64, 8_u64])
    empty_schedules = CrystalClick::DynamicDiscriminatorCodec.decode_child_site_with_budget(
      structure, header_only, zero_grid, w184c_binary_budget(false)
    )
    empty_schedules.map(&.row_count).should eq([0, 0])
  end

  it "rejects missing, extra, or backwards terminal mark coordinates even for zero-mark selections" do
    structure = CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)
    grid = CrystalClick::StorageOccurrenceGrid.new(
      [2_u64, 2_u64], [0_u64, 1_u64], w184c_binary_budget(true)
    )
    header_and_tag = Bytes[0, 0, 0, 0, 0, 0, 0, 0, CrystalClick::DynamicDiscriminatorCodec::NULL_TAG]

    missing_terminal = CrystalClick::DynamicDiscriminatorStream.new(
      header_and_tag,
      [
        CrystalClick::DynamicDiscriminatorMark.new(8_u64, 0_u64),
        CrystalClick::DynamicDiscriminatorMark.new(8_u64, 0_u64),
      ] of CrystalClick::DynamicDiscriminatorMark,
    )
    extra_terminal = CrystalClick::DynamicDiscriminatorStream.new(
      header_and_tag,
      [
        CrystalClick::DynamicDiscriminatorMark.new(8_u64, 0_u64),
        CrystalClick::DynamicDiscriminatorMark.new(8_u64, 1_u64),
        CrystalClick::DynamicDiscriminatorMark.new(9_u64, 0_u64),
        CrystalClick::DynamicDiscriminatorMark.new(9_u64, 0_u64),
      ] of CrystalClick::DynamicDiscriminatorMark,
    )
    backwards_terminal = CrystalClick::DynamicDiscriminatorStream.new(
      header_and_tag,
      [
        CrystalClick::DynamicDiscriminatorMark.new(8_u64, 0_u64),
        CrystalClick::DynamicDiscriminatorMark.new(8_u64, 1_u64),
        CrystalClick::DynamicDiscriminatorMark.new(7_u64, 0_u64),
      ] of CrystalClick::DynamicDiscriminatorMark,
    )

    [missing_terminal, extra_terminal, backwards_terminal].each do |stream|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::DynamicDiscriminatorCodec.decode_child_site_with_budget(
          structure, stream, grid, w184c_binary_budget(false), first_mark: 0, mark_count: 0
        )
      end
    end

    string = CrystalClick::BinaryDataType.primitive("String")
    populated_structure = CrystalClick::DynamicStructure.new([string] of CrystalClick::BinaryDataType)
    compact = CrystalClick::DynamicValueCodec.encode(
      populated_structure,
      [[CrystalClick::BinaryValue.string("value")]] of Array(CrystalClick::BinaryValue),
      mode: CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE,
    )
    one_row_grid = CrystalClick::StorageOccurrenceGrid.new(
      [2_u64], [1_u64], w184c_binary_budget(true)
    )
    compact_child = CrystalClick::DynamicValueCodec.decode_child_site_with_budget(
      populated_structure, compact, one_row_grid, w184c_binary_budget(false)
    )
    compact_child.size.should eq(1)
    compact_child[0].size.should eq(1)
    compact_child[0][0].as_string.should eq("value")
    expect_raises(ArgumentError) do
      CrystalClick::DynamicDiscriminatorCodec.encode_child_site_with_budget(
        populated_structure,
        [[populated_structure.canonical_index_for(string).to_u8]] of Array(UInt8),
        one_row_grid,
        w184c_binary_budget(false),
      )
    end
    expect_raises(ArgumentError) do
      CrystalClick::DynamicDiscriminatorCodec.decode_child_site_with_budget(
        populated_structure,
        compact.discriminators,
        one_row_grid,
        w184c_binary_budget(true),
      )
    end
  end

  it "round trips an all-empty Object child grid while retaining parent typed and shared lanes" do
    typed_schema, plan, _grid, _write_budget, _granules = w184c_fixture
    empty_budget = w184c_binary_budget(true)
    empty_grid = CrystalClick::StorageOccurrenceGrid.new(
      [2_u64, 2_u64], [0_u64, 0_u64], empty_budget
    )
    empty = [] of CrystalClick::ObjectDocument
    empty_granules = [empty, empty] of Array(CrystalClick::ObjectDocument)
    streams = CrystalClick::ObjectDocumentCodec.encode_child_site_with_budget(
      plan, empty_granules, empty_grid, empty_budget
    )
    streams.rows_per_mark.should eq([0_u64, 0_u64])
    typed_data = streams.typed_for("t").stream("root.data")
    typed_data.offsets.should eq([0_u64, 0_u64, 0_u64])
    typed_data.byte_size.should eq(0)
    streams.shared.mark_count.should eq(2)
    streams.shared.roles.each do |role|
      shared_lane = streams.shared.stream(role)
      shared_lane.offsets.should eq([0_u64, 0_u64, 0_u64])
      shared_lane.byte_size.should eq(0)
    end
    discriminator_source = streams.dynamic_for("d").discriminators
    discriminator_source.byte_size.should eq(8)
    discriminator_source.bytes.should eq(Bytes[0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8])
    discriminator_source.marks.map(&.offset).should eq([8_u64, 8_u64, 8_u64])

    decoded = CrystalClick::ObjectDocumentCodec.decode_child_site_with_budget(
      typed_schema, streams, empty_grid, w184c_binary_budget(false)
    )
    decoded.map(&.size).should eq([0, 0])

    typed_lane = CrystalClick::ObjectDocumentColumnLane.new(
      "payload.t", typed_data.bytes, bulk_source: typed_data
    )
    discriminator_lane = CrystalClick::ObjectDocumentColumnLane.new(
      "payload.d.discriminators",
      discriminator_source.bytes,
      discriminator_source: discriminator_source,
      prefix_size: CrystalClick::DynamicDiscriminatorCodec::HEADER_BYTES.to_i,
    )
    typed_files = typed_lane.encode_child_site(
      empty_grid, 64, CrystalClick::CompressedStreamBudget.write_default
    )
    discriminator_files = discriminator_lane.encode_child_site(
      empty_grid, 64, CrystalClick::CompressedStreamBudget.write_default
    )

    w184c_with_parent do |parent|
      typed_data_path = File.join(parent, "empty-typed.bin")
      typed_marks_path = File.join(parent, "empty-typed.mrk2")
      File.open(typed_data_path, "wb") { |io| io.write(typed_files.data) }
      File.open(typed_marks_path, "wb") { |io| io.write(typed_files.marks) }
      typed_window = CrystalClick::CompressedMarkReader.read(
        typed_data_path,
        typed_marks_path,
        File.size(typed_data_path),
        File.size(typed_marks_path),
        first_mark: 0,
        mark_count: 2,
      )
      typed_window.bytes.should be_empty
      typed_window.offsets.should eq([0_u64, 0_u64, 0_u64])
      typed_window.rows_per_mark.should eq([2_u64, 2_u64])
      typed_grid = CrystalClick::CompressedMarkReader.inspect(
        typed_data_path,
        typed_marks_path,
        File.size(typed_data_path),
        File.size(typed_marks_path),
      )
      typed_grid.rows_per_mark.should eq([2_u64, 2_u64])
      typed_grid.positions.should eq([0_i64, 0_i64, 0_i64])

      discriminator_data_path = File.join(parent, "empty-dynamic.bin")
      discriminator_marks_path = File.join(parent, "empty-dynamic.mrk2")
      File.open(discriminator_data_path, "wb") { |io| io.write(discriminator_files.data) }
      File.open(discriminator_marks_path, "wb") { |io| io.write(discriminator_files.marks) }
      discriminator_window = CrystalClick::CompressedMarkReader.read(
        discriminator_data_path,
        discriminator_marks_path,
        File.size(discriminator_data_path),
        File.size(discriminator_marks_path),
        first_mark: 0,
        mark_count: 2,
        prefix_size: 8,
      )
      discriminator_window.bytes.should eq(Bytes[0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8])
      discriminator_window.offsets.should eq([8_u64, 8_u64, 8_u64])
      discriminator_window.rows_per_mark.should eq([2_u64, 2_u64])
      discriminator_grid = CrystalClick::CompressedMarkReader.inspect(
        discriminator_data_path,
        discriminator_marks_path,
        File.size(discriminator_data_path),
        File.size(discriminator_marks_path),
        prefix_size: 8,
      )
      discriminator_grid.rows_per_mark.should eq([2_u64, 2_u64])
      discriminator_grid.positions.should eq([8_i64, 8_i64, 8_i64])
    end
  end

  it "carries one borrowed budget through Object, Dynamic, and discriminator wrappers under a cumulative bound" do
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["d"] of String),
      {"d" => CrystalClick::DynamicStructure.new([
        CrystalClick::BinaryDataType.primitive("String"),
      ] of CrystalClick::BinaryDataType)},
    )
    plan = CrystalClick::ObjectDocumentPlan.new(
      structures,
      Hash(String, CrystalClick::BinaryDataType).new,
    )
    granules = [[CrystalClick::ObjectDocument.new({
      "d" => CrystalClick::BinaryValue.string("x"),
    })]] of Array(CrystalClick::ObjectDocument)

    baseline_budget = w184c_binary_budget(true)
    baseline_grid = CrystalClick::StorageOccurrenceGrid.new([2_u64], [1_u64], baseline_budget)
    discriminator_entry_nodes = 0_i64
    W184ChildOccurrenceProbe.begin
    begin
      CrystalClick::ObjectDocumentCodec.encode_child_site_with_budget(
        plan, granules, baseline_grid, baseline_budget
      )
      W184ChildOccurrenceProbe.budget_events.map(&.[0]).should eq(["object", "dynamic", "discriminator"])
      W184ChildOccurrenceProbe.budget_events.each do |event|
        event[1].same?(baseline_budget).should be_true
      end
      discriminator_entry_nodes = W184ChildOccurrenceProbe.budget_events.last[2]
    ensure
      W184ChildOccurrenceProbe.finish
    end

    # At discriminator entry, the repeated complete-grid validation and the
    # discriminator's own minimum work require six additional nodes in total.
    # Allow five: Dynamic's preflight passes, but discriminator work cannot be
    # charged. A nested fresh budget would evade this cumulative refusal.
    limits = CrystalClick::BinaryCodecLimits.new(
      max_depth: 64,
      max_nodes: (discriminator_entry_nodes + 5_i64).to_u64,
      max_elements: 1_000,
      max_bytes: 64 * 1024,
    )
    budget = CrystalClick::BinaryCodecBudget.new(limits, true)
    grid = CrystalClick::StorageOccurrenceGrid.new([2_u64], [1_u64], budget)
    W184ChildOccurrenceProbe.begin
    begin
      error = expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentCodec.encode_child_site_with_budget(
          plan, granules, grid, budget
        )
      end
      error.message.should eq("binary codec node limit exceeded")
      W184ChildOccurrenceProbe.budget_events.map(&.[0]).should eq(["object", "dynamic", "discriminator"])
      W184ChildOccurrenceProbe.budget_events.each do |event|
        event[1].same?(budget).should be_true
      end
      budget.node_count.should eq(discriminator_entry_nodes + 2_i64)
    ensure
      W184ChildOccurrenceProbe.finish
    end
  end

  it "reopens child typed and Dynamic lanes through the compressed paired reader with physical parent rows" do
    typed_schema, plan, grid, write_budget, granules = w184c_fixture
    streams = CrystalClick::ObjectDocumentCodec.encode_child_site_with_budget(plan, granules, grid, write_budget)
    typed_source = streams.typed_for("t").stream("root.data")
    discriminator_source = streams.dynamic_for("d").discriminators
    typed_lane = CrystalClick::ObjectDocumentColumnLane.new(
      "payload.t", typed_source.bytes, bulk_source: typed_source
    )
    discriminator_lane = CrystalClick::ObjectDocumentColumnLane.new(
      "payload.d.discriminators",
      discriminator_source.bytes,
      discriminator_source: discriminator_source,
      prefix_size: CrystalClick::DynamicDiscriminatorCodec::HEADER_BYTES.to_i,
    )

    typed_files = typed_lane.encode_child_site(
      grid, 64, CrystalClick::CompressedStreamBudget.write_default
    )
    discriminator_files = discriminator_lane.encode_child_site(
      grid, 64, CrystalClick::CompressedStreamBudget.write_default
    )
    w184c_with_parent do |parent|
      typed_data = File.join(parent, "typed.bin")
      typed_marks = File.join(parent, "typed.mrk2")
      File.open(typed_data, "wb") { |io| io.write(typed_files.data) }
      File.open(typed_marks, "wb") { |io| io.write(typed_files.marks) }
      typed_window = CrystalClick::CompressedMarkReader.read(
        typed_data,
        typed_marks,
        File.size(typed_data),
        File.size(typed_marks),
        first_mark: 2,
        mark_count: 2,
      )
      typed_window.bytes.should eq(Bytes[11_u8, 13_u8, 17_u8])
      typed_window.offsets.should eq([0_u64, 3_u64, 3_u64])
      typed_window.rows_per_mark.should eq([2_u64, 2_u64])
      typed_grid = CrystalClick::CompressedMarkReader.inspect(
        typed_data,
        typed_marks,
        File.size(typed_data),
        File.size(typed_marks),
      )
      typed_grid.mark_count.should eq(4)
      typed_grid.rows_per_mark.should eq([2_u64, 2_u64, 2_u64, 2_u64])

      dynamic_data = File.join(parent, "dynamic.bin")
      dynamic_marks = File.join(parent, "dynamic.mrk2")
      File.open(dynamic_data, "wb") { |io| io.write(discriminator_files.data) }
      File.open(dynamic_marks, "wb") { |io| io.write(discriminator_files.marks) }
      dynamic_window = CrystalClick::CompressedMarkReader.read(
        dynamic_data,
        dynamic_marks,
        File.size(dynamic_data),
        File.size(dynamic_marks),
        first_mark: 2,
        mark_count: 2,
        prefix_size: 8,
      )
      string_tag = plan.structures.dynamic_for("d").canonical_index_for(
        CrystalClick::BinaryDataType.primitive("String")
      ).to_u8
      dynamic_window.bytes.should eq(Bytes[0, 0, 0, 0, 0, 0, 0, 0, string_tag, 255_u8, string_tag])
      dynamic_window.offsets.should eq([8_u64, 11_u64, 11_u64])
      dynamic_window.rows_per_mark.should eq([2_u64, 2_u64])
      dynamic_grid = CrystalClick::CompressedMarkReader.inspect(
        dynamic_data,
        dynamic_marks,
        File.size(dynamic_data),
        File.size(dynamic_marks),
        prefix_size: 8,
      )
      dynamic_grid.mark_count.should eq(4)
      dynamic_grid.rows_per_mark.should eq([2_u64, 2_u64, 2_u64, 2_u64])
    end
  end

  it "preflights a transformed Variant prefix lane before adapting bytes and leaves the root guard closed" do
    typed_schema, plan, _grid, _write_budget, granules = w184c_fixture
    root_error = expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentCodec.encode_with_budget(
        plan,
        granules,
        w184c_binary_budget(true),
        mode: CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
      )
    end
    root_error.message.should eq("Object document real marks must contain at least one row")

    _schema, child_plan, child_grid, child_budget, child_granules = w184c_fixture
    typed_dynamic_streams = CrystalClick::ObjectDocumentCodec.encode_child_site_with_budget(
      child_plan,
      child_granules,
      child_grid,
      child_budget,
      mode: CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE,
    )
    typed_dynamic_streams.typed_dynamic_mode.should eq(CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE)

    source = CrystalClick::BinaryBulkStream.new(Bytes[0xaa_u8, 0xbb_u8], [0_u64, 2_u64])
    variant_lane = CrystalClick::ObjectDocumentColumnLane.new(
      "payload.root.discriminators",
      source.bytes,
      bulk_source: source,
      prefix_size: 8,
      variant_prefix_role: "root.discriminators",
    )
    variant_lane.byte_size.should eq(10)
    child_grid = CrystalClick::StorageOccurrenceGrid.new(
      [2_u64], [2_u64], w184c_binary_budget(true)
    )
    limits = CrystalClick::CompressedStreamLimits.new(max_decoded_bytes: 9)
    transport_budget = CrystalClick::CompressedStreamBudget.new(limits, true)
    W184ChildOccurrenceProbe.begin
    begin
      error = expect_raises(CrystalClick::UnsupportedFormatError) do
        variant_lane.encode_child_site(child_grid, 64, transport_budget)
      end
      error.message.should eq("compressed stream decoded-byte limit exceeded")
      W184ChildOccurrenceProbe.prefix_adapter_calls.should eq(0)
      transport_budget.decoded_byte_count.should eq(0_i64)
      transport_budget.record_count.should eq(0_i64)
      transport_budget.file_byte_count.should eq(0_i64)
      transport_budget.result_byte_count.should eq(0_i64)

      positive_budget = CrystalClick::CompressedStreamBudget.write_default
      variant_lane.encode_child_site(child_grid, 64, positive_budget)
      W184ChildOccurrenceProbe.prefix_adapter_calls.should eq(1)
    ensure
      W184ChildOccurrenceProbe.finish
    end
  end
end
