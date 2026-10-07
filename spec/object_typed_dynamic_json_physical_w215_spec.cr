require "file_utils"
require "./spec_helper"

private alias W215PLeafPlan = Tuple(
  CrystalClick::BinaryDynamicJsonLeafKey,
  CrystalClick::ObjectDocumentPlan,
)

private def w215p_json_type : CrystalClick::BinaryDataType
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  CrystalClick::BinaryDataType.json(
    max_dynamic_paths: 0,
    max_dynamic_types: 0,
    typed_paths: {"v" => uint8} of String => CrystalClick::BinaryDataType,
  )
end

private def w215p_nested_json_type : CrystalClick::BinaryDataType
  dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 2)
  CrystalClick::BinaryDataType.json(
    max_dynamic_paths: 0,
    max_dynamic_types: 0,
    typed_paths: {"p" => dynamic} of String => CrystalClick::BinaryDataType,
  )
end

private def w215p_json(type : CrystalClick::BinaryDataType, value : UInt8) : CrystalClick::BinaryValue
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  CrystalClick::BinaryValue.json(
    type,
    CrystalClick::BinaryJsonRow.new(
      type,
      [{"v", CrystalClick::BinaryValue.fixed(uint8, Bytes[value])}] of Tuple(String, CrystalClick::BinaryValue),
    ),
  )
end

private def w215p_json_with_note(
  type : CrystalClick::BinaryDataType,
  value : UInt8,
  note : String,
) : CrystalClick::BinaryValue
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  CrystalClick::BinaryValue.json(
    type,
    CrystalClick::BinaryJsonRow.new(
      type,
      [
        {"v", CrystalClick::BinaryValue.fixed(uint8, Bytes[value])},
        {"note", CrystalClick::BinaryValue.string(note)},
      ] of Tuple(String, CrystalClick::BinaryValue),
    ),
  )
end

private def w215p_note_signature(value : CrystalClick::BinaryValue) : Tuple(UInt8, String)
  unless value.type.tag == CrystalClick::BinaryDataType::TAG_DYNAMIC && !value.is_null?
    raise "W215 note witness did not decode as a non-NULL Dynamic"
  end
  json = value.child_at(0)
  unless json.type.tag == CrystalClick::BinaryDataType::TAG_JSON
    raise "W215 note witness did not decode as JSON"
  end
  row = json.json_row
  typed_value = row.value_for("v").not_nil!
  expected = CrystalClick::BinaryDataType.primitive("UInt8")
  unless typed_value.type == expected
    raise "W215 note witness typed v path changed type: #{typed_value.type.name}"
  end
  note = row.value_for("note").not_nil!
  unless note.type.tag == CrystalClick::BinaryDataType::TAG_STRING
    raise "W215 note witness shared path changed type: #{note.type.name}"
  end
  {typed_value.byte_at(0), note.as_string}
end

private def w215p_nested_json(
  type : CrystalClick::BinaryDataType,
  dynamic : CrystalClick::BinaryDataType,
  json : CrystalClick::BinaryDataType,
  value : UInt8,
) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.json(
    type,
    CrystalClick::BinaryJsonRow.new(
      type,
      [{"p", CrystalClick::BinaryValue.dynamic(dynamic, w215p_json(json, value))}] of Tuple(String, CrystalClick::BinaryValue),
    ),
  )
end

private def w215p_empty_structures : CrystalClick::ObjectDynamicStructureSet
  CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new([] of String),
    {} of String => CrystalClick::DynamicStructure,
  )
end

