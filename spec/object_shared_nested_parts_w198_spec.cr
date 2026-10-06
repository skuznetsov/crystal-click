require "./spec_helper"

private def w198_part_schema : CrystalClick::ObjectDocumentSchema
  CrystalClick::ObjectDocumentSchema.new(
    {} of String => CrystalClick::BinaryDataType,
    max_dynamic_paths: 0,
    max_dynamic_types: 1,
  )
end

private def w198_part_plan(
  schema : CrystalClick::ObjectDocumentSchema,
  shared_version : UInt64,
) : CrystalClick::ObjectDocumentPlan
  object = CrystalClick::ObjectStructure.new(
    [] of String,
    shared_data_version: shared_version,
    bucket_count: 2_u64,
  )
  CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      object,
      {} of String => CrystalClick::DynamicStructure,
    ),
    schema.typed_paths,
  )
end

private def w198_actual_type(kind : String) : CrystalClick::BinaryDataType
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  string = CrystalClick::BinaryDataType.primitive("String")
  fields = [uint8, string] of CrystalClick::BinaryDataType
  names = ["n", "s"] of String
  case kind
  when "nested"
    CrystalClick::BinaryDataType.nested(fields, names)
  when "array_tuple"
    CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.tuple(fields, names))
  else
    raise ArgumentError.new("unknown W198 actual kind")
  end
end

private def w198_record(
  actual_type : CrystalClick::BinaryDataType,
  number : UInt8,
  text : String,
) : CrystalClick::BinaryValue
  tuple_type = actual_type.child_at(0)
  CrystalClick::BinaryValue.tuple(tuple_type, [
    CrystalClick::BinaryValue.fixed(
      CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[number]
    ),
    CrystalClick::BinaryValue.string(text),
  ] of CrystalClick::BinaryValue)
end

private def w198_composite(
  actual_type : CrystalClick::BinaryDataType,
  records : Array(CrystalClick::BinaryValue),
) : CrystalClick::BinaryValue
  if actual_type.tag == CrystalClick::BinaryDataType::TAG_NESTED
    CrystalClick::BinaryValue.nested(actual_type, records)
  else
    CrystalClick::BinaryValue.array(actual_type, records)
  end
end

private def w198_document(value : CrystalClick::BinaryValue? = nil) : CrystalClick::ObjectDocument
  fields = Hash(String, CrystalClick::BinaryValue).new
  fields["n"] = value if value
  CrystalClick::ObjectDocument.new(fields)
end

private def w198_granules(actual_type : CrystalClick::BinaryDataType) : Array(Array(CrystalClick::ObjectDocument))
  one = w198_composite(actual_type, [w198_record(actual_type, 7_u8, "one")] of CrystalClick::BinaryValue)
  empty = w198_composite(actual_type, [] of CrystalClick::BinaryValue)
  four = w198_composite(actual_type, [w198_record(actual_type, 9_u8, "four")] of CrystalClick::BinaryValue)
  two = w198_composite(actual_type, [
    w198_record(actual_type, 11_u8, "a"),
    w198_record(actual_type, 12_u8, "bb"),
  ] of CrystalClick::BinaryValue)
  last = w198_composite(actual_type, [w198_record(actual_type, 0_u8, "")] of CrystalClick::BinaryValue)

  [
    [w198_document(one), w198_document] of CrystalClick::ObjectDocument,
    [w198_document(empty), w198_document(four)] of CrystalClick::ObjectDocument,
    [w198_document(two), w198_document] of CrystalClick::ObjectDocument,
    [w198_document(empty), w198_document(last)] of CrystalClick::ObjectDocument,
  ] of Array(CrystalClick::ObjectDocument)
end

private def w198_assert_missing(document : CrystalClick::ObjectDocument) : Nil
  document.has_path?("n").should be_false
end

