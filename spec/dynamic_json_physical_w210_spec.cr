require "./spec_helper"
require "file_utils"

alias W210Fixture = NamedTuple(
  type: CrystalClick::BinaryDataType,
  structures: Hash(String, CrystalClick::DynamicStructure),
  granules: Array(Array(CrystalClick::BinaryValue)),
  plans: Array(Tuple(String, Int32, CrystalClick::ObjectDocumentPlan)),
  json_used: CrystalClick::BinaryDataType,
  json_unused: CrystalClick::BinaryDataType,
)

alias W210RecursiveFixture = NamedTuple(
  schema: CrystalClick::StorageColumnSchema,
  object_plans: Hash(String, CrystalClick::ObjectDocumentPlan),
  dynamic_plans: Hash(String, CrystalClick::BinaryDynamicBulkPlan),
  granules: Array(Array(CrystalClick::StorageColumnValue)),
  json_used: CrystalClick::BinaryDataType,
  json_unused: CrystalClick::BinaryDataType,
)

private def w210_json_type(max_dynamic_types : Int) : CrystalClick::BinaryDataType
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

private def w210_object_plan(json_type : CrystalClick::BinaryDataType) : CrystalClick::ObjectDocumentPlan
  uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new(["counter"] of String),
    {"counter" => CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType)},
  )
  CrystalClick::ObjectDocumentPlan.new(
    structures,
    json_type.json_type.not_nil!.typed_paths,
  )
end

private def w210_wrong_typed_object_plan(json_type : CrystalClick::BinaryDataType) : CrystalClick::ObjectDocumentPlan
  valid = w210_object_plan(json_type)
  typed_paths = json_type.json_type.not_nil!.typed_paths
  typed_paths["id"] = CrystalClick::BinaryDataType.primitive("UInt16")
  CrystalClick::ObjectDocumentPlan.new(valid.structures, typed_paths)
end

private def w210_json_value(
  json_type : CrystalClick::BinaryDataType,
  id : UInt8,
  counter : UInt64,
  dynamic_path : String = "counter",
  maybe_value : UInt8? = nil,
) : CrystalClick::BinaryValue
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  nullable_uint8 = CrystalClick::BinaryDataType.nullable(uint8)
  maybe = if value = maybe_value
            CrystalClick::BinaryValue.nullable(nullable_uint8, CrystalClick::BinaryValue.fixed(uint8, Bytes[value]))
          else
            CrystalClick::BinaryValue.null(nullable_uint8)
          end
  row = CrystalClick::BinaryJsonRow.new(
    json_type,
    [
      {"id", CrystalClick::BinaryValue.fixed(uint8, Bytes[id])},
      {"maybe", maybe},
      {dynamic_path, CrystalClick::BinaryValue.uint64(counter)},
    ] of Tuple(String, CrystalClick::BinaryValue),
  )
  CrystalClick::BinaryValue.json(json_type, row)
end

private def w210_document(
  id : UInt8,
  maybe_value : UInt8? = nil,
) : CrystalClick::ObjectDocument
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  nullable_uint8 = CrystalClick::BinaryDataType.nullable(uint8)
  maybe = if value = maybe_value
            CrystalClick::BinaryValue.nullable(nullable_uint8, CrystalClick::BinaryValue.fixed(uint8, Bytes[value]))
          else
            CrystalClick::BinaryValue.null(nullable_uint8)
          end
  CrystalClick::ObjectDocument.new({
    "id"    => CrystalClick::BinaryValue.fixed(uint8, Bytes[id]),
    "maybe" => maybe,
  } of String => CrystalClick::BinaryValue)
end

private def w210_actual_signature(value : CrystalClick::BinaryValue) : String
  if value.is_null?
    return "null"
  end
  actual = value.child_at(0)
  if actual.type.tag == CrystalClick::BinaryDataType::TAG_JSON
    row = actual.json_row
    id = row.value_for("id").not_nil!.byte_at(0)
    maybe = row.value_for("maybe").not_nil!
    maybe_text = maybe.is_null? ? "null" : maybe.child_at(0).byte_at(0).to_s
    counter = row.value_for("counter").not_nil!
    unless counter.type == CrystalClick::BinaryDataType.primitive("UInt64")
      raise "W210 expected JSON path `counter` to have UInt64 type"
    end
    "json:#{id}:#{maybe_text}:counter=#{counter.as_uint64}"
  else
    "u8:#{actual.byte_at(0)}"
  end
end

private def w210_direct_signature(value : CrystalClick::BinaryValue) : String
  "[#{value.elements.map { |dynamic| w210_actual_signature(dynamic) }.join(",")}]"
end

private def w210_recursive_signature(value : CrystalClick::StorageColumnValue) : String
  id = value.child_at(0).object_document.value_for("id").byte_at(0)
  array = value.child_at(1)
  elements = array.bulk_value.elements.map do |dynamic|
    w210_actual_signature(dynamic)
  end
  "#{id}:[#{elements.join(",")}]"
end

private def w210_qzero_recursive_signature(value : CrystalClick::StorageColumnValue) : String
  elements = value.array_values.map do |tuple|
    id = tuple.child_at(0).object_document.value_for("id").byte_at(0)
    "#{id}:#{w210_actual_signature(tuple.child_at(1).bulk_value)}"
  end
  "[#{elements.join(",")}]"
end

private def w210_object_structure_stream(names : Array(String)) : String
  names.find(&.ends_with?("object_structure")).not_nil!
end

