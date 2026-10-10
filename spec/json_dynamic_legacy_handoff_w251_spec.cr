require "./spec_helper"

alias W251LegacyJsonFixture = NamedTuple(
  type: CrystalClick::BinaryDataType,
  structures: Hash(String, CrystalClick::DynamicStructure),
  granules: Array(Array(CrystalClick::BinaryValue)),
  plans: Array(Tuple(String, Int32, CrystalClick::ObjectDocumentPlan)),
  json_used: CrystalClick::BinaryDataType,
  json_unused: CrystalClick::BinaryDataType,
)

private def w251_json_type(max_dynamic_types : Int) : CrystalClick::BinaryDataType
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  nullable_uint8 = CrystalClick::BinaryDataType.nullable(uint8)
  CrystalClick::BinaryDataType.json(
    max_dynamic_paths: 1,
    max_dynamic_types: max_dynamic_types,
    typed_paths: {
      "id"    => uint8,
      "maybe" => nullable_uint8,
    } of String => CrystalClick::BinaryDataType,
  )
end

private def w251_json_value(
  json_type : CrystalClick::BinaryDataType,
  id : UInt8,
  counter : UInt64,
) : CrystalClick::BinaryValue
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  nullable_uint8 = CrystalClick::BinaryDataType.nullable(uint8)
  row = CrystalClick::BinaryJsonRow.new(
    json_type,
    [
      {"id", CrystalClick::BinaryValue.fixed(uint8, Bytes[id])},
      {"maybe", CrystalClick::BinaryValue.null(nullable_uint8)},
      {"counter", CrystalClick::BinaryValue.uint64(counter)},
    ] of Tuple(String, CrystalClick::BinaryValue),
  )
  CrystalClick::BinaryValue.json(json_type, row)
end

private def w251_dynamic_structure(
  types : Array(CrystalClick::BinaryDataType),
  counts_by_name : Hash(String, UInt64),
  version : UInt64,
) : CrystalClick::DynamicStructure
  names = types.map(&.name)
  names << CrystalClick::DynamicStructure::SHARED_VARIANT_NAME
  names.sort!
  unless counts_by_name.size == names.size
    raise ArgumentError.new("W251 expected one count for every canonical Dynamic arm")
  end
  counts = names.map { |name| counts_by_name[name] }
  statistics = CrystalClick::StructureStatistics.new(
    counts,
    [] of CrystalClick::StructureStatistic,
  )
  if version == CrystalClick::DynamicStructure::VERSION_V1
    CrystalClick::DynamicStructure.new(
      types,
      statistics,
      version: version,
      legacy_max_dynamic_types: types.size.to_u64,
    )
  else
    CrystalClick::DynamicStructure.new(types, statistics, version: version)
  end
end

private def w251_object_plan(
  json_type : CrystalClick::BinaryDataType,
  version : UInt64,
  counter_rows : UInt64,
) : CrystalClick::ObjectDocumentPlan
  uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
  counter_structure = w251_dynamic_structure(
    [uint64] of CrystalClick::BinaryDataType,
    {
      "SharedVariant" => 0_u64,
      "UInt64"        => counter_rows,
    } of String => UInt64,
    version,
  )
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new(["counter"] of String),
    {"counter" => counter_structure},
  )
  CrystalClick::ObjectDocumentPlan.new(
    structures,
    json_type.json_type.not_nil!.typed_paths,
  )
end

private def w251_fixture(version : UInt64) : W251LegacyJsonFixture
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  dynamic = CrystalClick::BinaryDataType.dynamic(3)
  array = CrystalClick::BinaryDataType.array(dynamic)
  json_used = w251_json_type(1)
  json_unused = w251_json_type(2)
  site = "root.elements"
  types = [json_used, json_unused, uint8] of CrystalClick::BinaryDataType
  root_counts = {
    json_used.name   => 2_u64,
    json_unused.name => 0_u64,
    "SharedVariant"  => 0_u64,
    "UInt8"          => 3_u64,
  } of String => UInt64
  root_structure = w251_dynamic_structure(types, root_counts, version)
  structures = {site => root_structure}
  used_index = root_structure.canonical_index_for(json_used)
  unused_index = root_structure.canonical_index_for(json_unused)
  plans = [
    {site, used_index, w251_object_plan(json_used, version, 2_u64)},
    {site, unused_index, w251_object_plan(json_unused, version, 0_u64)},
  ] of Tuple(String, Int32, CrystalClick::ObjectDocumentPlan)

  empty = CrystalClick::BinaryValue.array(array, [] of CrystalClick::BinaryValue)
  two_uint8 = CrystalClick::BinaryValue.array(array, [
    CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.fixed(uint8, Bytes[17_u8])),
    CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.fixed(uint8, Bytes[18_u8])),
  ] of CrystalClick::BinaryValue)
  one_uint8 = CrystalClick::BinaryValue.array(array, [
    CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.fixed(uint8, Bytes[19_u8])),
  ] of CrystalClick::BinaryValue)
  first_json = CrystalClick::BinaryValue.array(array, [
    CrystalClick::BinaryValue.dynamic(dynamic, w251_json_value(json_used, 41_u8, 401_u64)),
  ] of CrystalClick::BinaryValue)
  second_json = CrystalClick::BinaryValue.array(array, [
    CrystalClick::BinaryValue.dynamic(dynamic, w251_json_value(json_used, 42_u8, 402_u64)),
  ] of CrystalClick::BinaryValue)
  granules = [
    [empty, empty] of CrystalClick::BinaryValue,
    [two_uint8, one_uint8] of CrystalClick::BinaryValue,
    [first_json, second_json] of CrystalClick::BinaryValue,
  ] of Array(CrystalClick::BinaryValue)

  {
    type:        array,
    structures:  structures,
    granules:    granules,
    plans:       plans,
    json_used:   json_used,
    json_unused: json_unused,
  }