private struct W215PhysicalFixture
  getter schema : CrystalClick::ObjectDocumentSchema
  getter plan : CrystalClick::ObjectDocumentPlan
  getter granules : Array(Array(CrystalClick::ObjectDocument))
  getter expected : Array(Array(String))

  def initialize
    json = w215p_json_type
    array_json = CrystalClick::BinaryDataType.array(json)
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 2)
    outer = CrystalClick::BinaryDataType.array(dynamic)
    nested_json = w215p_nested_json_type
    nested_array = CrystalClick::BinaryDataType.array(nested_json)
    p_roster = CrystalClick::DynamicStructure.new([json] of CrystalClick::BinaryDataType)
    q_roster = CrystalClick::DynamicStructure.new([array_json] of CrystalClick::BinaryDataType)
    outer_roster = CrystalClick::DynamicStructure.new([json, array_json] of CrystalClick::BinaryDataType)
    unselected_roster = CrystalClick::DynamicStructure.new([json, uint8] of CrystalClick::BinaryDataType)
    nested_roster = CrystalClick::DynamicStructure.new([nested_array] of CrystalClick::BinaryDataType)

    @schema = CrystalClick::ObjectDocumentSchema.new({
      "p"          => dynamic,
      "q"          => dynamic,
      "outer"      => outer,
      "unselected" => dynamic,
      "nested"     => dynamic,
    } of String => CrystalClick::BinaryDataType)
    child_structures = w215p_empty_structures
    child_plan = CrystalClick::ObjectDocumentPlan.new(child_structures, json.json_type.not_nil!.typed_paths)
    nested_inner_roster = CrystalClick::DynamicStructure.new([json] of CrystalClick::BinaryDataType)
    nested_inner_binding = {
      CrystalClick::BinaryDynamicJsonLeafKey.new("root", nested_inner_roster.canonical_index_for(json), [] of Int32),
      child_plan,
    }
    nested_json_plan = CrystalClick::ObjectDocumentPlan.new(
      child_structures,
      nested_json.json_type.not_nil!.typed_paths,
      {"p" => nested_inner_roster} of String => CrystalClick::DynamicStructure,
      typed_dynamic_json_object_leaf_plans: {
        "p" => [nested_inner_binding] of W215PLeafPlan,
      } of String => Array(W215PLeafPlan),
    )
    p_arm = p_roster.canonical_index_for(json)
    q_arm = q_roster.canonical_index_for(array_json)
    outer_json_arm = outer_roster.canonical_index_for(json)
    outer_array_arm = outer_roster.canonical_index_for(array_json)
    unselected_json_arm = unselected_roster.canonical_index_for(json)
    nested_array_arm = nested_roster.canonical_index_for(nested_array)
    leaf_plans = {
      "p"     => [{CrystalClick::BinaryDynamicJsonLeafKey.new("root", p_arm, [] of Int32), child_plan}] of W215PLeafPlan,
      "q"     => [{CrystalClick::BinaryDynamicJsonLeafKey.new("root", q_arm, [0_i32] of Int32), child_plan}] of W215PLeafPlan,
      "outer" => [
        {CrystalClick::BinaryDynamicJsonLeafKey.new("root.elements", outer_json_arm, [] of Int32), child_plan},
        {CrystalClick::BinaryDynamicJsonLeafKey.new("root.elements", outer_array_arm, [0_i32] of Int32), child_plan},
      ] of W215PLeafPlan,
      "unselected" => [{CrystalClick::BinaryDynamicJsonLeafKey.new("root", unselected_json_arm, [] of Int32), child_plan}] of W215PLeafPlan,
      "nested"     => [{CrystalClick::BinaryDynamicJsonLeafKey.new("root", nested_array_arm, [0_i32] of Int32), nested_json_plan}] of W215PLeafPlan,
    } of String => Array(W215PLeafPlan)
    @plan = CrystalClick::ObjectDocumentPlan.new(
      w215p_empty_structures,
      @schema.typed_paths,
      {"p" => p_roster, "q" => q_roster, "unselected" => unselected_roster, "nested" => nested_roster} of String => CrystalClick::DynamicStructure,
      typed_dynamic_sites: {
        "outer" => {"root.elements" => outer_roster} of String => CrystalClick::DynamicStructure,
      } of String => Hash(String, CrystalClick::DynamicStructure),
      typed_dynamic_json_object_leaf_plans: leaf_plans,
    )

    d = ->(actual : CrystalClick::BinaryValue?) { CrystalClick::BinaryValue.dynamic(dynamic, actual) }
    a = ->(items : Array(CrystalClick::BinaryValue)) { CrystalClick::BinaryValue.array(array_json, items) }
    nested_a = ->(items : Array(CrystalClick::BinaryValue)) { CrystalClick::BinaryValue.array(nested_array, items) }
    o = ->(items : Array(CrystalClick::BinaryValue)) { CrystalClick::BinaryValue.array(outer, items) }
    nested_value = ->(items : Array(CrystalClick::BinaryValue)) { d.call(nested_a.call(items)) }
    row = ->(p : CrystalClick::BinaryValue, q : CrystalClick::BinaryValue, values : CrystalClick::BinaryValue, unselected : UInt8, nested : CrystalClick::BinaryValue) {
      CrystalClick::ObjectDocument.new({
        "p"          => p,
        "q"          => q,
        "outer"      => values,
        "unselected" => d.call(CrystalClick::BinaryValue.fixed(uint8, Bytes[unselected])),
        "nested"     => nested,
      } of String => CrystalClick::BinaryValue)
    }
    @granules = [
      [
        row.call(d.call(w215p_json(json, 1_u8)), d.call(a.call([w215p_json(json, 11_u8)] of CrystalClick::BinaryValue)), o.call([] of CrystalClick::BinaryValue), 101_u8, nested_value.call([] of CrystalClick::BinaryValue)),
        row.call(d.call(nil), d.call(a.call([] of CrystalClick::BinaryValue)), o.call([] of CrystalClick::BinaryValue), 102_u8, nested_value.call([] of CrystalClick::BinaryValue)),
      ] of CrystalClick::ObjectDocument,
      [
        row.call(d.call(w215p_json(json, 3_u8)), d.call(a.call([w215p_json(json, 21_u8), w215p_json(json, 22_u8)] of CrystalClick::BinaryValue)), o.call([d.call(a.call([] of CrystalClick::BinaryValue))] of CrystalClick::BinaryValue), 103_u8, nested_value.call([w215p_nested_json(nested_json, dynamic, json, 71_u8)] of CrystalClick::BinaryValue)),
        row.call(d.call(w215p_json(json, 4_u8)), d.call(a.call([w215p_json(json, 31_u8)] of CrystalClick::BinaryValue)), o.call([] of CrystalClick::BinaryValue), 104_u8, nested_value.call([] of CrystalClick::BinaryValue)),
      ] of CrystalClick::ObjectDocument,
      [
        row.call(d.call(w215p_json(json, 5_u8)), d.call(a.call([] of CrystalClick::BinaryValue)), o.call([
          d.call(w215p_json(json, 51_u8)),
          d.call(a.call([w215p_json(json, 52_u8)] of CrystalClick::BinaryValue)),
          d.call(a.call([] of CrystalClick::BinaryValue)),
        ] of CrystalClick::BinaryValue), 105_u8, nested_value.call([] of CrystalClick::BinaryValue)),
        row.call(d.call(w215p_json(json, 6_u8)), d.call(nil), o.call([
          d.call(w215p_json(json, 61_u8)),
        ] of CrystalClick::BinaryValue), 106_u8, nested_value.call([] of CrystalClick::BinaryValue)),
      ] of CrystalClick::ObjectDocument,
    ] of Array(CrystalClick::ObjectDocument)
    @expected = [
      ["D(J(1))", "D(A[J(11)])", "A[]", "D(U(101))", "D(A[])"],
      ["DNULL", "D(A[])", "A[]", "D(U(102))", "D(A[])"],
      ["D(J(3))", "D(A[J(21),J(22)])", "A[D(A[])]", "D(U(103))", "D(A[N(D(J(71)))])"],
      ["D(J(4))", "D(A[J(31)])", "A[]", "D(U(104))", "D(A[])"],
      ["D(J(5))", "D(A[])", "A[D(J(51)),D(A[J(52)]),D(A[])]", "D(U(105))", "D(A[])"],
      ["D(J(6))", "DNULL", "A[D(J(61))]", "D(U(106))", "D(A[])"],
    ] of Array(String)
  end
