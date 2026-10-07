require "file_utils"
require "./spec_helper"

private def w214p_json_type : CrystalClick::BinaryDataType
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  CrystalClick::BinaryDataType.json(
    max_dynamic_paths: 1,
    max_dynamic_types: 1,
    typed_paths: {
      "id"    => uint8,
      "maybe" => CrystalClick::BinaryDataType.nullable(uint8),
    } of String => CrystalClick::BinaryDataType,
  )
end

private def w214p_json(type : CrystalClick::BinaryDataType, id : UInt8) : CrystalClick::BinaryValue
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  nullable_uint8 = CrystalClick::BinaryDataType.nullable(uint8)
  row = CrystalClick::BinaryJsonRow.new(
    type,
    [
      {"id", CrystalClick::BinaryValue.fixed(uint8, Bytes[id])},
      {"maybe", CrystalClick::BinaryValue.null(nullable_uint8)},
      {"counter", CrystalClick::BinaryValue.int64(id.to_i64 * 10_i64 + 1_i64)},
    ] of Tuple(String, CrystalClick::BinaryValue),
  )
  CrystalClick::BinaryValue.json(type, row)
end

private struct W214PhysicalFixture
  getter schema : CrystalClick::ObjectDocumentSchema
  getter plan : CrystalClick::ObjectDocumentPlan
  getter granules : Array(Array(CrystalClick::ObjectDocument))
  getter expected : Array(Array(String))

  def initialize
    json = w214p_json_type
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    outer_array = CrystalClick::BinaryDataType.array(dynamic)
    empty_roster = CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)
    @schema = CrystalClick::ObjectDocumentSchema.new({
      "p"     => dynamic,
      "outer" => outer_array,
    } of String => CrystalClick::BinaryDataType)
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    )
    @plan = CrystalClick::ObjectDocumentPlan.new(
      structures,
      @schema.typed_paths,
      {"p" => empty_roster} of String => CrystalClick::DynamicStructure,
      typed_dynamic_sites: {
        "outer" => {"root.elements" => empty_roster} of String => CrystalClick::DynamicStructure,
      } of String => Hash(String, CrystalClick::DynamicStructure),
    )

    direct = ->(value : CrystalClick::BinaryValue?) {
      CrystalClick::BinaryValue.dynamic(dynamic, value)
    }
    array = ->(items : Array(CrystalClick::BinaryValue)) {
      CrystalClick::BinaryValue.array(outer_array, items)
    }
    document = ->(p : CrystalClick::BinaryValue, outer : CrystalClick::BinaryValue) {
      CrystalClick::ObjectDocument.new({"p" => p, "outer" => outer} of String => CrystalClick::BinaryValue)
    }
    j = ->(id : UInt8) { w214p_json(json, id) }
    @granules = [
      [
        document.call(direct.call(j.call(1_u8)), array.call([direct.call(j.call(11_u8)), direct.call(nil)] of CrystalClick::BinaryValue)),
        document.call(direct.call(nil), array.call([] of CrystalClick::BinaryValue)),
      ] of CrystalClick::ObjectDocument,
      [
        document.call(direct.call(j.call(2_u8)), array.call([direct.call(j.call(21_u8)), direct.call(j.call(22_u8))] of CrystalClick::BinaryValue)),
        document.call(direct.call(j.call(3_u8)), array.call([direct.call(nil), direct.call(j.call(31_u8)), direct.call(j.call(32_u8))] of CrystalClick::BinaryValue)),
      ] of CrystalClick::ObjectDocument,
      [
        document.call(direct.call(j.call(4_u8)), array.call([direct.call(j.call(41_u8))] of CrystalClick::BinaryValue)),
        document.call(direct.call(nil), array.call([direct.call(j.call(51_u8)), direct.call(j.call(52_u8)), direct.call(j.call(53_u8))] of CrystalClick::BinaryValue)),
      ] of CrystalClick::ObjectDocument,
    ] of Array(CrystalClick::ObjectDocument)
    @expected = [
      ["D(J(1,11,N))", "A[D(J(11,111,N)),DNULL]"],
      ["DNULL", "A[]"],
      ["D(J(2,21,N))", "A[D(J(21,211,N)),D(J(22,221,N))]"],
      ["D(J(3,31,N))", "A[DNULL,D(J(31,311,N)),D(J(32,321,N))]"],
      ["D(J(4,41,N))", "A[D(J(41,411,N))]"],
      ["DNULL", "A[D(J(51,511,N)),D(J(52,521,N)),D(J(53,531,N))]"],
    ] of Array(String)
  end
end

private def w214p_signature(value : CrystalClick::BinaryValue) : String
  case value.type.tag
  when CrystalClick::BinaryDataType::TAG_DYNAMIC
    value.is_null? ? "DNULL" : "D(#{w214p_signature(value.child_at(0))})"
  when CrystalClick::BinaryDataType::TAG_ARRAY
    children = (0...value.element_count).map { |index| w214p_signature(value.element_at(index)) }
    "A[#{children.join(",")}]"
  when CrystalClick::BinaryDataType::TAG_JSON
    row = value.json_row
    id = row.value_for("id").not_nil!.byte_at(0)
    counter = row.value_for("counter").not_nil!.as_int64
    maybe = row.value_for("maybe").not_nil!.is_null? ? "N" : "V"
    "J(#{id},#{counter},#{maybe})"
  else
    raise "unexpected W214 physical value type: #{value.type.name}"
  end