end

private def w251_assert_structure_metadata(
  structure : CrystalClick::DynamicStructure,
  version : UInt64,
  expected_counts : Hash(String, UInt64),
) : Nil
  structure.version.should eq(version)
  structure.statistics.not_nil!.counts.should eq(
    structure.canonical_variant_names.map { |name| expected_counts[name] },
  )
  if version == CrystalClick::DynamicStructure::VERSION_V1
    structure.legacy_max_dynamic_types.should eq(structure.type_count.to_u64)
  else
    structure.legacy_max_dynamic_types.should be_nil
  end
  nil
end

private def w251_actual_signature(dynamic : CrystalClick::BinaryValue) : String
  return "null" if dynamic.is_null?

  actual = dynamic.child_at(0)
  if actual.type.tag == CrystalClick::BinaryDataType::TAG_JSON
    row = actual.json_row
    id = row.value_for("id").not_nil!.byte_at(0)
    maybe = row.value_for("maybe").not_nil!
    maybe_text = maybe.is_null? ? "null" : maybe.child_at(0).byte_at(0).to_s
    counter = row.value_for("counter").not_nil!
    "json:#{id}:#{maybe_text}:counter=#{counter.as_uint64}"
  else
    "u8:#{actual.byte_at(0)}"
  end
end

private def w251_array_signature(value : CrystalClick::BinaryValue) : String
  "[#{value.elements.map { |dynamic| w251_actual_signature(dynamic) }.join(",")}]"
end

private def w251_expected_signatures : Array(Array(String))
  [
    ["[]", "[]"] of String,
    ["[u8:17,u8:18]", "[u8:19]"] of String,
    ["[json:41:null:counter=401]", "[json:42:null:counter=402]"] of String,
  ] of Array(String)
end

private def w251_assert_reads(part : String, fixture : W251LegacyJsonFixture) : Nil
  expected = w251_expected_signatures
  reader = CrystalClick::DynamicBulkColumnReader.open(part, "payload", fixture[:type])
  reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64])
  reader.read_marks(0, reader.mark_count).map do |mark|
    mark.map { |value| w251_array_signature(value) }
  end.should eq(expected)
  reader.read_marks(1, 1).map do |mark|
    mark.map { |value| w251_array_signature(value) }
  end.should eq([expected[1]])
  reader.read_marks(reader.mark_count, 0).should be_empty

  table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
  table_rows = [] of Array(String)
  table.scan_typed_candidate_marks([[0, 1, 2]]) do |batch|
    table_rows << batch.dynamic_bulk_values_for("payload").map do |value|
      w251_array_signature(value)
    end.to_a
  end
  table_rows.should eq(expected)
  nil
end

private def w251_write_part(
  part : String,
  fixture : W251LegacyJsonFixture,
  profile : CrystalClick::BinaryBulkProfile,
) : Nil
  CrystalClick::WidePartWriter.write_uint64_dynamic_bulk_part(
    part,
    "pk",
    Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64],
    "payload",
    fixture[:type],
    fixture[:structures],
    fixture[:granules],
    rows_per_mark: 2,
    profile: profile,
    json_object_plans: fixture[:plans],
  ).should eq(part)
  nil
end

private def w251_unused_child_data_path(
  part : String,
  fixture : W251LegacyJsonFixture,
  profile : CrystalClick::BinaryBulkProfile,
) : String
  plan = CrystalClick::BinaryDynamicBulkPlan.new_with_budget(
    fixture[:type],
    fixture[:structures],
    CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true),
    profile,
    json_object_plans: fixture[:plans],
  )
  physical = CrystalClick::BinaryDynamicBulkPhysicalPlan.new(plan, "payload")
  structure = fixture[:structures]["root.elements"]
  unused_index = structure.canonical_index_for(fixture[:json_unused])
  unused_site = physical.json_object_site("root.elements", unused_index)
  child_name = unused_site.physical_plan.stream_names.find do |name|
    name.ends_with?("object_structure")
  end.not_nil!
  File.join(part, "#{CrystalClick::StreamName.hash(child_name)}.bin")