end

private def w215p_signature(value : CrystalClick::BinaryValue) : String
  case value.type.tag
  when CrystalClick::BinaryDataType::TAG_DYNAMIC
    value.is_null? ? "DNULL" : "D(#{w215p_signature(value.child_at(0))})"
  when CrystalClick::BinaryDataType::TAG_ARRAY
    values = (0...value.element_count).map { |index| w215p_signature(value.element_at(index)) }
    "A[#{values.join(",")}]"
  when CrystalClick::BinaryDataType::TAG_JSON
    row = value.json_row
    if id = row.value_for("v")
      expected = CrystalClick::BinaryDataType.primitive("UInt8")
      unless id.type == expected
        raise "W215 typed JSON v path changed type: #{id.type.name}"
      end
      "J(#{id.byte_at(0)})"
    elsif child = row.value_for("p")
      "N(#{w215p_signature(child)})"
    else
      raise "unexpected W215 JSON row paths"
    end
  when CrystalClick::BinaryDataType::TAG_UINT8
    "U(#{value.byte_at(0)})"
  else
    raise "unexpected W215 physical value type: #{value.type.name}"
  end
end

private def w215p_array_object_signatures(
  marks : Array(Array(Array(CrystalClick::ObjectDocument))),
) : Array(Array(Array(String)))
  marks.map do |parents|
    parents.map do |documents|
      documents.map { |document| w215p_signature(document.value_for("p")) }
    end
  end