private def w210_recursive_fixture : W210RecursiveFixture
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  dynamic = CrystalClick::BinaryDataType.dynamic(3)
  array = CrystalClick::BinaryDataType.array(dynamic)
  json_used = w210_json_type(1)
  json_unused = w210_json_type(2)
  structure = CrystalClick::DynamicStructure.new(
    [json_used, json_unused, uint8] of CrystalClick::BinaryDataType,
  )
  used_index = structure.canonical_index_for(json_used)
  unused_index = structure.canonical_index_for(json_unused)
  dynamic_object_plans = [
    {"root.elements", used_index, w210_object_plan(json_used)},
    {"root.elements", unused_index, w210_object_plan(json_unused)},
  ] of Tuple(String, Int32, CrystalClick::ObjectDocumentPlan)
  limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
  dynamic_plan = CrystalClick::BinaryDynamicBulkPlan.new_with_budget(
    array,
    {"root.elements" => structure},
    CrystalClick::BinaryCodecBudget.new(limits, true),
    json_object_plans: dynamic_object_plans,
  )

  schema = CrystalClick::StorageColumnSchema.parse(
    "Tuple(doc JSON(id UInt8, maybe Nullable(UInt8)), rows Array(Dynamic(max_types=3)))"
  )
  nominal_json = CrystalClick::ObjectDocumentSchema.parse_declaration(
    "JSON(id UInt8, maybe Nullable(UInt8))"
  )
  nominal_plan = CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    ),
    nominal_json.typed_paths,
  )
  object_plans = {"root/tuple[0]" => nominal_plan}
  dynamic_plans = {"root/tuple[1]" => dynamic_plan}

  tuple_value = ->(id : UInt8, elements : Array(CrystalClick::BinaryValue)) {
    CrystalClick::StorageColumnValue.tuple([
      CrystalClick::StorageColumnValue.object_document(w210_document(id)),
      CrystalClick::StorageColumnValue.bulk(CrystalClick::BinaryValue.array(array, elements)),
    ] of CrystalClick::StorageColumnValue)
  }
  empty = [] of CrystalClick::BinaryValue
  mark0 = [
    tuple_value.call(1_u8, empty),
    tuple_value.call(2_u8, empty),
  ] of CrystalClick::StorageColumnValue
  mark1 = [
    tuple_value.call(3_u8, [
      CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.fixed(uint8, Bytes[17_u8])),
      CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.fixed(uint8, Bytes[18_u8])),
    ] of CrystalClick::BinaryValue),
    tuple_value.call(4_u8, [
      CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.fixed(uint8, Bytes[19_u8])),
    ] of CrystalClick::BinaryValue),
  ] of CrystalClick::StorageColumnValue
  mark2 = [
    tuple_value.call(5_u8, [
      CrystalClick::BinaryValue.dynamic(dynamic, w210_json_value(json_used, 41_u8, 401_u64)),
    ] of CrystalClick::BinaryValue),
    tuple_value.call(6_u8, [
      CrystalClick::BinaryValue.dynamic(dynamic, w210_json_value(json_used, 42_u8, 402_u64)),
    ] of CrystalClick::BinaryValue),
  ] of CrystalClick::StorageColumnValue
  {
    schema:        schema,
    object_plans:  object_plans,
    dynamic_plans: dynamic_plans,
    granules:      [mark0, mark1, mark2],
    json_used:     json_used,
    json_unused:   json_unused,
  }
end

private def w210_qzero_recursive_fixture(
  limits : CrystalClick::BinaryCodecLimits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
) : W210RecursiveFixture
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  dynamic = CrystalClick::BinaryDataType.dynamic(3)
  json_used = w210_json_type(1)
  json_unused = w210_json_type(2)
  structure = CrystalClick::DynamicStructure.new(
    [json_used, json_unused, uint8] of CrystalClick::BinaryDataType,
  )
  used_index = structure.canonical_index_for(json_used)
  unused_index = structure.canonical_index_for(json_unused)
  dynamic_object_plans = [
    {"root", used_index, w210_object_plan(json_used)},
    {"root", unused_index, w210_object_plan(json_unused)},
  ] of Tuple(String, Int32, CrystalClick::ObjectDocumentPlan)
  dynamic_plan = CrystalClick::BinaryDynamicBulkPlan.new_with_budget(
    dynamic,
    {"root" => structure},
    CrystalClick::BinaryCodecBudget.new(limits, true),
    json_object_plans: dynamic_object_plans,
  )

  declaration = "Array(Tuple(doc JSON(id UInt8, maybe Nullable(UInt8)), value Dynamic(max_types=3)))"
  schema = CrystalClick::StorageColumnSchema.parse(declaration, limits)
  nominal_json = CrystalClick::ObjectDocumentSchema.parse_declaration(
    "JSON(id UInt8, maybe Nullable(UInt8))", limits
  )
  nominal_plan = CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    ),
    nominal_json.typed_paths,
  )
  object_plans = {"root/array[0]/tuple[0]" => nominal_plan}
  dynamic_plans = {"root/array[0]/tuple[1]" => dynamic_plan}

  tuple_value = ->(id : UInt8, dynamic_value : CrystalClick::BinaryValue) {
    CrystalClick::StorageColumnValue.tuple([
      CrystalClick::StorageColumnValue.object_document(w210_document(id)),
      CrystalClick::StorageColumnValue.bulk(dynamic_value),
    ] of CrystalClick::StorageColumnValue)
  }
  array_value = ->(elements : Array(CrystalClick::StorageColumnValue)) {
    CrystalClick::StorageColumnValue.array(elements)
  }
  mark0 = [
    array_value.call([] of CrystalClick::StorageColumnValue),
    array_value.call([] of CrystalClick::StorageColumnValue),
  ] of CrystalClick::StorageColumnValue
  mark1 = [
    array_value.call([
      tuple_value.call(3_u8, CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.fixed(uint8, Bytes[17_u8]))),
      tuple_value.call(4_u8, CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.fixed(uint8, Bytes[18_u8]))),
    ] of CrystalClick::StorageColumnValue),
    array_value.call([
      tuple_value.call(5_u8, CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.fixed(uint8, Bytes[19_u8]))),
    ] of CrystalClick::StorageColumnValue),
  ] of CrystalClick::StorageColumnValue
  mark2 = [
    array_value.call([
      tuple_value.call(6_u8, CrystalClick::BinaryValue.dynamic(dynamic, w210_json_value(json_used, 61_u8, 601_u64))),
    ] of CrystalClick::StorageColumnValue),
    array_value.call([
      tuple_value.call(7_u8, CrystalClick::BinaryValue.dynamic(dynamic, w210_json_value(json_used, 62_u8, 602_u64))),
    ] of CrystalClick::StorageColumnValue),
  ] of CrystalClick::StorageColumnValue
  {
    schema:        schema,
    object_plans:  object_plans,
    dynamic_plans: dynamic_plans,
    granules:      [mark0, mark1, mark2],
    json_used:     json_used,
    json_unused:   json_unused,
  }
