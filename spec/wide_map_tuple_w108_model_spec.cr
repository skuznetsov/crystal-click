require "./spec_helper"

describe CrystalClick::WideMapTupleTypePlan do
  it "retains Map identity while composing exact key and recursive Tuple streams" do
    declaration = "Map(String, Tuple(meta Tuple(note Nullable(String), amount Decimal(18, 3)), at DateTime64(3, 'America/New_York')))"
    plan = CrystalClick::WideMapTupleTypePlan.for_type(declaration).not_nil!

    plan.column_type.should eq(declaration)
    plan.type_name.should eq(declaration)
    plan.key_type.type_name.should eq("String")
    plan.tuple_plan.type_name.should eq("Tuple(meta Tuple(note Nullable(String), amount Decimal(18, 3)), at DateTime64(3, 'America/New_York'))")
    plan.physical_streams("payload").should eq([
      "payload.size0",
      "payload%2Ekeys.size",
      "payload%2Ekeys",
      "payload%2Evalues%2Emeta%2Enote.null",
      "payload%2Evalues%2Emeta%2Enote.size",
      "payload%2Evalues%2Emeta%2Enote",
      "payload%2Evalues%2Emeta%2Eamount",
      "payload%2Evalues%2Eat",
    ])
    plan.raw_string_stream?("payload", "payload%2Ekeys").should be_true
    plan.raw_string_stream?("payload", "payload%2Evalues%2Emeta%2Enote").should be_true
    plan.stream_width("payload", "payload%2Ekeys").should eq(1)
    plan.stream_width("payload", "payload%2Evalues%2Emeta%2Enote.null").should eq(1)
    plan.stream_width("payload", "payload%2Evalues%2Emeta%2Eamount").should eq(8)
    plan.stream_width("payload", "payload%2Evalues%2Eat").should eq(8)

    detached_name = plan.column_type
    detached_name.to_unsafe[0] = 'X'.ord.to_u8
    plan.column_type.should eq(declaration)
    plan.key_type.type_name.should eq("String")
  end

  it "uses the exact fixed-width descriptor for non-String keys without adding a String size stream" do
    declaration = "Map(FixedString(5), Tuple(value UInt64))"
    plan = CrystalClick::WideMapTupleTypePlan.for_type(declaration).not_nil!

    plan.column_type.should eq(declaration)
    plan.physical_streams("payload").should eq([
      "payload.size0",
      "payload%2Ekeys",
      "payload%2Evalues%2Evalue",
    ])
    plan.stream_width("payload", "payload%2Ekeys").should eq(5)
    plan.raw_string_stream?("payload", "payload%2Ekeys").should be_false
    plan.key_type.parameterized_type.not_nil!.as(CrystalClick::WideTupleFixedStringType).width.should eq(5)
  end

  it "keeps Map parser admission closed at the complete declaration boundary" do
    tuple = "Tuple(left Tuple(code UInt64, note Nullable(String)), right DateTime64(9, 'America/New_York'))"
    CrystalClick::WideMapTupleTypePlan.for_type("Map(UInt64, #{tuple})").should_not be_nil

    [
      "Map(Nullable(String), #{tuple})",
      "Map(String, Nullable(#{tuple}))",
      "Map(String, Tuple(value Array(UInt64)))",
      "Map(String, Tuple(value Map(String, UInt64)))",
      "Map(String, Tuple(value UInt64, value String))",
      "Map(String, Tuple())",
      "Map(String, Tuple(UInt64, String))",
      "Map(String, Tuple(value DateTime64(10)))",
      "Map(String, Tuple(value DateTime('Definitely/Not_A_Zone')))",
    ].each do |unsupported|
      CrystalClick::WideMapTupleTypePlan.for_type(unsupported).should be_nil
      CrystalClick::WidePart.supports_typed_type?(unsupported).should be_false
    end

    oversized = "Map(String, Tuple(value UInt64))" + (" " * CrystalClick::WideTupleSchemaParser::MAX_SOURCE_BYTES)
    CrystalClick::WideMapTupleTypePlan.for_type(oversized).should be_nil
  end

  it "preserves indexed duplicate entries and charges physical Nullable String bytes" do
    type_name = "Map(String, Tuple(note Nullable(String)))"
    plan = CrystalClick::WideMapTupleTypePlan.for_type(type_name).not_nil!
    key_column = CrystalClick::WideTupleLeafColumn.new("keys", ["k", "k"] of String)
    note_type = CrystalClick::WideTupleLeafType.parse("Nullable(String)").not_nil!
    note_map = CrystalClick::ScalarNullMap.new(Bytes[1_u8, 0_u8], 2_u64)
    note_column = CrystalClick::WideTupleLeafColumn.new("note", note_type, ["hidden", "visible"] of String, note_map)
    tuple_data = CrystalClick::WideTupleColumnData.new(plan.tuple_plan, [note_column])
    data = CrystalClick::WideMapTupleColumnData.new(plan, key_column, tuple_data, [2_u64])
    row = data.row(0)

    row[0][0].should eq("k")
    row[0][1]["note"].should be_nil
    row[1][0].should eq("k")
    row[1][1]["note"].should eq("visible")
    row.string_bytesize.should eq(15_u64)
    expect_raises(CrystalClick::UnsupportedFormatError) { row.key_as(0, UInt64) }
  end
end