end

private def w215p_array_object_child_rows(
  granules : Array(Array(Array(CrystalClick::ObjectDocument))),
) : Array(UInt64)
  granules.map do |parents|
    rows = 0_u64
    parents.each { |children| rows += children.size.to_u64 }
    rows
  end
end

private def w215p_logical_qr(granules : Array(Array(CrystalClick::ObjectDocument))) : Tuple(Array(UInt64), Array(UInt64))
  q_by_mark = [] of UInt64
  r_by_mark = [] of UInt64
  granules.each do |mark|
    q = 0_u64
    r = 0_u64
    mark.each do |document|
      outer = document.value_for("outer")
      q += outer.element_count.to_u64
      (0...outer.element_count).each do |index|
        dynamic = outer.element_at(index)
        next if dynamic.is_null?
        actual = dynamic.child_at(0)
        case actual.type.tag
        when CrystalClick::BinaryDataType::TAG_JSON
          r += 1_u64
        when CrystalClick::BinaryDataType::TAG_ARRAY
          r += actual.element_count.to_u64
        else
          raise "unexpected W215 nested Dynamic actual: #{actual.type.name}"
        end
      end
    end
    q_by_mark << q
    r_by_mark << r
  end
  {q_by_mark, r_by_mark}
end

private def w215p_signatures(marks : Array(Array(CrystalClick::ObjectDocument))) : Array(Array(String))
  marks.flat_map do |mark|
    mark.map do |document|
      ["p", "q", "outer", "unselected", "nested"].map { |path| w215p_signature(document.value_for(path)) }
    end
  end
end

private def w215p_mark_rows(marks : Bytes) : Array(UInt64)
  unless marks.size % CrystalClick::CompressedMarkWriter::MARK_RECORD_SIZE == 0
    raise "W215 mark file contains an incomplete record"
  end
  count = marks.size // CrystalClick::CompressedMarkWriter::MARK_RECORD_SIZE
  Array(UInt64).new(count) do |record|
    offset = record * CrystalClick::CompressedMarkWriter::MARK_RECORD_SIZE + 16
    value = 0_u64
    8.times { |index| value |= marks[offset + index].to_u64 << (index * 8) }
    value
  end
end

private def w215p_write_u64(bytes : Bytes, offset : Int32, value : UInt64) : Nil
  8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w215p_with_parent(&)
  parent = File.tempname("crystal-click-w215-json-")
  Dir.mkdir(parent)
  begin
    yield parent
  ensure
    FileUtils.rm_rf(parent)
  end
end

