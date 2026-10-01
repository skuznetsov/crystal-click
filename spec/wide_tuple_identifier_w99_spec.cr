require "./spec_helper"

private def w99_leaf_descriptor_charge(base_type_name : String) : UInt64
  instance_sizeof(CrystalClick::WideTupleLeafType).to_u64 +
    instance_sizeof(String).to_u64 + base_type_name.bytesize.to_u64 + 1_u64
end

private def w99_identifier_leaf_descriptor_bytes : UInt64
  w99_leaf_descriptor_charge("IPv6") +
    w99_leaf_descriptor_charge("IPv4") +
    w99_leaf_descriptor_charge("UUID")
end

private def w99_flat_tree_and_path_charge(field_names : Array(String)) : UInt64
  node_bytes = instance_sizeof(CrystalClick::WideTupleSchemaNode).to_u64
  node_children_bytes = instance_sizeof(Array(CrystalClick::WideTupleSchemaNode)).to_u64
  name_header_bytes = instance_sizeof(String).to_u64
  node_reference_bytes = sizeof(Pointer(CrystalClick::WideTupleSchemaNode)).to_u64
  path_header_bytes = instance_sizeof(Array(String)).to_u64
  path_reference_bytes = sizeof(Pointer(String)).to_u64

  total = node_bytes + node_children_bytes + field_names.size.to_u64 * node_reference_bytes
  field_names.each do |name|
    owned_name_bytes = name_header_bytes + name.bytesize.to_u64 + 1_u64
    total += node_bytes + node_children_bytes + owned_name_bytes
    total += path_header_bytes + path_reference_bytes + owned_name_bytes
  end
  total
end

private def w99_identifier_columns : Array(CrystalClick::WideTupleLeafColumn)
  ipv6_values = [
    CrystalClick::IPv6Value.new(0x20010db885a30000_u64, 0x00008a2e03707334_u64),
    CrystalClick::IPv6Value.new(0xfedcba9876543210_u64, 0x0123456789abcdef_u64),
    CrystalClick::IPv6Value.new(0_u64, 0_u64),
    CrystalClick::IPv6Value.new(UInt64::MAX, 0x0102030405060708_u64),
    CrystalClick::IPv6Value.new(0x8000000000000000_u64, 0xffff000000000001_u64),
  ]
  ipv4_values = [
    CrystalClick::IPv4Value.from_octets(1_u8, 2_u8, 3_u8, 4_u8),
    CrystalClick::IPv4Value.from_octets(4_u8, 3_u8, 2_u8, 1_u8),
    CrystalClick::IPv4Value.from_octets(0_u8, 0_u8, 0_u8, 0_u8),
    CrystalClick::IPv4Value.from_octets(255_u8, 255_u8, 255_u8, 255_u8),
    CrystalClick::IPv4Value.from_octets(192_u8, 168_u8, 1_u8, 7_u8),
  ]
  uuid_values = [
    CrystalClick::UUIDValue.new(0x0011223344556677_u64, 0x8899aabbccddeeff_u64),
    CrystalClick::UUIDValue.new(UInt64::MAX, 0_u64),
    CrystalClick::UUIDValue.new(0_u64, UInt64::MAX),
    CrystalClick::UUIDValue.new(0x0123456789abcdef_u64, 0xfedcba9876543210_u64),
    CrystalClick::UUIDValue.new(0x7f00ff01fe02fd03_u64, 0x04fc05fb06fa07f9_u64),
  ]

  [
    CrystalClick::WideTupleLeafColumn.new("v6", ipv6_values),
    CrystalClick::WideTupleLeafColumn.new("v4", ipv4_values),
    CrystalClick::WideTupleLeafColumn.new("id", uuid_values),
  ] of CrystalClick::WideTupleLeafColumn
end

private def w99_identifier_type_name(columns : Array(CrystalClick::WideTupleLeafColumn)) : String
  "Tuple(#{columns.map { |column| "#{column.name} #{column.type_name}" }.join(", ")})"
end

