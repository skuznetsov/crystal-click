require "./spec_helper"

private def w95_mutate_string_byte(value : String, byte : UInt8) : Nil
  raise "W95 mutation fixture must be non-empty" if value.empty?
  value.to_unsafe[0] = byte
end

private def w95_row_sample_data : CrystalClick::WideTupleColumnData
  plan = CrystalClick::WideTupleTypePlan.for_type(
    "Tuple(label String, count UInt64, payload String)"
  ).not_nil!
  columns = [
    CrystalClick::WideTupleLeafColumn.new(
      "label", ["first", String.new(Bytes[0x6d_u8, 0_u8, 0xff_u8]), "third"] of String
    ),
    CrystalClick::WideTupleLeafColumn.new("count", [7_u64, UInt64::MAX, 9_u64]),
    CrystalClick::WideTupleLeafColumn.new("payload", ["", String.new(Bytes[0_u8, 0x72_u8, 0xff_u8]), "tail"] of String),
  ] of CrystalClick::WideTupleLeafColumn
  CrystalClick::WideTupleColumnData.new(plan, columns)
end

private def w95_row_after_data_scope : CrystalClick::WideTupleRow
  data = w95_row_sample_data
  data.row(1)
end

private def w95_row_field_signature(row : CrystalClick::WideTupleRow) : Array(Tuple(String, String))
  row.fields.map { |field| {field.name, field.type_name} }
end

private def w95_row_identity(row : CrystalClick::WideTupleRow) : Tuple(String, Bool)
  {typeof(row).name, {{ CrystalClick::WideTupleRow.struct? }}}
end

describe "W95 named Tuple rows" do
  it "returns an immutable nominal value-semantic row with declaration-ordered fields" do
    row = w95_row_after_data_scope

    w95_row_identity(row).should eq({"CrystalClick::WideTupleRow", true})
    row.type_name.should eq("Tuple(label String, count UInt64, payload String)")
    row.field_count.should eq(3)
    row.string_bytesize.should eq(6_u64)
    w95_row_field_signature(row).should eq([
      {"label", "String"},
      {"count", "UInt64"},
      {"payload", "String"},
    ])
    row["label"].should eq(String.new(Bytes[0x6d_u8, 0_u8, 0xff_u8]))
    row["count"].should eq(UInt64::MAX)
    row["payload"].should eq(String.new(Bytes[0_u8, 0x72_u8, 0xff_u8]))
  end

  it "copies returned String bytes and field names without mutating a retained row" do
    row = w95_row_after_data_scope

    exposed_label = row["label"].as(String)
    exposed_payload = row["payload"].as(String)
    exposed_name = row.fields[0].name
    exposed_type_name = row.type_name
    w95_mutate_string_byte(exposed_label, 0x58_u8)
    w95_mutate_string_byte(exposed_payload, 0x59_u8)
    w95_mutate_string_byte(exposed_name, 0x5a_u8)
    w95_mutate_string_byte(exposed_type_name, 0x58_u8)

    row["label"].should eq(String.new(Bytes[0x6d_u8, 0_u8, 0xff_u8]))
    row["payload"].should eq(String.new(Bytes[0_u8, 0x72_u8, 0xff_u8]))
    row.type_name.should eq("Tuple(label String, count UInt64, payload String)")
    row.string_bytesize.should eq(6_u64)
    w95_row_field_signature(row).should eq([
      {"label", "String"},
      {"count", "UInt64"},
      {"payload", "String"},
    ])
  end

  it "owns source arrays, source Strings, and names independently of the backing data" do
    plan = CrystalClick::WideTupleTypePlan.for_type("Tuple(label String, count UInt64, payload String)").not_nil!
    label_name = String.new("label".to_slice)
    label_source = String.new(Bytes[0x6d_u8, 0_u8, 0xff_u8])
    payload_source = String.new(Bytes[0_u8, 0x72_u8, 0xff_u8])
    label_values = ["first", label_source, "third"] of String
    counts = [7_u64, UInt64::MAX, 9_u64]
    payload_values = ["", payload_source, "tail"] of String
    columns = [
      CrystalClick::WideTupleLeafColumn.new(label_name, label_values),
      CrystalClick::WideTupleLeafColumn.new("count", counts),
      CrystalClick::WideTupleLeafColumn.new("payload", payload_values),
    ] of CrystalClick::WideTupleLeafColumn
    data = CrystalClick::WideTupleColumnData.new(plan, columns)
    row = data.row(1)

    w95_mutate_string_byte(label_name, 0x58_u8)
    w95_mutate_string_byte(label_source, 0x59_u8)
    w95_mutate_string_byte(payload_source, 0x5a_u8)
    label_values[1] = "replacement"
    counts[1] = 0_u64
    payload_values[1] = "replacement"

    w95_row_field_signature(row).should eq([
      {"label", "String"},
      {"count", "UInt64"},
      {"payload", "String"},
    ])
    row["label"].should eq(String.new(Bytes[0x6d_u8, 0_u8, 0xff_u8]))
    row["count"].should eq(UInt64::MAX)
    row["payload"].should eq(String.new(Bytes[0_u8, 0x72_u8, 0xff_u8]))
    data.value_at("count", 1).should eq(UInt64::MAX)
  end

  it "rejects invalid indices before narrowing and reports unknown fields" do
    data = w95_row_sample_data

    expect_raises(CrystalClick::BoundsError) { data.row(-1) }
    expect_raises(CrystalClick::BoundsError) { data.row(Int64::MAX) }
    expect_raises(CrystalClick::BoundsError) { data.row(UInt64::MAX) }
    expect_raises(CrystalClick::BoundsError) { data.row(data.row_count) }
    expect_raises(CrystalClick::BoundsError) { CrystalClick::WideTupleRow.new(data, -1) }
    expect_raises(CrystalClick::BoundsError) { CrystalClick::WideTupleRow.new(data, Int64::MAX) }
    expect_raises(CrystalClick::BoundsError) { CrystalClick::WideTupleRow.new(data, UInt64::MAX) }
    expect_raises(CrystalClick::BoundsError) { CrystalClick::WideTupleRow.new(data, data.row_count) }
    expect_raises(KeyError) { data.row(0)["missing"] }
  end
end
