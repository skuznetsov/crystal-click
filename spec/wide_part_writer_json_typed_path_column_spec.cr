require "spec"
require "../src/crystal_click/wide_part_writer/json_typed_path_column"

describe CrystalClick::WidePartWriter::JSONTypedPathColumn do
  it "copies homogeneous and heterogeneous allowed values into owned storage" do
    homogeneous = Array(Int16).new
    homogeneous << 4_i16
    homogeneous << 9_i16
    homogeneous_column = CrystalClick::WidePartWriter::JSONTypedPathColumn.new(
      "homogeneous", "Int16", homogeneous
    )

    heterogeneous = Array(Int16 | String).new
    heterogeneous << 7_i16
    heterogeneous << "x\0y"
    heterogeneous_column = CrystalClick::WidePartWriter::JSONTypedPathColumn.new(
      "heterogeneous", "String", heterogeneous
    )

    homogeneous_column.values.should eq([4_i16, 9_i16])
    homogeneous_column.name.should eq("homogeneous")
    homogeneous_column.type_name.should eq("Int16")
    heterogeneous_column.values.size.should eq(2)
    heterogeneous_column.values[0].should eq(7_i16)
    heterogeneous_column.values[1].should eq("x\0y")

    homogeneous[0] = 12_i16
    heterogeneous[0] = 13_i16
    heterogeneous[1] = "changed"

    homogeneous_column.values.should eq([4_i16, 9_i16])
    heterogeneous_column.values[0].should eq(7_i16)
    heterogeneous_column.values[1].should eq("x\0y")
  end

  it "retains every value-alias member without the writer facade" do
    values = [
      -1_i8, -2_i16, -3_i32, -4_i64,
      1_u8, 2_u16, 3_u32, 4_u64,
      1.25_f32, 2.5_f64, "opaque\0bytes",
    ] of CrystalClick::WidePartWriter::JSONTypedPathValue
    column = CrystalClick::WidePartWriter::JSONTypedPathColumn.new("all", "retained", values)
    column.values.should eq(values)
    column.values.map { |value| value.class.to_s }.should eq([
      "Int8", "Int16", "Int32", "Int64", "UInt8", "UInt16", "UInt32", "UInt64",
      "Float32", "Float64", "String",
    ])
    column.values.object_id.should_not eq(values.object_id)

    empty = CrystalClick::WidePartWriter::JSONTypedPathColumn.new("empty", "String", [] of String)
    empty.values.should be_empty
  end
end