end

private def w210_fixture : W210Fixture
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  dynamic = CrystalClick::BinaryDataType.dynamic(3)
  array = CrystalClick::BinaryDataType.array(dynamic)
  json_used = w210_json_type(1)
  json_unused = w210_json_type(2)
  structure = CrystalClick::DynamicStructure.new(
    [json_used, json_unused, uint8] of CrystalClick::BinaryDataType,
  )
  site = "root.elements"
  structures = {site => structure}
  used_index = structure.canonical_index_for(json_used)
  unused_index = structure.canonical_index_for(json_unused)
  plans = [
    {site, used_index, w210_object_plan(json_used)},
    {site, unused_index, w210_object_plan(json_unused)},
  ] of Tuple(String, Int32, CrystalClick::ObjectDocumentPlan)

  empty = CrystalClick::BinaryValue.array(array, [] of CrystalClick::BinaryValue)
  three_uint8 = CrystalClick::BinaryValue.array(array, [
    CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.fixed(uint8, Bytes[17_u8])),
    CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.fixed(uint8, Bytes[18_u8])),
  ] of CrystalClick::BinaryValue)
  one_uint8 = CrystalClick::BinaryValue.array(array, [
    CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.fixed(uint8, Bytes[19_u8])),
  ] of CrystalClick::BinaryValue)
  first_json = CrystalClick::BinaryValue.array(array, [
    CrystalClick::BinaryValue.dynamic(dynamic, w210_json_value(json_used, 41_u8, 401_u64)),
  ] of CrystalClick::BinaryValue)
  second_json = CrystalClick::BinaryValue.array(array, [
    CrystalClick::BinaryValue.dynamic(dynamic, w210_json_value(json_used, 42_u8, 402_u64)),
  ] of CrystalClick::BinaryValue)
  granules = [
    [empty, empty] of CrystalClick::BinaryValue,
    [three_uint8, one_uint8] of CrystalClick::BinaryValue,
    [first_json, second_json] of CrystalClick::BinaryValue,
  ] of Array(CrystalClick::BinaryValue)

  {type: array, structures: structures, granules: granules, plans: plans, json_used: json_used, json_unused: json_unused}
end

private def w210_root_fixture : W210Fixture
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  dynamic = CrystalClick::BinaryDataType.dynamic(3)
  json_used = w210_json_type(1)
  json_unused = w210_json_type(2)
  structure = CrystalClick::DynamicStructure.new(
    [json_used, json_unused, uint8] of CrystalClick::BinaryDataType,
  )
  used_index = structure.canonical_index_for(json_used)
  unused_index = structure.canonical_index_for(json_unused)
  plans = [
    {"root", used_index, w210_object_plan(json_used)},
    {"root", unused_index, w210_object_plan(json_unused)},
  ] of Tuple(String, Int32, CrystalClick::ObjectDocumentPlan)
  granules = [
    [
      CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.fixed(uint8, Bytes[17_u8])),
      CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.fixed(uint8, Bytes[18_u8])),
    ] of CrystalClick::BinaryValue,
    [
      CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.fixed(uint8, Bytes[19_u8])),
      CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.fixed(uint8, Bytes[20_u8])),
    ] of CrystalClick::BinaryValue,
    [
      CrystalClick::BinaryValue.dynamic(dynamic, w210_json_value(json_used, 41_u8, 401_u64)),
      CrystalClick::BinaryValue.dynamic(dynamic, w210_json_value(json_used, 42_u8, 402_u64)),
    ] of CrystalClick::BinaryValue,
  ] of Array(CrystalClick::BinaryValue)
  {
    type:        dynamic,
    structures:  {"root" => structure},
    granules:    granules,
    plans:       plans,
    json_used:   json_used,
    json_unused: json_unused,
  }
end

private def w210_mark_rows(marks : Bytes) : Array(UInt64)
  unless marks.size % CrystalClick::CompressedMarkWriter::MARK_RECORD_SIZE == 0
    raise "W210 mark file contains an incomplete record"
  end
  mark_count = marks.size // CrystalClick::CompressedMarkWriter::MARK_RECORD_SIZE
  Array(UInt64).new(mark_count) do |record_index|
    offset = record_index * CrystalClick::CompressedMarkWriter::MARK_RECORD_SIZE + 16
    value = 0_u64
    8.times { |index| value |= marks[offset + index].to_u64 << (index * 8) }
    value
  end