describe "W215 ordinary JSON actuals in declared Object Dynamic physical readers" do
  it "discovers child Object bindings from part metadata for full, bounded, and table reads" do
    fixture = W215PhysicalFixture.new
    logical_q, logical_r = w215p_logical_qr(fixture.granules)
    logical_q.should eq([0_u64, 1_u64, 4_u64])
    logical_r.should eq([0_u64, 0_u64, 3_u64])
    logical_q.should_not eq(logical_r)
    profiles = [
      CrystalClick::BinaryBulkProfile.single_stream,
      CrystalClick::BinaryBulkProfile.with_size_stream,
    ] of CrystalClick::BinaryBulkProfile
    modes = [
      CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
      CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE,
    ] of UInt64

    w215p_with_parent do |parent|
      part_index = 0
      profiles.each do |profile|
        modes.each do |mode|
          part_index += 1
          part = File.join(parent, "all_#{part_index}_#{part_index}_0")
          CrystalClick::WidePartWriter.write_uint64_object_pair(
            part,
            "pk",
            Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64],
            "payload",
            fixture.schema,
            fixture.plan,
            fixture.granules,
            rows_per_mark: 2,
            mode: mode,
            profile: profile,
            frame_bytes: 64,
          ).should eq(part)

          File.read(File.join(part, "count.txt")).should eq("6")
          File.read(File.join(part, "columns.txt")).should contain(fixture.schema.declaration)
          reader = CrystalClick::ObjectColumnReader.open(part, "payload", fixture.schema)
          reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64])
          physical = CrystalClick::ObjectDocumentPhysicalPlan.new("payload", fixture.plan, profile)
          reader.physical_stream_names.should eq(physical.stream_names)
          physical.stream_names.each do |stream|
            marks_path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
            w215p_mark_rows(File.read(marks_path).to_slice).should eq([2_u64, 2_u64, 2_u64, 0_u64])
          end

          full = CrystalClick::ObjectDocumentFileReader.read(
            part,
            "payload",
            fixture.schema.typed_paths,
            profile: profile,
            first_mark: 0,
            mark_count: 3,
            hashed: true,
          )
          w215p_signatures(full).should eq(fixture.expected)
          w215p_signatures(CrystalClick::ObjectDocumentFileReader.read(
            part, "payload", fixture.schema.typed_paths,
            first_mark: 1, mark_count: 1, profile: profile, hashed: true,
          )).should eq(fixture.expected[2, 2])
          w215p_signatures(CrystalClick::ObjectDocumentFileReader.read(
            part, "payload", fixture.schema.typed_paths,
            first_mark: 2, mark_count: 1, profile: profile, hashed: true,
          )).should eq(fixture.expected[4, 2])
          CrystalClick::ObjectDocumentFileReader.read(
            part, "payload", fixture.schema.typed_paths,
            first_mark: 3, mark_count: 0, profile: profile, hashed: true,
          ).should be_empty
          w215p_signatures(reader.read_marks(0, 3)).should eq(fixture.expected)
          w215p_signatures(reader.read_marks(1, 1)).should eq(fixture.expected[2, 2])
          reader.read_marks(3, 0).should be_empty

          table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
          table.total_row_count.should eq(6_u64)
          observed = [] of Array(String)
          table.scan_typed do |batch|
            batch.object_documents_for("payload").each do |document|
              observed << ["p", "q", "outer", "unselected", "nested"].map { |path| w215p_signature(document.value_for(path)) }
            end
          end
          observed.should eq(fixture.expected)
          window = [] of Array(String)
          table.scan_typed_window(4_u64, 2) do |batch|
            batch.object_documents_for("payload").each do |document|
              window << ["p", "q", "outer", "unselected", "nested"].map { |path| w215p_signature(document.value_for(path)) }
            end
          end
          window.should eq(fixture.expected[4, 2])
          table.scan_typed_window(6_u64, 1) { raise "EOF table window unexpectedly materialized a batch" }
        end
      end
    end
  end

  it "validates a bound but unselected JSON child's physical grid at EOF" do
    json = w215p_json_type
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 2)
    roster = CrystalClick::DynamicStructure.new([json, uint8] of CrystalClick::BinaryDataType)
    schema = CrystalClick::ObjectDocumentSchema.new({"only" => dynamic} of String => CrystalClick::BinaryDataType)
    child_plan = CrystalClick::ObjectDocumentPlan.new(w215p_empty_structures, json.json_type.not_nil!.typed_paths)
    binding = {
      CrystalClick::BinaryDynamicJsonLeafKey.new("root", roster.canonical_index_for(json), [] of Int32),
      child_plan,
    }
    plan = CrystalClick::ObjectDocumentPlan.new(
      w215p_empty_structures,
      schema.typed_paths,
      {"only" => roster} of String => CrystalClick::DynamicStructure,
      typed_dynamic_json_object_leaf_plans: {
        "only" => [binding] of W215PLeafPlan,
      } of String => Array(W215PLeafPlan),
    )
    documents = [[
      CrystalClick::ObjectDocument.new({
        "only" => CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.fixed(uint8, Bytes[1_u8])),
      } of String => CrystalClick::BinaryValue),
      CrystalClick::ObjectDocument.new({
        "only" => CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.fixed(uint8, Bytes[2_u8])),
      } of String => CrystalClick::BinaryValue),
    ] of CrystalClick::ObjectDocument]

    w215p_with_parent do |parent|
      part = File.join(parent, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_object_pair(
        part,
        "pk",
        Slice[1_u64, 2_u64],
        "payload",
        schema,
        plan,
        documents,
        rows_per_mark: 2,
        mode: CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
        profile: CrystalClick::BinaryBulkProfile.single_stream,
        frame_bytes: 64,
      ).should eq(part)

      physical = CrystalClick::ObjectDocumentPhysicalPlan.new(
        "payload", plan, CrystalClick::BinaryBulkProfile.single_stream,
      )
      child_structure = physical.stream_names.find do |name|
        name != physical.object_structure_stream && name.ends_with?(".object_structure")
      end.not_nil!
      marks_path = File.join(part, "#{CrystalClick::StreamName.hash(child_structure)}.mrk2")
      marks = File.read(marks_path).to_slice.dup
      w215p_write_u64(marks, 16, 1_u64)
      File.write(marks_path, marks)

      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::ObjectDocumentFileReader.read(
          part,
          "payload",
          schema.typed_paths,
          profile: CrystalClick::BinaryBulkProfile.single_stream,
          first_mark: 1,
          mark_count: 0,
          hashed: true,
        )
      end
    end
  end

  it "carries typed Dynamic JSON through the public Array(JSON) writer, reader, and table path" do
    json = w215p_json_type
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    schema = CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(p Dynamic(max_types=1))")
    roster = CrystalClick::DynamicStructure.new([json] of CrystalClick::BinaryDataType)
    child_plan = CrystalClick::ObjectDocumentPlan.new(
      w215p_empty_structures,
      json.json_type.not_nil!.typed_paths,
    )
    binding = {
      CrystalClick::BinaryDynamicJsonLeafKey.new("root", roster.canonical_index_for(json), [] of Int32),
      child_plan,
    }
    plan = CrystalClick::ObjectDocumentPlan.new(
      w215p_empty_structures,
      schema.typed_paths,
      {"p" => roster} of String => CrystalClick::DynamicStructure,
      typed_dynamic_json_object_leaf_plans: {
        "p" => [binding] of W215PLeafPlan,
      } of String => Array(W215PLeafPlan),
    )
    document = ->(value : UInt8) {
      CrystalClick::ObjectDocument.new({
        "p" => CrystalClick::BinaryValue.dynamic(dynamic, w215p_json(json, value)),
      } of String => CrystalClick::BinaryValue)
    }
    granules = [
      [
        [] of CrystalClick::ObjectDocument,
        [document.call(101_u8)] of CrystalClick::ObjectDocument,
      ] of Array(CrystalClick::ObjectDocument),
      [
        [] of CrystalClick::ObjectDocument,
        [] of CrystalClick::ObjectDocument,
      ] of Array(CrystalClick::ObjectDocument),
      [
        [document.call(201_u8), document.call(202_u8), document.call(203_u8)] of CrystalClick::ObjectDocument,
        [] of CrystalClick::ObjectDocument,
      ] of Array(CrystalClick::ObjectDocument),
      [
        [document.call(211_u8)] of CrystalClick::ObjectDocument,
        [document.call(212_u8)] of CrystalClick::ObjectDocument,
      ] of Array(CrystalClick::ObjectDocument),
    ] of Array(Array(CrystalClick::ObjectDocument))
    expected = [
      [[] of String, ["D(J(101))"] of String],
      [[] of String, [] of String],
      [["D(J(201))", "D(J(202))", "D(J(203))"] of String, [] of String],
      [["D(J(211))"] of String, ["D(J(212))"] of String],
    ] of Array(Array(String))
    q = w215p_array_object_child_rows(granules)
    q.should eq([1_u64, 0_u64, 3_u64, 2_u64])
    q[1].should eq(0_u64)
    q[0].should eq(1_u64)
    q[2].should be > 2_u64

    profiles = [
      CrystalClick::BinaryBulkProfile.single_stream,
      CrystalClick::BinaryBulkProfile.with_size_stream,
    ] of CrystalClick::BinaryBulkProfile
    w215p_with_parent do |parent|
      profiles.each_with_index do |profile, profile_index|
        files = CrystalClick::ArrayObjectColumnWriter.encode(
          "a", plan, granules,
          mode: CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
          profile: profile,
          shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
          frame_bytes: 64,
        )
        files.stream_names.should contain("a.size0")
        files.stream_names.each do |stream|
          w215p_mark_rows(files.pair_for(stream).marks).should eq([2_u64, 2_u64, 2_u64, 2_u64, 0_u64])
        end

        part_index = profile_index + 1
        part = File.join(parent, "all_#{part_index}_#{part_index}_0")
        CrystalClick::WidePartWriter.write_uint64_array_object_pair(
          part,
          "pk",
          Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64, 8_u64],
          "a",
          schema,
          plan,
          granules,
          rows_per_mark: 2,
          mode: CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
          profile: profile,
          shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
          frame_bytes: 64,
        ).should eq(part)

        reader = CrystalClick::ArrayObjectColumnReader.open(part, "a", schema)
        reader.schema_declaration.should eq("Array(#{schema.declaration})")
        reader.row_count.should eq(8_u64)
        reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])
        reader.child_occurrence_row_counts(0, 4).should eq(q)
        reader.physical_stream_names.each do |stream|
          marks_path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
          w215p_mark_rows(File.read(marks_path).to_slice).should eq([2_u64, 2_u64, 2_u64, 2_u64, 0_u64])
        end
        w215p_array_object_signatures(reader.read_marks(0, 4)).should eq(expected)
        w215p_array_object_signatures(reader.read_marks(1, 2)).should eq(expected[1, 2])
        reader.read_marks(4, 0).should be_empty

        table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "a"])
        table.total_row_count.should eq(8_u64)
        table.column_types.should eq([
          {"pk", "UInt64"},
          {"a", "Array(#{schema.declaration})"},
        ])
        observed = [] of Array(String)
        table.scan_typed do |batch|
          batch.array_object_documents_for("a").each do |parents|
            observed << parents.map { |document| w215p_signature(document.value_for("p")) }
          end
          nil
        end
        observed.should eq(expected.flat_map { |mark| mark })
        window = [] of Array(String)
        table.scan_typed_window(4_u64, 4) do |batch|
          batch.array_object_documents_for("a").each do |parents|
            window << parents.map { |document| w215p_signature(document.value_for("p")) }
          end
          nil
        end
        window.should eq(expected[2, 2].flat_map { |mark| mark })
        table.scan_typed_window(8_u64, 1) { raise "EOF table window unexpectedly materialized a batch" }
      end
    end
  end

  it "keeps a bound JSON child's shared String lanes single-stream under both parent profiles" do
    json = w215p_json_type
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    schema = CrystalClick::ObjectDocumentSchema.new({"p" => dynamic} of String => CrystalClick::BinaryDataType)
    roster = CrystalClick::DynamicStructure.new([json] of CrystalClick::BinaryDataType)
    structures = w215p_empty_structures
    child_plan = CrystalClick::ObjectDocumentPlan.new(
      structures,
      json.json_type.not_nil!.typed_paths,
    )
    binding = {
      CrystalClick::BinaryDynamicJsonLeafKey.new("root", roster.canonical_index_for(json), [] of Int32),
      child_plan,
    }
    plan = CrystalClick::ObjectDocumentPlan.new(
      structures,
      schema.typed_paths,
      {"p" => roster} of String => CrystalClick::DynamicStructure,
      typed_dynamic_json_object_leaf_plans: {
        "p" => [binding] of W215PLeafPlan,
      } of String => Array(W215PLeafPlan),
    )
    document = ->(value : UInt8, note : String) {
      CrystalClick::ObjectDocument.new({
        "p" => CrystalClick::BinaryValue.dynamic(dynamic, w215p_json_with_note(json, value, note)),
      } of String => CrystalClick::BinaryValue)
    }
    rows = [
      [document.call(7_u8, "shared-child-first"), document.call(8_u8, "shared-child-middle")] of CrystalClick::ObjectDocument,
      [document.call(9_u8, "shared-child-final"), document.call(10_u8, "shared-child-eof")] of CrystalClick::ObjectDocument,
    ] of Array(CrystalClick::ObjectDocument)
    expected = [
      {7_u8, "shared-child-first"},
      {8_u8, "shared-child-middle"},
      {9_u8, "shared-child-final"},
      {10_u8, "shared-child-eof"},
    ] of Tuple(UInt8, String)
    profiles = [
      CrystalClick::BinaryBulkProfile.single_stream,
      CrystalClick::BinaryBulkProfile.with_size_stream,
    ] of CrystalClick::BinaryBulkProfile

    w215p_with_parent do |parent|
      profiles.each_with_index do |profile, profile_index|
        part = File.join(parent, "all_#{profile_index + 1}_#{profile_index + 1}_0")
        CrystalClick::WidePartWriter.write_uint64_object_pair(
          part,
          "pk",
          Slice[1_u64, 2_u64, 3_u64, 4_u64],
          "payload",
          schema,
          plan,
          rows,
          rows_per_mark: 2,
          mode: CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
          profile: profile,
          frame_bytes: 64,
        ).should eq(part)

        physical = CrystalClick::ObjectDocumentPhysicalPlan.new("payload", plan, profile)
        child_sites = physical.typed_dynamic("p").json_object_sites
        child_sites.size.should eq(1)
        child_shared_names = child_sites.first.physical_plan.shared.stream_names.values.sort
        child_shared_names.size.should eq(3)
        child_shared_names.any?(&.ends_with?(".object_shared_data.size0")).should be_true
        child_shared_names.any?(&.ends_with?(".object_shared_data%2Epaths")).should be_true
        child_shared_names.any?(&.ends_with?(".object_shared_data%2Evalues")).should be_true
        child_shared_names.any? do |name|
          name.ends_with?(".object_shared_data%2Epaths.size") ||
            name.ends_with?(".object_shared_data%2Evalues.size")
        end.should be_false

        reader = CrystalClick::ObjectColumnReader.open(part, "payload", schema)
        reader.mark_row_counts.should eq([2_u64, 2_u64])
        reader.physical_stream_names.sort.should eq(physical.stream_names)
        substreams = File.read(File.join(part, "columns_substreams.txt"))
        child_shared_names.each { |name| substreams.should contain(name) }
        child_sites.first.physical_plan.stream_names.each do |name|
          base = CrystalClick::StreamName.hash(name)
          File.exists?(File.join(part, "#{base}.bin")).should be_true
          File.exists?(File.join(part, "#{base}.mrk2")).should be_true
          w215p_mark_rows(File.read(File.join(part, "#{base}.mrk2")).to_slice).should eq([2_u64, 2_u64, 0_u64])
        end

        signature = ->(marks : Array(Array(CrystalClick::ObjectDocument))) {
          marks.flat_map { |mark| mark.map { |row| w215p_note_signature(row.value_for("p")) } }
        }
        signature.call(reader.read_marks(0, 2)).should eq(expected)
        signature.call(reader.read_marks(1, 1)).should eq(expected[2, 2])
        reader.read_marks(2, 0).should be_empty

        table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
        observed = [] of Tuple(UInt8, String)
        table.scan_typed do |batch|
          batch.object_documents_for("payload").each do |row|
            observed << w215p_note_signature(row.value_for("p"))
          end
        end
        observed.should eq(expected)
      end
    end
  end
end