end

private def w214p_signatures(rows : Array(Array(CrystalClick::ObjectDocument))) : Array(Array(String))
  rows.flat_map do |mark|
    mark.map do |document|
      [w214p_signature(document.value_for("p")), w214p_signature(document.value_for("outer"))]
    end
  end
end

private def w214p_with_parent(&)
  parent = File.tempname("crystal-click-w214-shared-json-")
  Dir.mkdir(parent)
  begin
    yield parent
  ensure
    FileUtils.rm_rf(parent)
  end
end

describe "W214 declared Object Dynamic inline SharedVariant JSON physical readers" do
  it "persists literal JSON values and metadata through complete part, bounded windows, and typed table reads" do
    fixture = W214PhysicalFixture.new
    profiles = [
      CrystalClick::BinaryBulkProfile.single_stream,
      CrystalClick::BinaryBulkProfile.with_size_stream,
    ] of CrystalClick::BinaryBulkProfile

    w214p_with_parent do |parent|
      profiles.each_with_index do |profile, profile_index|
        part = File.join(parent, "all_#{profile_index + 1}_#{profile_index + 1}_0")
        CrystalClick::WidePartWriter.write_uint64_object_pair(
          part,
          "pk",
          Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64],
          "payload",
          fixture.schema,
          fixture.plan,
          fixture.granules,
          rows_per_mark: 2,
          mode: CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE,
          profile: profile,
          frame_bytes: 64,
        ).should eq(part)

        File.read(File.join(part, "count.txt")).should eq("6")
        File.read(File.join(part, "columns.txt")).should contain(fixture.schema.declaration)
        reader = CrystalClick::ObjectColumnReader.open(part, "payload", fixture.schema)
        reader.source_declaration.should eq(fixture.schema.declaration)
        reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64])
        physical = CrystalClick::ObjectDocumentPhysicalPlan.new("payload", fixture.plan, profile)
        reader.physical_stream_names.should eq(physical.stream_names)
        shared_name = physical.stream_names.find { |name| name.ends_with?(".SharedVariant") }
        shared_name.should_not be_nil
        File.read(File.join(part, "columns_substreams.txt")).should contain(shared_name.not_nil!)
        reader.physical_stream_names.none? do |name|
          name.ends_with?(".id") || name.ends_with?(".maybe") || name.ends_with?(".counter")
        end.should be_true

        full = CrystalClick::ObjectDocumentFileReader.read(
          part,
          "payload",
          fixture.schema.typed_paths,
          profile: profile,
          first_mark: 0,
          mark_count: 3,
          hashed: true,
        )
        w214p_signatures(full).should eq(fixture.expected)
        w214p_signatures(CrystalClick::ObjectDocumentFileReader.read(
          part, "payload", fixture.schema.typed_paths,
          first_mark: 1, mark_count: 1, profile: profile, hashed: true,
        )).should eq(fixture.expected[2, 2])
        w214p_signatures(CrystalClick::ObjectDocumentFileReader.read(
          part, "payload", fixture.schema.typed_paths,
          first_mark: 2, mark_count: 1, profile: profile, hashed: true,
        )).should eq(fixture.expected[4, 2])
        CrystalClick::ObjectDocumentFileReader.read(
          part, "payload", fixture.schema.typed_paths,
          first_mark: 3, mark_count: 0, profile: profile, hashed: true,
        ).should be_empty

        w214p_signatures(reader.read_marks(0, 3)).should eq(fixture.expected)
        w214p_signatures(reader.read_marks(1, 1)).should eq(fixture.expected[2, 2])
        w214p_signatures(reader.read_marks(2, 1)).should eq(fixture.expected[4, 2])
        reader.read_marks(3, 0).should be_empty

        table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
        table.total_row_count.should eq(6_u64)
        observed = [] of Array(String)
        table.scan_typed do |batch|
          batch.object_documents_for("payload").each do |document|
            observed << [w214p_signature(document.value_for("p")), w214p_signature(document.value_for("outer"))]
          end
        end
        observed.should eq(fixture.expected)
        [
          {2_u64, fixture.expected[2, 2]},
          {4_u64, fixture.expected[4, 2]},
        ].each do |start_row, expected|
          window = [] of Array(String)
          table.scan_typed_window(start_row, 2) do |batch|
            batch.object_documents_for("payload").each do |document|
              window << [w214p_signature(document.value_for("p")), w214p_signature(document.value_for("outer"))]
            end
          end
          window.should eq(expected)
        end
        table.scan_typed_window(6_u64, 1) { raise "EOF table window unexpectedly materialized a batch" }
      end
    end
  end
end