private def w99_identifier_write_part(
  parent : String,
  name : String,
  columns : Array(CrystalClick::WideTupleLeafColumn),
  rows_per_mark : Int32 = 2,
) : String
  row_count = columns.first?.try(&.size) || 0
  keys = Array(UInt64).new(row_count) { |index| index.to_u64 }
  part_container = File.join(parent, name)
  Dir.mkdir(part_container)
  destination = File.join(part_container, "all_1_1_0")
  CrystalClick::WidePartWriter.write_uint64_tuple_pair(
    destination,
    "pk",
    keys.to_unsafe.to_slice(keys.size),
    "payload",
    w99_identifier_type_name(columns),
    columns,
    rows_per_mark: rows_per_mark
  )
  destination
end

private def w99_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

private def w99_corrupt_mark_frame_header(part : String, stream : String, mark_index : Int) : Nil
  marks_path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(marks_path).to_slice
  offset = mark_index * CrystalClick::WidePart::MARK_SIZE
  compressed_offset = w99_read_u64(marks, offset).to_i
  data_path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")
  bytes = File.read(data_path).to_slice.dup
  decompressed_size_offset = compressed_offset + CrystalClick::CompressedBlock::CHECKSUM_SIZE + 5
  if compressed_offset < 0 || decompressed_size_offset > bytes.size - 4
    raise "W99 frame-header corruption target is outside the stream"
  end
  4.times { |index| bytes[decompressed_size_offset + index] = 0_u8 }
  File.write(data_path, bytes)
end

private def w99_identifier_row_after_data_scope : CrystalClick::WideTupleRow
  type_name = "Tuple(v6 IPv6, v4 IPv4, id UUID)"
  plan = CrystalClick::WideTupleTypePlan.for_type(type_name) || raise "W99 identifier Tuple plan is not admitted"
  CrystalClick::WideTupleColumnData.new(plan, w99_identifier_columns).row(2)
end