private def w198_assert_value(
  document : CrystalClick::ObjectDocument,
  actual_type : CrystalClick::BinaryDataType,
  expected : Array(Tuple(UInt8, String)),
) : Nil
  document.has_path?("n").should be_true
  value = document.value_for("n")
  value.type.should eq(actual_type)
  value.type.name.should eq(actual_type.name)
  value.element_count.should eq(expected.size)

  expected.each_with_index do |record, index|
    tuple = value.element_at(index)
    tuple.type.should eq(actual_type.child_at(0))
    tuple.child_count.should eq(2)
    tuple.child_at(0).type.name.should eq("UInt8")
    tuple.child_at(0).bytes.should eq(Bytes[record[0]])
    tuple.child_at(1).type.name.should eq("String")
    tuple.child_at(1).as_string.should eq(record[1])
  end
end

private def with_w198_part_parent(label : String, & : String ->)
  parent = File.tempname("crystal-click-w198-nested-#{label}-")
  created = false
  Dir.mkdir(parent)
  created = true
  yield parent
ensure
  FileUtils.rm_rf(parent) if created && parent && Dir.exists?(parent)
end

describe "W198 complete-part Nested and Array(Tuple) composition" do
  it "preserves nominal actuals and authored rows through public full, middle, and zero reads" do
    schema = w198_part_schema
    profiles = [
      {2_u64, CrystalClick::BinaryBulkProfile.single_stream},
      {2_u64, CrystalClick::BinaryBulkProfile.with_size_stream},
      {3_u64, CrystalClick::BinaryBulkProfile.single_stream},
      {3_u64, CrystalClick::BinaryBulkProfile.with_size_stream},
    ] of Tuple(UInt64, CrystalClick::BinaryBulkProfile)

    ["nested", "array_tuple"].each do |kind|
      actual_type = w198_actual_type(kind)
      actual_type.name.should eq(
        kind == "nested" ? "Nested(n UInt8, s String)" : "Array(Tuple(n UInt8, s String))"
      )

      profiles.each do |profile_case|
        shared_version = profile_case[0]
        profile = profile_case[1]
        with_w198_part_parent("#{kind}-v#{shared_version}-s#{profile.with_size_stream?}") do |parent|
          part = File.join(parent, "all_1_1_0")
          plan = w198_part_plan(schema, shared_version)
          CrystalClick::WidePartWriter.write_uint64_object_pair(
            part,
            "pk",
            Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64, 8_u64],
            "j",
            schema,
            plan,
            w198_granules(actual_type),
            rows_per_mark: 2,
            profile: profile,
          ).should eq(part)

          reader = CrystalClick::ObjectColumnReader.open(part, "j", schema)
          reader.row_count.should eq(8_u64)
          reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])
          reader.ordinary_profile.should eq(profile)

          full = reader.read_marks(0, 4)
          full.size.should eq(4)
          full.each { |mark| mark.size.should eq(2) }
          w198_assert_value(full[0][0], actual_type, [{7_u8, "one"}] of Tuple(UInt8, String))
          w198_assert_missing(full[0][1])
          w198_assert_value(full[1][0], actual_type, [] of Tuple(UInt8, String))
          w198_assert_value(full[1][1], actual_type, [{9_u8, "four"}] of Tuple(UInt8, String))
          w198_assert_value(full[2][0], actual_type, [
            {11_u8, "a"}, {12_u8, "bb"},
          ] of Tuple(UInt8, String))
          w198_assert_missing(full[2][1])
          w198_assert_value(full[3][0], actual_type, [] of Tuple(UInt8, String))
          w198_assert_value(full[3][1], actual_type, [{0_u8, ""}] of Tuple(UInt8, String))

          middle = reader.read_marks(1, 2)
          middle.size.should eq(2)
          w198_assert_value(middle[0][0], actual_type, [] of Tuple(UInt8, String))
          w198_assert_value(middle[0][1], actual_type, [{9_u8, "four"}] of Tuple(UInt8, String))
          w198_assert_value(middle[1][0], actual_type, [
            {11_u8, "a"}, {12_u8, "bb"},
          ] of Tuple(UInt8, String))
          w198_assert_missing(middle[1][1])
          reader.read_marks(4, 0).should be_empty
        end
      end
    end
  end

  it "keeps Nested nominally distinct from its Array(Tuple) carrier" do
    nested = w198_actual_type("nested")
    array_tuple = w198_actual_type("array_tuple")
    nested.should_not eq(array_tuple)
    nested.name.should_not eq(array_tuple.name)
    nested.child_at(0).name.should eq(array_tuple.child_at(0).name)
  end
end