end

private def w251_run_guards_for_pair(
  version : UInt64,
  profile : CrystalClick::BinaryBulkProfile,
  label : String,
) : Nil
  fixture = w251_fixture(version)
  expected_parent_counts = {
    fixture[:json_used].name   => 2_u64,
    fixture[:json_unused].name => 0_u64,
    "SharedVariant"            => 0_u64,
    "UInt8"                    => 3_u64,
  } of String => UInt64
  root_structure = fixture[:structures]["root.elements"]
  w251_assert_structure_metadata(root_structure, version, expected_parent_counts)
  fixture[:plans].each do |binding|
    expected_counter_rows = binding[1] == root_structure.canonical_index_for(fixture[:json_used]) ? 2_u64 : 0_u64
    child_structure = binding[2].structures.dynamic_for("counter")
    w251_assert_structure_metadata(child_structure, version, {
      "SharedVariant" => 0_u64,
      "UInt64"        => expected_counter_rows,
    } of String => UInt64)
  end

  parent = File.tempname("crystal-click-w251-legacy-json-#{label}-")
  Dir.mkdir(parent)
  begin
    valid_parent = File.join(parent, "valid")
    missing_parent = File.join(parent, "missing")
    unbound_parent = File.join(parent, "unbound")
    Dir.mkdir(valid_parent)
    Dir.mkdir(missing_parent)
    Dir.mkdir(unbound_parent)

    # First prove that complete old-version metadata and the fixed
    # Array(Dynamic) JSON values really publish and read in this profile.
    part = File.join(valid_parent, "all_1_1_0")
    w251_write_part(part, fixture, profile)
    w251_assert_reads(part, fixture)
    reader = CrystalClick::DynamicBulkColumnReader.open(part, "payload", fixture[:type])
    table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])

    # A declared but unused JSON arm still owns its child binding. Omitting it
    # must fail before either a destination or staging entry is exposed.
    unbound_destination = File.join(unbound_parent, "all_1_1_0")
    unused_index = root_structure.canonical_index_for(fixture[:json_unused])
    incomplete_plans = fixture[:plans].reject do |binding|
      binding[0] == "root.elements" && binding[1] == unused_index
    end
    expect_raises(ArgumentError) do
      CrystalClick::WidePartWriter.write_uint64_dynamic_bulk_part(
        unbound_destination,
        "pk",
        Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64],
        "payload",
        fixture[:type],
        fixture[:structures],
        fixture[:granules],
        rows_per_mark: 2,
        profile: profile,
        json_object_plans: incomplete_plans,
      )
    end
    File.exists?(unbound_destination).should be_false
    Dir.children(unbound_parent).should be_empty

    child_path = w251_unused_child_data_path(part, fixture, profile)
    bytes = File.read(child_path).to_slice.dup
    raise "W251 unused Object child file is unexpectedly empty" if bytes.empty?
    bytes[0] = bytes[0] ^ 0xff_u8
    File.write(child_path, bytes)

    callbacks = 0
    expect_raises(CrystalClick::CorruptPartError) do
      table.scan_typed_candidate_marks([[] of Int32]) do |batch|
        callbacks += 1
        batch.dynamic_bulk_values_for("payload")
      end
    end
    callbacks.should eq(0)

    expect_raises(CrystalClick::CorruptPartError) do
      table.scan_typed_window(table.total_row_count, 1) do |_batch|
        callbacks += 1
      end
    end
    callbacks.should eq(0)

    expect_raises(CrystalClick::CorruptPartError) do
      reader.read_marks(reader.mark_count, 0)
    end

    # Missing bytes for the same unused binding are rejected during open,
    # after a separate valid write/read proves the old version itself works.
    missing_part = File.join(missing_parent, "all_1_1_0")
    w251_write_part(missing_part, fixture, profile)
    w251_assert_reads(missing_part, fixture)
    File.delete(w251_unused_child_data_path(missing_part, fixture, profile))
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicBulkColumnReader.open(missing_part, "payload", fixture[:type])
    end
  ensure
    FileUtils.rm_rf(parent)
  end
  nil
end

describe "W251 complete V1/V2 Dynamic JSON physical handoff" do
  it "reads and guards V1 single-stream Dynamic structures with complete statistics" do
    w251_run_guards_for_pair(
      CrystalClick::DynamicStructure::VERSION_V1,
      CrystalClick::BinaryBulkProfile.single_stream,
      "v1-single",
    )
  end

  it "reads and guards V2 sized-stream Dynamic structures with complete statistics" do
    w251_run_guards_for_pair(
      CrystalClick::DynamicStructure::VERSION_V2,
      CrystalClick::BinaryBulkProfile.with_size_stream,
      "v2-sized",
    )
  end
end