describe "W99 identifier and address Tuple plan" do
  it "preserves the existing primitive, Bool, and String leaf widths" do
    type_name = "Tuple(count UInt64, flag Bool, text String)"
    plan = CrystalClick::WideTupleTypePlan.for_type(type_name).not_nil!

    plan.fields.map(&.type_name).should eq(["UInt64", "Bool", "String"])
    plan.physical_streams("payload").should eq([
      "payload%2Ecount",
      "payload%2Eflag",
      "payload%2Etext.size",
      "payload%2Etext",
    ])
    plan.stream_width("payload", "payload%2Ecount").should eq(8)
    plan.stream_width("payload", "payload%2Eflag").should eq(1)
    plan.stream_width("payload", "payload%2Etext.size").should eq(8)
    plan.stream_width("payload", "payload%2Etext").should eq(1)
  end

  it "admits UUID as a distinct fixed-width Tuple leaf" do
    sizeof(CrystalClick::UUIDValue).should eq(16)
    type_name = "Tuple(value UUID)"
    plan = CrystalClick::WideTupleTypePlan.for_type(type_name)
    plan.should_not be_nil

    if plan
      plan.type_name.should eq(type_name)
      plan.fields.map { |field| {field.name, field.type_name} }.should eq([{"value", "UUID"}])
      plan.physical_streams("payload").should eq(["payload%2Evalue"])
      plan.stream_width("payload", "payload%2Evalue").should eq(16)
    end
  end

  it "admits IPv4 without relabeling its equal-width UInt32 neighbor" do
    sizeof(CrystalClick::IPv4Value).should eq(4)
    plan = CrystalClick::WideTupleTypePlan.for_type("Tuple(address IPv4)")
    plan.should_not be_nil

    if plan
      plan.fields.map(&.type_name).should eq(["IPv4"])
      plan.stream_width("payload", "payload%2Eaddress").should eq(4)
    end

    uint32 = CrystalClick::WideTupleTypePlan.for_type("Tuple(address UInt32)").not_nil!
    uint32.fields.map(&.type_name).should eq(["UInt32"])
    uint32.stream_width("payload", "payload%2Eaddress").should eq(4)
  end

  it "admits IPv6 without relabeling its equal-width UInt128 neighbor" do
    sizeof(CrystalClick::IPv6Value).should eq(16)
    plan = CrystalClick::WideTupleTypePlan.for_type("Tuple(address IPv6)")
    plan.should_not be_nil

    if plan
      plan.fields.map(&.type_name).should eq(["IPv6"])
      plan.stream_width("payload", "payload%2Eaddress").should eq(16)
    end

    uint128 = CrystalClick::WideTupleTypePlan.for_type("Tuple(address UInt128)").not_nil!
    uint128.fields.map(&.type_name).should eq(["UInt128"])
    uint128.stream_width("payload", "payload%2Eaddress").should eq(16)
  end

  it "keeps identifiers in a distinct closed nominal owner with zero defaults" do
    {
      {{ CrystalClick::WideTupleLeafColumn::Value.union_types.includes?(CrystalClick::UUIDValue) }},
      {{ CrystalClick::WideTupleLeafColumn::Value.union_types.includes?(CrystalClick::IPv4Value) }},
      {{ CrystalClick::WideTupleLeafColumn::Value.union_types.includes?(CrystalClick::IPv6Value) }},
      {{ CrystalClick::WideTupleLeafColumn::Buffer.union_types.includes?(Array(CrystalClick::UUIDValue)) }},
      {{ CrystalClick::WideTupleLeafColumn::Buffer.union_types.includes?(Array(CrystalClick::IPv4Value)) }},
      {{ CrystalClick::WideTupleLeafColumn::Buffer.union_types.includes?(Array(CrystalClick::IPv6Value)) }},
    }.should eq({true, true, true, true, true, true})

    {"UUID", "IPv4", "IPv6"}.each do |type_name|
      CrystalClick::WideTupleNumericType.width(type_name).should be_nil
    end
    CrystalClick::WideTupleIdentifierType.width("UUID").should eq(16)
    CrystalClick::WideTupleIdentifierType.width("IPv4").should eq(4)
    CrystalClick::WideTupleIdentifierType.width("IPv6").should eq(16)
    CrystalClick::WideTupleIdentifierType.type_name(CrystalClick::UUIDValue).should eq("UUID")
    CrystalClick::WideTupleIdentifierType.type_name(CrystalClick::IPv4Value).should eq("IPv4")
    CrystalClick::WideTupleIdentifierType.type_name(CrystalClick::IPv6Value).should eq("IPv6")

    CrystalClick::WideTupleIdentifierType.same_bits?(CrystalClick::UUIDValue.new(1_u64, 2_u64), CrystalClick::UUIDValue.new(1_u64, 2_u64)).should be_true
    CrystalClick::WideTupleIdentifierType.same_bits?(CrystalClick::UUIDValue.new(0_u64, 0_u64), CrystalClick::IPv6Value.new(0_u64, 0_u64)).should be_false
    CrystalClick::WideTupleIdentifierType.same_bits?(CrystalClick::IPv4Value.new(0x01020304_u32), CrystalClick::IPv4Value.new(0x01020304_u32)).should be_true

    CrystalClick::WideTupleIdentifierType.is_default?(CrystalClick::UUIDValue.new(0_u64, 0_u64)).should be_true
    CrystalClick::WideTupleIdentifierType.is_default?(CrystalClick::IPv4Value.new(0_u32)).should be_true
    CrystalClick::WideTupleIdentifierType.is_default?(CrystalClick::IPv6Value.new(0_u64, 0_u64)).should be_true
    CrystalClick::WideTupleIdentifierType.is_default?(CrystalClick::UUIDValue.new(0_u64, 1_u64)).should be_false
    CrystalClick::WideTupleIdentifierType.is_default?(CrystalClick::IPv4Value.new(1_u32)).should be_false
    CrystalClick::WideTupleIdentifierType.is_default?(CrystalClick::IPv6Value.new(1_u64, 0_u64)).should be_false

    owner_name = CrystalClick::WideTupleIdentifierType.type_name(CrystalClick::UUIDValue)
    owner_name.to_unsafe[0] = 0x58_u8
    CrystalClick::WideTupleIdentifierType.type_name(CrystalClick::UUIDValue).should eq("UUID")
  end

  it "keeps repeated and reordered identifier leaves in declaration stream order" do
    type_name = "Tuple(v6 IPv6, v4 IPv4, id UUID, id_again UUID, count UInt64, label String)"
    plan = CrystalClick::WideTupleTypePlan.for_type(type_name)
    plan.should_not be_nil

    if plan
      plan.fields.map(&.type_name).should eq(["IPv6", "IPv4", "UUID", "UUID", "UInt64", "String"])
      plan.physical_streams("payload").should eq([
        "payload%2Ev6",
        "payload%2Ev4",
        "payload%2Eid",
        "payload%2Eid_again",
        "payload%2Ecount",
        "payload%2Elabel.size",
        "payload%2Elabel",
      ])
      plan.stream_width("payload", "payload%2Ev6").should eq(16)
      plan.stream_width("payload", "payload%2Ev4").should eq(4)
      plan.stream_width("payload", "payload%2Eid").should eq(16)
      plan.stream_width("payload", "payload%2Eid_again").should eq(16)
    end
  end

  it "admits Nullable UUID and nested paths while rejecting malformed and unsupported recursive aliases" do
    nullable = CrystalClick::WideTupleTypePlan.for_type("Tuple(value Nullable(UUID))").not_nil!
    nullable.fields.first.type_name.should eq("Nullable(UUID)")

    rejected = [
      "Tuple()",
      "Tuple(UUID)",
      "Tuple(value UUID())",
      "Tuple(value IPv4())",
      "Tuple(value IPv6())",
      "Tuple(value Array(IPv4))",
      "Tuple(value Tuple())",
      "Tuple(value Array(Tuple(inner IPv6)))",
    ]

    rejected.each do |type_name|
      CrystalClick::WideTupleTypePlan.for_type(type_name).should be_nil
    end

    nested = CrystalClick::WideTupleTypePlan.for_type("Tuple(value Tuple(inner IPv6))").not_nil!
    nested.fields.map { |field| {field.name, field.type_name} }.should eq([{"value.inner", "IPv6"}])
    nested.physical_streams("payload").should eq(["payload%2Evalue%2Einner"])
  end

  it "keeps wrapper buffers owned and exact nominal access distinct" do
    ipv6_source = [CrystalClick::IPv6Value.new(0x20010db885a30000_u64, 0x00008a2e03707334_u64)]
    ipv4_source = [CrystalClick::IPv4Value.from_octets(1_u8, 2_u8, 3_u8, 4_u8)]
    uuid_source = [CrystalClick::UUIDValue.new(0x0011223344556677_u64, 0x8899aabbccddeeff_u64)]
    ipv6 = CrystalClick::WideTupleLeafColumn.new("v6", ipv6_source)
    ipv4 = CrystalClick::WideTupleLeafColumn.new("v4", ipv4_source)
    uuid = CrystalClick::WideTupleLeafColumn.new("id", uuid_source)

    ipv6_source[0] = CrystalClick::IPv6Value.new(0_u64, 0_u64)
    ipv4_source[0] = CrystalClick::IPv4Value.new(0_u32)
    uuid_source[0] = CrystalClick::UUIDValue.new(0_u64, 0_u64)

    ipv6.type_name.should eq("IPv6")
    ipv4.type_name.should eq("IPv4")
    uuid.type_name.should eq("UUID")
    returned_leaf_type_name = ipv4.type_name
    returned_leaf_type_name.to_unsafe[0] = 0x58_u8
    ipv4.type_name.should eq("IPv4")
    ipv6.value_at(0, CrystalClick::IPv6Value).should eq(
      CrystalClick::IPv6Value.new(0x20010db885a30000_u64, 0x00008a2e03707334_u64)
    )
    ipv4.value_at(0, CrystalClick::IPv4Value).should eq(CrystalClick::IPv4Value.from_octets(1_u8, 2_u8, 3_u8, 4_u8))
    uuid.value_at(0, CrystalClick::UUIDValue).should eq(
      CrystalClick::UUIDValue.new(0x0011223344556677_u64, 0x8899aabbccddeeff_u64)
    )

    ipv6_copy = ipv6.values_as(CrystalClick::IPv6Value)
    ipv6_copy[0] = CrystalClick::IPv6Value.new(0_u64, 1_u64)
    ipv6_buffer_copy = ipv6.values.as(Array(CrystalClick::IPv6Value))
    ipv6_buffer_copy[0] = CrystalClick::IPv6Value.new(0_u64, 2_u64)
    ipv4_copy = ipv4.values_as(CrystalClick::IPv4Value)
    ipv4_copy[0] = CrystalClick::IPv4Value.new(0_u32)
    ipv4_buffer_copy = ipv4.values.as(Array(CrystalClick::IPv4Value))
    ipv4_buffer_copy[0] = CrystalClick::IPv4Value.new(2_u32)
    uuid_copy = uuid.values_as(CrystalClick::UUIDValue)
    uuid_copy[0] = CrystalClick::UUIDValue.new(0_u64, 1_u64)
    uuid_buffer_copy = uuid.values.as(Array(CrystalClick::UUIDValue))
    uuid_buffer_copy[0] = CrystalClick::UUIDValue.new(0_u64, 2_u64)

    ipv6.value_at(0, CrystalClick::IPv6Value).high.should eq(0x20010db885a30000_u64)
    ipv4.value_at(0, CrystalClick::IPv4Value).network_order.should eq(0x01020304_u32)
    uuid.value_at(0, CrystalClick::UUIDValue).high.should eq(0x0011223344556677_u64)
    expect_raises(CrystalClick::UnsupportedFormatError) { ipv6.values_as(CrystalClick::UUIDValue) }
    expect_raises(CrystalClick::UnsupportedFormatError) { ipv4.values_as(UInt32) }
    expect_raises(CrystalClick::UnsupportedFormatError) { ipv4.value_at(0, UInt32) }
    expect_raises(CrystalClick::UnsupportedFormatError) { uuid.values_as(CrystalClick::IPv6Value) }
  end

  it "rejects equal-width nominal substitutions in row-aligned model data" do
    uuid_plan = CrystalClick::WideTupleTypePlan.for_type("Tuple(value UUID)").not_nil!
    ipv4_plan = CrystalClick::WideTupleTypePlan.for_type("Tuple(value IPv4)").not_nil!

    ipv6_for_uuid = CrystalClick::WideTupleLeafColumn.new(
      "value", [CrystalClick::IPv6Value.new(1_u64, 2_u64)]
    )
    uint32_for_ipv4 = CrystalClick::WideTupleLeafColumn.new("value", [0x01020304_u32])
    expect_raises(ArgumentError) do
      CrystalClick::WideTupleColumnData.new(uuid_plan, [ipv6_for_uuid] of CrystalClick::WideTupleLeafColumn)
    end
    expect_raises(ArgumentError) do
      CrystalClick::WideTupleColumnData.new(ipv4_plan, [uint32_for_ipv4] of CrystalClick::WideTupleLeafColumn)
    end
  end

  it "retains an exact nominal identifier row after its data scope ends" do
    row = w99_identifier_row_after_data_scope

    row.fields.map(&.type_name).should eq(["IPv6", "IPv4", "UUID"])
    row.value_as("v6", CrystalClick::IPv6Value).should eq(
      CrystalClick::IPv6Value.new(0_u64, 0_u64)
    )
    row.value_as("v4", CrystalClick::IPv4Value).should eq(CrystalClick::IPv4Value.new(0_u32))
    row.value_as("id", CrystalClick::UUIDValue).should eq(
      CrystalClick::UUIDValue.new(0_u64, UInt64::MAX)
    )

    returned_type_name = row.type_name
    returned_type_name.to_unsafe[0] = 0x58_u8
    row.type_name.should eq("Tuple(v6 IPv6, v4 IPv4, id UUID)")
    fields = row.fields
    returned_field_name = fields[0].name
    returned_field_name.to_unsafe[0] = 0x58_u8
    row.fields[0].name.should eq("v6")
  end

  it "charges the exact 16+4+16 identifier slots with checked overflow" do
    plan = CrystalClick::WideTupleTypePlan.for_type("Tuple(v6 IPv6, v4 IPv4, id UUID)").not_nil!

    # 64-byte container + three actual field slots, independent schema-tree
    # and path storage, and leaf owners; per row is 8 row bytes plus exact
    # 16+4+16-byte identifier payloads.
    fixed_bytes = 64_u64 +
                  3_u64 * sizeof(CrystalClick::WideTupleField).to_u64 +
                  w99_flat_tree_and_path_charge(["v6", "v4", "id"] of String) +
                  w99_identifier_leaf_descriptor_bytes
    bytes_per_row = 8_u64 + 16_u64 + 4_u64 + 16_u64
    plan.materialization_charge(0_u64, 0_u64).should eq(fixed_bytes)
    plan.materialization_charge(3_u64, 0_u64).should eq(fixed_bytes + 3_u64 * bytes_per_row)
    plan.materialization_charge(5_u64, 0_u64).should eq(fixed_bytes + 5_u64 * bytes_per_row)
    plan.materialization_charge(UInt64::MAX, 0_u64).should be_nil
    plan.materialization_charge(0_u64, UInt64::MAX).should be_nil
  end

  it "reads full and selected identifier ranges while bounding each materialized result" do
    parent = File.tempname("crystal-click-w99-identifier-reader")
    Dir.mkdir(parent)
    begin
      columns = w99_identifier_columns
      part = w99_identifier_write_part(parent, "ranges", columns, 2)
      reader = CrystalClick::WidePart.open_typed(part, "payload")

      reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      fixed_bytes = 64_u64 +
                    3_u64 * sizeof(CrystalClick::WideTupleField).to_u64 +
                    w99_flat_tree_and_path_charge(["v6", "v4", "id"] of String) +
                    w99_identifier_leaf_descriptor_bytes
      bytes_per_row = 8_u64 + 16_u64 + 4_u64 + 16_u64
      reader.tuple_mark_range_materialization_charge("payload", 0, 3).should eq(
        fixed_bytes + 5_u64 * bytes_per_row
      )
      reader.tuple_mark_range_materialization_charge("payload", 1, 1).should eq(
        fixed_bytes + 2_u64 * bytes_per_row
      )

      full = reader.read_tuple_mark_range("payload", 0, 3)
      full.row_count.should eq(5)
      full.fields.map { |field| {field.name, field.type_name} }.should eq([
        {"v6", "IPv6"}, {"v4", "IPv4"}, {"id", "UUID"},
      ])
      full.row_count.times do |index|
        row = full.row(index)
        row.value_as("v6", CrystalClick::IPv6Value).should eq(columns[0].values_as(CrystalClick::IPv6Value)[index])
        row.value_as("v4", CrystalClick::IPv4Value).should eq(columns[1].values_as(CrystalClick::IPv4Value)[index])
        row.value_as("id", CrystalClick::UUIDValue).should eq(columns[2].values_as(CrystalClick::UUIDValue)[index])
      end

      selected = reader.read_tuple_mark_range("payload", 1, 1)
      selected.row_count.should eq(2)
      selected.row(0).value_as("v6", CrystalClick::IPv6Value).should eq(
        columns[0].values_as(CrystalClick::IPv6Value)[2]
      )
      selected.row(1).value_as("id", CrystalClick::UUIDValue).should eq(
        columns[2].values_as(CrystalClick::UUIDValue)[3]
      )

      required_two_row_charge = fixed_bytes + 2_u64 * bytes_per_row
      expect_raises(CrystalClick::CorruptPartError) do
        reader.read_tuple_mark_range("payload", 0, 1, max_materialized_bytes: required_two_row_charge - 1_u64)
      end
      callbacks = [] of Int32
      expect_raises(CrystalClick::CorruptPartError) do
        reader.each_tuple_mark_range("payload", 0, 1, max_materialized_bytes: required_two_row_charge - 1_u64) do |_data, mark_index|
          callbacks << mark_index
          nil
        end
      end
      callbacks.should be_empty
      reader.read_tuple_mark_range(
        "payload", 0, 1, max_materialized_bytes: required_two_row_charge
      ).row_count.should eq(2)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps corruption in a later identifier mark lazy until that mark is selected" do
    parent = File.tempname("crystal-click-w99-identifier-lazy")
    Dir.mkdir(parent)
    begin
      columns = w99_identifier_columns
      part = w99_identifier_write_part(parent, "lazy", columns, 1)
      w99_corrupt_mark_frame_header(part, "payload%2Eid", 1)
      reader = CrystalClick::WidePart.open_typed(part, "payload")

      first = reader.read_tuple_mark_range("payload", 0, 1)
      first.row(0).value_as("id", CrystalClick::UUIDValue).should eq(
        columns[2].values_as(CrystalClick::UUIDValue)[0]
      )

      callbacks = [] of Int32
      expect_raises(CrystalClick::CorruptPartError) do
        reader.each_tuple_mark_range("payload", 0, 3) do |_data, mark_index|
          callbacks << mark_index
          nil
        end
      end
      callbacks.should eq([0])
      expect_raises(CrystalClick::CorruptPartError) do
        reader.read_tuple_mark_range("payload", 1, 1)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