end

describe "W210 Dynamic JSON physical composition" do
  it "hands bound Array(Dynamic) JSON rows to physical Object children on the P/Q/R grids" do
    fixture = w210_fixture
    type = fixture[:type]
    structures = fixture[:structures]
    granules = fixture[:granules]
    plans = fixture[:plans]
    rows_per_mark = [2_u64, 2_u64, 2_u64]

    structure = structures["root.elements"]
    used_index = structure.canonical_index_for(fixture[:json_used])
    unused_index = structure.canonical_index_for(fixture[:json_unused])
    normalized = CrystalClick::BinaryDynamicBulkCodec.encode(
      type,
      structures,
      granules,
      json_object_plans: plans,
    )
    normalized.json_object_for("root.elements", used_index).rows_per_mark.should eq([0_u64, 0_u64, 2_u64])
    normalized.json_object_for("root.elements", unused_index).rows_per_mark.should eq([0_u64, 0_u64, 0_u64])
    normalized_rows = CrystalClick::BinaryDynamicBulkCodec.decode(
      type,
      normalized,
      rows_per_mark,
      json_object_plans: plans,
    )
    normalized_rows.map do |mark|
      mark.reduce(0) { |total, value| total + value.element_count }
    end.should eq([0, 3, 2])

    codec_budget = CrystalClick::BinaryCodecBudget.new(
      CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
      true,
    )
    plan = CrystalClick::BinaryDynamicBulkPlan.new_with_budget(
      type,
      structures,
      codec_budget,
      json_object_plans: plans,
    )
    plan.json_object_binding_count.should eq(2)
    physical = CrystalClick::BinaryDynamicBulkPhysicalPlan.new(
      plan,
      "payload",
      CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
    )

    # This is the first W210 runtime RED: normalized W209 can produce the
    # paired streams, but the physical plan/writer must compose the bound
    # Object children instead of rejecting a JSON actual descriptor.
    files = CrystalClick::DynamicBulkColumnWriter.encode(
      plan,
      physical,
      granules,
      rows_per_mark,
      4096,
      CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
      CrystalClick::CompressedStreamLimits.new,
      codec_budget: codec_budget,
    )

    ordinary_names = physical.ordinary_stream_names.values
    ordinary_names.each { |name| files.has_key?(name).should be_true }
    files.keys.sort.should eq(physical.stream_names.values.sort)
    physical.json_object_sites.size.should eq(2)
    physical.json_object_sites.each do |site|
      site.physical_plan.stream_names.each { |name| files.has_key?(name).should be_true }
    end
    files.each_value do |pair|
      # The third .mrk2 word is physical parent rows P, including on the Object
      # child grid. It is not the Array occurrence count Q or JSON count R.
      w210_mark_rows(pair.marks).should eq([2_u64, 2_u64, 2_u64, 0_u64])
    end
  end

  it "publishes and auto-reads the complete public part across both Dynamic bulk profiles" do
    fixture = w210_fixture
    expected = [
      ["[]", "[]"] of String,
      ["[u8:17,u8:18]", "[u8:19]"] of String,
      ["[json:41:null:counter=401]", "[json:42:null:counter=402]"] of String,
    ] of Array(String)
    profiles = [
      CrystalClick::BinaryBulkProfile.single_stream,
      CrystalClick::BinaryBulkProfile.with_size_stream,
    ] of CrystalClick::BinaryBulkProfile

    profiles.each_with_index do |profile, index|
      parent = File.tempname("crystal-click-w210-public-#{index}-")
      Dir.mkdir(parent)
      begin
        part = File.join(parent, "all_1_1_0")
        keys = Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64]
        CrystalClick::WidePartWriter.write_uint64_dynamic_bulk_part(
          part,
          "pk",
          keys,
          "payload",
          fixture[:type],
          fixture[:structures],
          fixture[:granules],
          rows_per_mark: 2,
          profile: profile,
          json_object_plans: fixture[:plans],
        ).should eq(part)

        reader = CrystalClick::DynamicBulkColumnReader.open(part, "payload", fixture[:type])
        plan = CrystalClick::BinaryDynamicBulkPlan.new_with_budget(
          fixture[:type],
          fixture[:structures],
          CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true),
          profile,
          json_object_plans: fixture[:plans],
        )
        physical_plan = CrystalClick::BinaryDynamicBulkPhysicalPlan.new(plan, "payload")
        reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64])
        reader.physical_stream_names.sort.should eq(physical_plan.stream_names.values.sort)
        checksum_names = physical_plan.stream_names.values.flat_map do |name|
          base = CrystalClick::StreamName.hash(name)
          ["#{base}.bin", "#{base}.mrk2"] of String
        end.sort
        reader.selected_checksum_names.sort.should eq(checksum_names)
        checksums = CrystalClick::PartChecksums.open(part)
        reader.selected_checksum_names.each do |name|
          checksums.entries.has_key?(name).should be_true
        end
        child_stream_names = physical_plan.json_object_sites.flat_map do |site|
          site.physical_plan.stream_names
        end
        child_stream_names.size.should be > 0
        child_stream_names.each do |name|
          (name.ends_with?(".object_shared_data%2Epaths.size") ||
            name.ends_with?(".object_shared_data%2Evalues.size")).should be_false
        end
        physical_plan.json_object_sites.each do |site|
          shared_variant_size = site.physical_plan.stream_names.any? do |name|
            name.ends_with?(".counter.SharedVariant.size")
          end
          shared_variant_size.should eq(index == 1)
        end
        child_stream_names.each do |name|
          base = CrystalClick::StreamName.hash(name)
          mark_path = File.join(part, "#{base}.mrk2")
          w210_mark_rows(File.read(mark_path).to_slice).should eq([2_u64, 2_u64, 2_u64, 0_u64])
          ["#{base}.bin", "#{base}.mrk2"].each do |file_name|
            reader.selected_checksum_names.should contain(file_name)
          end
        end

        full = reader.read_marks(0, reader.mark_count)
        full.map { |mark| mark.map { |row| w210_direct_signature(row) } }.should eq(expected)
        reader.read_marks(1, 1).map { |mark| mark.map { |row| w210_direct_signature(row) } }.should eq([expected[1]])
        reader.read_marks(2, 1).map { |mark| mark.map { |row| w210_direct_signature(row) } }.should eq([expected[2]])
        reader.read_marks(reader.mark_count, 0).should be_empty
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "publishes and auto-reads bound JSON children at a root Dynamic site" do
    fixture = w210_root_fixture
    expected = [
      ["u8:17", "u8:18"] of String,
      ["u8:19", "u8:20"] of String,
      ["json:41:null:counter=401", "json:42:null:counter=402"] of String,
    ] of Array(String)
    parent = File.tempname("crystal-click-w210-root-")
    Dir.mkdir(parent)
    begin
      part = File.join(parent, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_dynamic_bulk_part(
        part,
        "pk",
        Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64],
        "payload",
        fixture[:type],
        fixture[:structures],
        fixture[:granules],
        rows_per_mark: 2,
        json_object_plans: fixture[:plans],
      ).should eq(part)

      reader = CrystalClick::DynamicBulkColumnReader.open(part, "payload", fixture[:type])
      plan = CrystalClick::BinaryDynamicBulkPlan.new_with_budget(
        fixture[:type],
        fixture[:structures],
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true),
        json_object_plans: fixture[:plans],
      )
      physical_plan = CrystalClick::BinaryDynamicBulkPhysicalPlan.new(plan, "payload")
      reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64])
      reader.physical_stream_names.sort.should eq(physical_plan.stream_names.values.sort)
      checksums = CrystalClick::PartChecksums.open(part)
      checksum_names = physical_plan.stream_names.values.flat_map do |name|
        base = CrystalClick::StreamName.hash(name)
        ["#{base}.bin", "#{base}.mrk2"] of String
      end.sort
      reader.selected_checksum_names.sort.should eq(checksum_names)
      reader.selected_checksum_names.each do |name|
        checksums.entries.has_key?(name).should be_true
      end
      physical_plan.json_object_sites.size.should eq(2)
      physical_plan.json_object_sites.each do |site|
        site.physical_plan.stream_names.each do |name|
          base = CrystalClick::StreamName.hash(name)
          w210_mark_rows(File.read(File.join(part, "#{base}.mrk2")).to_slice).should eq([2_u64, 2_u64, 2_u64, 0_u64])
          ["#{base}.bin", "#{base}.mrk2"].each do |file_name|
            reader.selected_checksum_names.should contain(file_name)
          end
        end
      end

      reader.read_marks(0, reader.mark_count).map do |mark|
        mark.map { |row| w210_actual_signature(row) }
      end.should eq(expected)
      reader.read_marks(1, 1).map { |mark| mark.map { |row| w210_actual_signature(row) } }.should eq([expected[1]])
      reader.read_marks(2, 1).map { |mark| mark.map { |row| w210_actual_signature(row) } }.should eq([expected[2]])
      reader.read_marks(reader.mark_count, 0).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "validates an unused JSON child's files during an empty public read" do
    fixture = w210_fixture
    parent = File.tempname("crystal-click-w210-empty-corrupt-")
    Dir.mkdir(parent)
    begin
      part = File.join(parent, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_dynamic_bulk_part(
        part,
        "pk",
        Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64],
        "payload",
        fixture[:type],
        fixture[:structures],
        fixture[:granules],
        rows_per_mark: 2,
        json_object_plans: fixture[:plans],
      )
      reader = CrystalClick::DynamicBulkColumnReader.open(part, "payload", fixture[:type])
      structure = fixture[:structures]["root.elements"]
      unused_index = structure.canonical_index_for(fixture[:json_unused])
      plan = CrystalClick::BinaryDynamicBulkPlan.new_with_budget(
        fixture[:type],
        fixture[:structures],
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true),
        json_object_plans: fixture[:plans],
      )
      physical = CrystalClick::BinaryDynamicBulkPhysicalPlan.new(plan, "payload")
      unused_site = physical.json_object_site("root.elements", unused_index)
      child_name = w210_object_structure_stream(unused_site.physical_plan.stream_names)
      child_path = File.join(part, "#{CrystalClick::StreamName.hash(child_name)}.bin")
      bytes = File.read(child_path).to_slice.dup
      raise "W210 unused Object child file is unexpectedly empty" if bytes.empty?
      bytes[0] = bytes[0] ^ 0xff_u8
      File.write(child_path, bytes)

      expect_raises(CrystalClick::CorruptPartError) do
        reader.read_marks(reader.mark_count, 0)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "requires the persisted child files for an unused bound JSON arm on open" do
    fixture = w210_fixture
    parent = File.tempname("crystal-click-w210-missing-unused-")
    Dir.mkdir(parent)
    begin
      part = File.join(parent, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_dynamic_bulk_part(
        part,
        "pk",
        Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64],
        "payload",
        fixture[:type],
        fixture[:structures],
        fixture[:granules],
        rows_per_mark: 2,
        json_object_plans: fixture[:plans],
      )
      structure = fixture[:structures]["root.elements"]
      unused_index = structure.canonical_index_for(fixture[:json_unused])
      plan = CrystalClick::BinaryDynamicBulkPlan.new_with_budget(
        fixture[:type],
        fixture[:structures],
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true),
        json_object_plans: fixture[:plans],
      )
      physical = CrystalClick::BinaryDynamicBulkPhysicalPlan.new(plan, "payload")
      unused_site = physical.json_object_site("root.elements", unused_index)
      child_name = w210_object_structure_stream(unused_site.physical_plan.stream_names)
      child_path = File.join(part, "#{CrystalClick::StreamName.hash(child_name)}.bin")
      File.delete(child_path)

      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::DynamicBulkColumnReader.open(part, "payload", fixture[:type])
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects an unbound JSON actual arm before publishing any part files" do
    fixture = w210_fixture
    parent = File.tempname("crystal-click-w210-unbound-")
    Dir.mkdir(parent)
    begin
      destination = File.join(parent, "part")
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.write_uint64_dynamic_bulk_part(
          destination,
          "pk",
          Slice[2_u64, 5_u64, 9_u64, 14_u64, 21_u64, 28_u64],
          "payload",
          fixture[:type],
          fixture[:structures],
          fixture[:granules],
          rows_per_mark: 2,
        )
      end
      File.exists?(destination).should be_false
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects incomplete and foreign JSON child bindings before publishing" do
    fixture = w210_fixture
    parent = File.tempname("crystal-click-w210-invalid-bindings-")
    Dir.mkdir(parent)
    begin
      keys = Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64]
      invalid_plan_sets = [
        fixture[:plans][0, 1],
        [
          {"root.foreign", fixture[:plans][0][1], fixture[:plans][0][2]},
          fixture[:plans][1],
        ] of Tuple(String, Int32, CrystalClick::ObjectDocumentPlan),
      ] of Array(Tuple(String, Int32, CrystalClick::ObjectDocumentPlan))

      invalid_plan_sets.each_with_index do |invalid_plans, index|
        destination = File.join(parent, "invalid-#{index}")
        expect_raises(ArgumentError) do
          CrystalClick::WidePartWriter.write_uint64_dynamic_bulk_part(
            destination,
            "pk",
            keys,
            "payload",
            fixture[:type],
            fixture[:structures],
            fixture[:granules],
            rows_per_mark: 2,
            json_object_plans: invalid_plans,
          )
        end
        File.exists?(destination).should be_false
      end

      wrong_typed = [
        {fixture[:plans][0][0], fixture[:plans][0][1], w210_wrong_typed_object_plan(fixture[:json_used])},
        fixture[:plans][1],
      ] of Tuple(String, Int32, CrystalClick::ObjectDocumentPlan)
      destination = File.join(parent, "wrong-typed-path-schema")
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_dynamic_bulk_part(
          destination,
          "pk",
          keys,
          "payload",
          fixture[:type],
          fixture[:structures],
          fixture[:granules],
          rows_per_mark: 2,
          json_object_plans: wrong_typed,
        )
      end
      File.exists?(destination).should be_false
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "writes, reads, and table-materializes a recursive Array(Dynamic) JSON sibling on P/Q/R" do
    fixture = w210_recursive_fixture
    expected = [
      ["1:[]", "2:[]"] of String,
      ["3:[u8:17,u8:18]", "4:[u8:19]"] of String,
      ["5:[json:41:null:counter=401]", "6:[json:42:null:counter=402]"] of String,
    ] of Array(String)
    modes = [
      CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
      CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE,
    ] of UInt64
    modes.each_with_index do |mode, mode_index|
      parent = File.tempname("crystal-click-w210-recursive-#{mode_index}-")
      Dir.mkdir(parent)
      begin
        part = File.join(parent, "all_1_1_0")
        keys = Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64]
        recursive_plan = CrystalClick::RecursiveStorageColumnPlan.for_column(
          "payload", fixture[:schema], fixture[:object_plans],
          hashed: true,
          mode: mode,
          dynamic_plans: fixture[:dynamic_plans],
        )
        recursive_plan.dynamic_site_count.should eq(1)
        recursive_plan.dynamic_site_at(0).key.should eq("root/tuple[1]")
        CrystalClick::WidePartWriter.write_uint64_recursive_pair(
          part,
          "pk",
          keys,
          "payload",
          fixture[:schema],
          fixture[:object_plans],
          fixture[:granules],
          rows_per_mark: 2,
          mode: mode,
          dynamic_plans: fixture[:dynamic_plans],
        ).should eq(part)

        reader = CrystalClick::RecursiveStorageColumnReader.open(part, "payload", fixture[:schema])
        reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64])
        reader.physical_stream_names.sort.should eq(recursive_plan.physical_stream_names.sort)
        reader.selected_checksum_names.sort.should eq(recursive_plan.file_names.sort)
        dynamic_physical = recursive_plan.dynamic_site_at(0).physical
        dynamic_physical.json_object_sites.size.should eq(2)
        dynamic_physical.json_object_sites.each do |site|
          site.physical_plan.stream_names.each do |name|
            base = CrystalClick::StreamName.hash(name)
            w210_mark_rows(File.read(File.join(part, "#{base}.mrk2")).to_slice).should eq([2_u64, 2_u64, 2_u64, 0_u64])
            ["#{base}.bin", "#{base}.mrk2"].each do |file_name|
              reader.selected_checksum_names.should contain(file_name)
            end
          end
        end
        full = reader.read_marks(0, reader.mark_count)
        full.map { |mark| mark.map { |row| w210_recursive_signature(row) } }.should eq(expected)
        reader.read_marks(1, 1).map { |mark| mark.map { |row| w210_recursive_signature(row) } }.should eq([expected[1]])
        reader.read_marks(2, 1).map { |mark| mark.map { |row| w210_recursive_signature(row) } }.should eq([expected[2]])
        reader.read_marks(reader.mark_count, 0).should be_empty

        table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
        table_rows = [] of Array(String)
        table.scan_typed_candidate_marks([[0, 1, 2]]) do |batch|
          table_rows << batch.recursive_values_for("payload").map { |row| w210_recursive_signature(row) }.to_a
        end
        table_rows.should eq(expected)

        if mode_index == 0
          callbacks = 0
          dynamic_site = recursive_plan.dynamic_site_at(0)
          structure = fixture[:dynamic_plans][dynamic_site.key].structure_for("root.elements")
          unused_index = structure.canonical_index_for(fixture[:json_unused])
          unused_child = dynamic_site.physical.json_object_site("root.elements", unused_index)
          child_name = w210_object_structure_stream(unused_child.physical_plan.stream_names)
          child_path = File.join(part, "#{CrystalClick::StreamName.hash(child_name)}.bin")
          bytes = File.read(child_path).to_slice.dup
          raise "W210 recursive unused child file is unexpectedly empty" if bytes.empty?
          bytes[0] = bytes[0] ^ 0xff_u8
          File.write(child_path, bytes)
          expect_raises(CrystalClick::CorruptPartError) do
            table.scan_typed_candidate_marks([[] of Int32]) do |batch|
              callbacks += 1
              batch.recursive_values_for("payload")
            end
          end
          callbacks.should eq(0)
        end
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "passes outer P and zero Dynamic-site Q through recursive Array(Tuple(JSON, Dynamic))" do
    fixture = w210_qzero_recursive_fixture
    expected = [
      ["[]", "[]"] of String,
      ["[3:u8:17,4:u8:18]", "[5:u8:19]"] of String,
      ["[6:json:61:null:counter=601]", "[7:json:62:null:counter=602]"] of String,
    ] of Array(String)
    parent = File.tempname("crystal-click-w210-recursive-qzero-")
    Dir.mkdir(parent)
    begin
      part = File.join(parent, "all_1_1_0")
      keys = Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64]
      recursive_plan = CrystalClick::RecursiveStorageColumnPlan.for_column(
        "payload", fixture[:schema], fixture[:object_plans],
        hashed: true,
        dynamic_plans: fixture[:dynamic_plans],
      )
      recursive_plan.dynamic_site_count.should eq(1)
      dynamic_site = recursive_plan.dynamic_site_at(0)
      dynamic_site.key.should eq("root/array[0]/tuple[1]")
      CrystalClick::WidePartWriter.write_uint64_recursive_pair(
        part,
        "pk",
        keys,
        "payload",
        fixture[:schema],
        fixture[:object_plans],
        fixture[:granules],
        rows_per_mark: 2,
        dynamic_plans: fixture[:dynamic_plans],
      ).should eq(part)

      reader = CrystalClick::RecursiveStorageColumnReader.open(part, "payload", fixture[:schema])
      reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64])
      reader.physical_stream_names.sort.should eq(recursive_plan.physical_stream_names.sort)
      reader.selected_checksum_names.sort.should eq(recursive_plan.file_names.sort)

      # The root part and every nested physical child retain P=[2,2,2]. The
      # logical Dynamic occurrence grid is Q=[0,3,2], while selected JSON rows
      # are R=[0,0,2]; neither logical count replaces the physical mark grid.
      dynamic_physical = dynamic_site.physical
      dynamic_physical.json_object_sites.size.should eq(2)
      dynamic_physical.stream_names.each_value do |name|
        base = CrystalClick::StreamName.hash(name)
        w210_mark_rows(File.read(File.join(part, "#{base}.mrk2")).to_slice).should eq([2_u64, 2_u64, 2_u64, 0_u64])
      end
      dynamic_physical.json_object_sites.each do |site|
        site.physical_plan.stream_names.each do |name|
          base = CrystalClick::StreamName.hash(name)
          w210_mark_rows(File.read(File.join(part, "#{base}.mrk2")).to_slice).should eq([2_u64, 2_u64, 2_u64, 0_u64])
          ["#{base}.bin", "#{base}.mrk2"].each do |file_name|
            reader.selected_checksum_names.should contain(file_name)
          end
        end
      end

      full = reader.read_marks(0, reader.mark_count)
      full.map { |mark| mark.map { |row| w210_qzero_recursive_signature(row) } }.should eq(expected)
      full.map { |mark| mark.sum { |row| row.array_values.size } }.should eq([0, 3, 2])
      full.map do |mark|
        mark.sum do |row|
          row.array_values.count do |tuple|
            tuple.child_at(1).bulk_value.child_at(0).type.tag == CrystalClick::BinaryDataType::TAG_JSON
          end
        end
      end.should eq([0, 0, 2])
      reader.read_marks(1, 1).map { |mark| mark.map { |row| w210_qzero_recursive_signature(row) } }.should eq([expected[1]])
      reader.read_marks(2, 1).map { |mark| mark.map { |row| w210_qzero_recursive_signature(row) } }.should eq([expected[2]])
      reader.read_marks(reader.mark_count, 0).should be_empty

      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      table_rows = [] of Array(String)
      table.scan_typed_candidate_marks([[0, 1, 2]]) do |batch|
        table_rows << batch.recursive_values_for("payload").map { |row| w210_qzero_recursive_signature(row) }.to_a
      end
      table_rows.should eq(expected)

      callbacks = 0
      structure = fixture[:dynamic_plans][dynamic_site.key].structure_for("root")
      unused_index = structure.canonical_index_for(fixture[:json_unused])
      unused_child = dynamic_physical.json_object_site("root", unused_index)
      child_name = w210_object_structure_stream(unused_child.physical_plan.stream_names)
      child_path = File.join(part, "#{CrystalClick::StreamName.hash(child_name)}.bin")
      bytes = File.read(child_path).to_slice.dup
      raise "W210 recursive zero-Q unused child file is unexpectedly empty" if bytes.empty?
      bytes[0] = bytes[0] ^ 0xff_u8
      File.write(child_path, bytes)
      expect_raises(CrystalClick::CorruptPartError) do
        table.scan_typed_candidate_marks([[] of Int32]) do |batch|
          callbacks += 1
          batch.recursive_values_for("payload")
        end
      end
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "admits exact inherited JSON depth and rejects one level less on recursive open" do
    exact_limits = CrystalClick::BinaryCodecLimits.new(6, 100_000, 100_000, 1_048_576)
    exact_fixture = w210_qzero_recursive_fixture(exact_limits)
    parent = File.tempname("crystal-click-w210-depth-")
    Dir.mkdir(parent)
    begin
      part = File.join(parent, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_recursive_pair(
        part,
        "pk",
        Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64],
        "payload",
        exact_fixture[:schema],
        exact_fixture[:object_plans],
        exact_fixture[:granules],
        rows_per_mark: 2,
        limits: exact_limits,
        dynamic_plans: exact_fixture[:dynamic_plans],
      )
      exact_reader = CrystalClick::RecursiveStorageColumnReader.open(
        part, "payload", exact_fixture[:schema]
      )
      exact_reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64])

      narrow_limits = CrystalClick::BinaryCodecLimits.new(5, 100_000, 100_000, 1_048_576)
      narrow_fixture = w210_qzero_recursive_fixture(narrow_limits)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::RecursiveStorageColumnReader.open(
          part, "payload", narrow_fixture[:schema]
        )
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "compares staged Dynamic and recursive JSON by path and nested value, not owner identity" do
    json_type = w210_json_type(1)
    equal_left = w210_json_value(json_type, 7_u8, 701_u64)
    equal_right = w210_json_value(json_type, 7_u8, 701_u64)
    equal_left.same?(equal_right).should be_false
    CrystalClick.w210_compare_dynamic!(equal_left, equal_right)
    left_storage = CrystalClick::StorageColumnValue.tuple([
      CrystalClick::StorageColumnValue.bulk(CrystalClick::BinaryValue.dynamic(
        CrystalClick::BinaryDataType.dynamic(3), equal_left
      )),
    ] of CrystalClick::StorageColumnValue)
    right_storage = CrystalClick::StorageColumnValue.tuple([
      CrystalClick::StorageColumnValue.bulk(CrystalClick::BinaryValue.dynamic(
        CrystalClick::BinaryDataType.dynamic(3), equal_right
      )),
    ] of CrystalClick::StorageColumnValue)
    CrystalClick.w210_compare_recursive!(left_storage, right_storage)

    changed_path = w210_json_value(json_type, 7_u8, 701_u64, "other_counter")
    changed_value = w210_json_value(json_type, 7_u8, 702_u64)
    changed_nullable = w210_json_value(json_type, 7_u8, 701_u64, maybe_value: 9_u8)
    [changed_path, changed_value, changed_nullable].each do |changed|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick.w210_compare_dynamic!(equal_left, changed)
      end
      changed_storage = CrystalClick::StorageColumnValue.tuple([
        CrystalClick::StorageColumnValue.bulk(CrystalClick::BinaryValue.dynamic(
          CrystalClick::BinaryDataType.dynamic(3), changed
        )),
      ] of CrystalClick::StorageColumnValue)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick.w210_compare_recursive!(left_storage, changed_storage)
      end
    end
  end
end

module CrystalClick
  module WidePartWriter
    private class DynamicBulkPartWriter
      def self.w210_compare!(actual : BinaryValue, expected : BinaryValue) : Nil
        compare_binary_value!(actual, expected)
      end
    end

    private class RecursiveStoragePartWriter
      def self.w210_compare!(actual : StorageColumnValue, expected : StorageColumnValue) : Nil
        compare_storage_value!(actual, expected)
      end
    end

    def self.w210_compare_dynamic!(actual : BinaryValue, expected : BinaryValue) : Nil
      DynamicBulkPartWriter.w210_compare!(actual, expected)
    end

    def self.w210_compare_recursive!(actual : StorageColumnValue, expected : StorageColumnValue) : Nil
      RecursiveStoragePartWriter.w210_compare!(actual, expected)
    end
  end

  def self.w210_compare_dynamic!(actual : BinaryValue, expected : BinaryValue) : Nil
    WidePartWriter.w210_compare_dynamic!(actual, expected)
  end

  def self.w210_compare_recursive!(actual : StorageColumnValue, expected : StorageColumnValue) : Nil
    WidePartWriter.w210_compare_recursive!(actual, expected)
  end
end
