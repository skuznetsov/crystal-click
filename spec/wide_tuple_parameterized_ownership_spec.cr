require "./spec_helper"

class CrystalClick::WidePart
  # Expose only the bounded in-memory decoder seam needed to assert how
  # malformed Enum wire codes are classified. This does not touch part state.
  def w101_decode_parameterized_leaf_for_test(
    name : String,
    exact_type : WideTupleParameterizedType,
    bytes : Bytes,
    rows : UInt64,
    width : Int32,
  ) : WideTupleLeafColumn
    decode_tuple_parameterized_leaf(name, exact_type, bytes, rows, width)
  end
end

# String#dup and a copied String value do not prove unique backing-byte
# ownership. These deliberate writes exercise the stronger byte boundary.
private def w101own_mutate_string(value : String, byte : UInt8) : Nil
  value.to_unsafe[0] = byte
end

private def w101_leaf_descriptor_charge(base_type_name : String) : UInt64
  instance_sizeof(CrystalClick::WideTupleLeafType).to_u64 +
    instance_sizeof(String).to_u64 + base_type_name.bytesize.to_u64 + 1_u64
end

private def w106_parameterized_tree_and_path_charge(name : String) : UInt64
  node_bytes = instance_sizeof(CrystalClick::WideTupleSchemaNode).to_u64 +
               instance_sizeof(Array(CrystalClick::WideTupleSchemaNode)).to_u64
  string_bytes = instance_sizeof(String).to_u64 + name.bytesize.to_u64 + 1_u64
  node_bytes + sizeof(Pointer(CrystalClick::WideTupleSchemaNode)).to_u64 +
    node_bytes + string_bytes +
    instance_sizeof(Array(String)).to_u64 + sizeof(Pointer(String)).to_u64 + string_bytes
end

private def w101own_detached_fixed_string_value : CrystalClick::FixedStringValue
  plan = CrystalClick::WideTupleTypePlan.for_type("Tuple(id FixedString(4))").not_nil!
  exact_type = plan.fields[0].parameterized_type.not_nil!.as(CrystalClick::WideTupleFixedStringType)
  leaf = CrystalClick::WideTupleLeafColumn.new(
    "id",
    exact_type,
    [CrystalClick::FixedStringValue.new(4_i32, "AB")]
  )
  CrystalClick::WideTupleColumnData.new(plan, [leaf]).row(0).value_as("id", CrystalClick::FixedStringValue)
end

private def w101own_detached_enum_value : CrystalClick::Enum8Value
  definition = CrystalClick::WideTupleEnumDefinition.new(
    :enum8,
    [{"inactive", -1_i16}, {"active", 3_i16}] of Tuple(String, Int16)
  )
  plan = CrystalClick::WideTupleTypePlan.for_type(
    "Tuple(state Enum8('inactive' = -1, 'active' = 3))"
  ).not_nil!
  exact_type = plan.fields[0].parameterized_type.not_nil!.as(CrystalClick::WideTupleEnumType)
  leaf = CrystalClick::WideTupleLeafColumn.new(
    "state",
    exact_type,
    [CrystalClick::Enum8Value.new(definition, 3_i8)]
  )
  CrystalClick::WideTupleColumnData.new(plan, [leaf]).row(0).value_as("state", CrystalClick::Enum8Value)
end

private def w101own_detached_decimal_value : CrystalClick::Decimal256TupleValue
  raw = CrystalClick::Decimal256Value.from_words(1_u64, 2_u64, 3_u64, 4_u64)
  plan = CrystalClick::WideTupleTypePlan.for_type("Tuple(amount Decimal(70, 6))").not_nil!
  exact_type = plan.fields[0].parameterized_type.not_nil!.as(CrystalClick::WideTupleDecimalType)
  leaf = CrystalClick::WideTupleLeafColumn.new(
    "amount",
    exact_type,
    [CrystalClick::Decimal256TupleValue.new(raw, 70_i32, 6_i32)]
  )
  CrystalClick::WideTupleColumnData.new(plan, [leaf]).row(0).value_as("amount", CrystalClick::Decimal256TupleValue)
end

describe "W101 parameterized Tuple immutable owners and nominal values" do
  it "threads every exact retained parameter through Crystal::Hasher" do
    fixed_value = CrystalClick::FixedStringValue.new(3_i32, "x")
    expected_hash = Crystal::Hasher.new
    expected_hash = 3_i32.hash(expected_hash)
    fixed_value.raw_bytes.each { |byte| expected_hash = byte.hash(expected_hash) }
    fixed_value.hash.should eq(expected_hash.result)

    fixed_type = CrystalClick::WideTupleFixedStringType.new(3_i32)
    expected_hash = Crystal::Hasher.new
    expected_hash = 3_i32.hash(expected_hash)
    fixed_type.hash.should eq(expected_hash.result)

    enum_definition = CrystalClick::WideTupleEnumDefinition.new(
      :enum8,
      [{"zero", 0_i16}, {"active", 7_i16}] of Tuple(String, Int16)
    )
    expected_hash = Crystal::Hasher.new
    expected_hash = :enum8.hash(expected_hash)
    enum_definition.entries.each do |label, code|
      expected_hash = label.hash(expected_hash)
      expected_hash = code.hash(expected_hash)
    end
    enum_definition.hash.should eq(expected_hash.result)

    enum_type = CrystalClick::WideTupleEnumType.new(enum_definition)
    expected_hash = Crystal::Hasher.new
    expected_hash = :enum8.hash(expected_hash)
    enum_definition.entries.each do |label, code|
      expected_hash = label.hash(expected_hash)
      expected_hash = code.hash(expected_hash)
    end
    enum_type.hash.should eq(expected_hash.result)

    enum8 = CrystalClick::Enum8Value.new(enum_definition, 7_i8)
    expected_hash = Crystal::Hasher.new
    expected_hash = :enum8.hash(expected_hash)
    enum_definition.entries.each do |label, code|
      expected_hash = label.hash(expected_hash)
      expected_hash = code.hash(expected_hash)
    end
    expected_hash = 7_i8.hash(expected_hash)
    enum8.hash.should eq(expected_hash.result)

    enum16_definition = CrystalClick::WideTupleEnumDefinition.new(
      :enum16,
      [{"known", 7_i16}] of Tuple(String, Int16)
    )
    enum16 = CrystalClick::Enum16Value.new(enum16_definition, 7_i16)
    expected_hash = Crystal::Hasher.new
    expected_hash = :enum16.hash(expected_hash)
    expected_hash = "known".hash(expected_hash)
    expected_hash = 7_i16.hash(expected_hash)
    expected_hash = 7_i16.hash(expected_hash)
    enum16.hash.should eq(expected_hash.result)

    decimal_type = CrystalClick::WideTupleDecimalType.new(20_i32, 4_i32)
    expected_hash = Crystal::Hasher.new
    expected_hash = 20_i32.hash(expected_hash)
    expected_hash = 4_i32.hash(expected_hash)
    decimal_type.hash.should eq(expected_hash.result)

    decimal32 = CrystalClick::Decimal32Value.new(5_i32, 9_i32, 2_i32)
    expected_hash = Crystal::Hasher.new
    expected_hash = 5_i32.hash(expected_hash)
    expected_hash = 9_i32.hash(expected_hash)
    expected_hash = 2_i32.hash(expected_hash)
    decimal32.hash.should eq(expected_hash.result)

    decimal64 = CrystalClick::Decimal64Value.new(5_i64, 18_i32, 2_i32)
    expected_hash = Crystal::Hasher.new
    expected_hash = 5_i64.hash(expected_hash)
    expected_hash = 18_i32.hash(expected_hash)
    expected_hash = 2_i32.hash(expected_hash)
    decimal64.hash.should eq(expected_hash.result)

    decimal128 = CrystalClick::Decimal128Value.new(5_i128, 38_i32, 2_i32)
    expected_hash = Crystal::Hasher.new
    expected_hash = 5_i128.hash(expected_hash)
    expected_hash = 38_i32.hash(expected_hash)
    expected_hash = 2_i32.hash(expected_hash)
    decimal128.hash.should eq(expected_hash.result)

    raw256 = CrystalClick::Decimal256Value.from_words(1_u64, 2_u64, 3_u64, 4_u64)
    decimal256 = CrystalClick::Decimal256TupleValue.new(raw256, 76_i32, 2_i32)
    expected_hash = Crystal::Hasher.new
    expected_hash = raw256.low.hash(expected_hash)
    expected_hash = raw256.high.hash(expected_hash)
    expected_hash = 76_i32.hash(expected_hash)
    expected_hash = 2_i32.hash(expected_hash)
    decimal256.hash.should eq(expected_hash.result)
  end

  it "accepts the canonical Enum byte boundary and rejects excess output and escape expansion" do
    boundary_label = "a" * 4_083
    boundary = CrystalClick::WideTupleEnumDefinition.new(
      :enum8,
      [{boundary_label, 1_i16}] of Tuple(String, Int16)
    )
    boundary.type_name.bytesize.should eq(4_096)

    enum16_boundary = CrystalClick::WideTupleEnumDefinition.new(
      :enum16,
      [{"a" * 4_077, -32_768_i16}] of Tuple(String, Int16)
    )
    enum16_boundary.type_name.bytesize.should eq(4_096)

    expect_raises(ArgumentError) do
      CrystalClick::WideTupleEnumDefinition.new(
        :enum8,
        [{"a" * 4_084, 1_i16}] of Tuple(String, Int16)
      )
    end

    expect_raises(ArgumentError) do
      CrystalClick::WideTupleEnumDefinition.new(
        :enum16,
        [{"a" * 4_078, -32_768_i16}] of Tuple(String, Int16)
      )
    end

    expect_raises(ArgumentError) do
      CrystalClick::WideTupleEnumDefinition.new(
        :enum8,
        [{"'" * 2_042, 1_i16}] of Tuple(String, Int16)
      )
    end
  end

  it "rejects Enum entry-count overflow before validating or copying entries" do
    too_many_entries = Array(Tuple(String, Int16)).new(510) do |index|
      {"duplicate", index.to_i16}
    end

    error = expect_raises(ArgumentError) do
      CrystalClick::WideTupleEnumDefinition.new(:enum16, too_many_entries)
    end
    error.message.should eq("Enum definition exceeds 509 entries")
  end

  it "classifies an undeclared Enum8 wire code as corrupt data" do
    definition = CrystalClick::WideTupleEnumDefinition.new(
      :enum8,
      [{"known", 7_i16}] of Tuple(String, Int16)
    )
    part = CrystalClick::WidePart.open(FIXTURE)

    expect_raises(CrystalClick::CorruptPartError) do
      part.w101_decode_parameterized_leaf_for_test(
        "state",
        CrystalClick::WideTupleEnumType.new(definition),
        Bytes[0_u8],
        1_u64,
        1
      )
    end
  end

  it "classifies an undeclared Enum16 wire code as corrupt data" do
    definition = CrystalClick::WideTupleEnumDefinition.new(
      :enum16,
      [{"known", 7_i16}] of Tuple(String, Int16)
    )
    part = CrystalClick::WidePart.open(FIXTURE)

    expect_raises(CrystalClick::CorruptPartError) do
      part.w101_decode_parameterized_leaf_for_test(
        "state",
        CrystalClick::WideTupleEnumType.new(definition),
        Bytes[0_u8, 0_u8],
        1_u64,
        2
      )
    end
  end

  it "owns and copies FixedString bytes on construction, raw import, and exposure" do
    source = String.new(Bytes[0x41_u8, 0x00_u8, 0x42_u8])
    value = CrystalClick::FixedStringValue.new(4_i32, source)
    w101own_mutate_string(source, 0x5a_u8)

    value.width.should eq(4)
    value.raw_bytes.to_a.should eq([0x41_u8, 0x00_u8, 0x42_u8, 0x00_u8])

    exposed = value.raw_bytes
    exposed[0] = 0x59_u8
    value.raw_bytes.to_a.should eq([0x41_u8, 0x00_u8, 0x42_u8, 0x00_u8])

    imported_source = Bytes[0x10_u8, 0x20_u8, 0x30_u8, 0x40_u8]
    imported = CrystalClick::FixedStringValue.from_raw(4_i32, imported_source)
    imported_source[0] = 0xff_u8
    imported.raw_bytes.to_a.should eq([0x10_u8, 0x20_u8, 0x30_u8, 0x40_u8])

    input_values = [CrystalClick::FixedStringValue.new(4_i32, "ORIG")]
    column = CrystalClick::WideTupleLeafColumn.new(
      "id",
      CrystalClick::WideTupleFixedStringType.new(4_i32),
      input_values
    )
    input_values[0] = CrystalClick::FixedStringValue.new(4_i32, "EDIT")
    column.value_at(0, CrystalClick::FixedStringValue).raw_bytes.to_a.should eq(
      [0x4f_u8, 0x52_u8, 0x49_u8, 0x47_u8]
    )
    exposed_values = column.values_as(CrystalClick::FixedStringValue)
    exposed_values[0] = CrystalClick::FixedStringValue.new(4_i32, "COPY")
    column.value_at(0, CrystalClick::FixedStringValue).raw_bytes.to_a.should eq(
      [0x4f_u8, 0x52_u8, 0x49_u8, 0x47_u8]
    )

    expect_raises(ArgumentError) { CrystalClick::FixedStringValue.new(2_i32, "long") }
    expect_raises(ArgumentError) { CrystalClick::FixedStringValue.from_raw(4_i32, Bytes[1_u8, 2_u8, 3_u8]) }
    expect_raises(ArgumentError) { CrystalClick::WideTupleFixedStringType.new(0_i32) }
    expect_raises(ArgumentError) { CrystalClick::WideTupleFixedStringType.new(65_537_i32) }
  end

  it "compares FixedString values and owners with width as part of nominal identity" do
    left = CrystalClick::FixedStringValue.new(3_i32, "xy")
    equal = CrystalClick::FixedStringValue.new(3_i32, "xy")
    different_width = CrystalClick::FixedStringValue.new(4_i32, "xy")
    left.should eq(equal)
    left.hash.should eq(equal.hash)
    left.should_not eq(different_width)

    owner = CrystalClick::WideTupleFixedStringType.new(3_i32)
    owner.should eq(CrystalClick::WideTupleFixedStringType.new(3_i32))
    owner.hash.should eq(CrystalClick::WideTupleFixedStringType.new(3_i32).hash)
    owner.should_not eq(CrystalClick::WideTupleFixedStringType.new(4_i32))
  end

  it "retains FixedString descriptors in empty leaves, copies, and detached row values" do
    plan = CrystalClick::WideTupleTypePlan.for_type("Tuple(id FixedString(4))").not_nil!
    exact_type = plan.fields[0].parameterized_type.not_nil!.as(CrystalClick::WideTupleFixedStringType)
    plan.fields[0].parameterized_type.not_nil!.as(CrystalClick::WideTupleFixedStringType).should eq(exact_type)
    empty = CrystalClick::WideTupleLeafColumn.new(
      "id",
      exact_type,
      [] of CrystalClick::FixedStringValue
    )
    empty.owned_copy.parameterized_type.not_nil!.as(CrystalClick::WideTupleFixedStringType).width.should eq(4)
    data = CrystalClick::WideTupleColumnData.new(plan, [empty])
    data.row_count.should eq(0)
    data.columns[0].parameterized_type.not_nil!.as(CrystalClick::WideTupleFixedStringType).width.should eq(4)

    wrong_empty = CrystalClick::WideTupleLeafColumn.new(
      "id",
      CrystalClick::WideTupleFixedStringType.new(5_i32),
      [] of CrystalClick::FixedStringValue
    )
    expect_raises(ArgumentError) { CrystalClick::WideTupleColumnData.new(plan, [wrong_empty]) }

    detached = w101own_detached_fixed_string_value
    detached.width.should eq(4)
    detached.raw_bytes.to_a.should eq([0x41_u8, 0x42_u8, 0x00_u8, 0x00_u8])
  end

  it "counts FixedString padded bytes with String payload once through the shared row contract" do
    plan = CrystalClick::WideTupleTypePlan.for_type(
      "Tuple(fixed FixedString(4), text String, amount Decimal(10, 2))"
    ).not_nil!
    fixed_type = plan.fields[0].parameterized_type.not_nil!.as(CrystalClick::WideTupleFixedStringType)
    decimal_type = plan.fields[2].parameterized_type.not_nil!.as(CrystalClick::WideTupleDecimalType)
    data = CrystalClick::WideTupleColumnData.new(plan, [
      CrystalClick::WideTupleLeafColumn.new(
        "fixed",
        fixed_type,
        [
          CrystalClick::FixedStringValue.new(4_i32, "xy"),
          CrystalClick::FixedStringValue.new(4_i32, "WXYZ"),
        ]
      ),
      CrystalClick::WideTupleLeafColumn.new("text", ["abc", ""] of String),
      CrystalClick::WideTupleLeafColumn.new(
        "amount",
        decimal_type,
        [
          CrystalClick::Decimal64Value.new(0_i64, 10_i32, 2_i32),
          CrystalClick::Decimal64Value.new(1_i64, 10_i32, 2_i32),
        ]
      ),
    ])

    # FixedString owns all N padded bytes, including the two zero-fill bytes
    # in row zero. Decimal coefficients do not contribute payload bytes.
    data.row(0).string_bytesize.should eq(7_u64)
    data.row(1).string_bytesize.should eq(4_u64)
    payload_bytes = data.row(0).string_bytesize + data.row(1).string_bytesize
    payload_bytes.should eq(11_u64)

    without_payload = plan.materialization_charge(2_u64, 0_u64).not_nil!
    with_payload = plan.materialization_charge(2_u64, payload_bytes).not_nil!
    (with_payload - without_payload).should eq(payload_bytes)
  end

  it "accounts independently measured owner storage and nominal row slots once" do
    fixed_plan = CrystalClick::WideTupleTypePlan.for_type("Tuple(id FixedString(4))").not_nil!
    fixed_owner = fixed_plan.fields[0].parameterized_type.not_nil!.as(CrystalClick::WideTupleFixedStringType)
    fixed_name = fixed_owner.type_name
    fixed_owner_charge = instance_sizeof(CrystalClick::WideTupleFixedStringType).to_u64 +
                         instance_sizeof(String).to_u64 + fixed_name.bytesize.to_u64 + 1_u64
    fixed_leaf_owner_charge = w101_leaf_descriptor_charge("FixedString(4)")
    fixed_owner.logical_charge.should eq(fixed_owner_charge)
    fixed_empty_charge = CrystalClick::WideTupleTypePlan::RESULT_CONTAINER_ACCOUNTING_BYTES +
                         CrystalClick::WideTupleTypePlan::FIELD_CONTAINER_ACCOUNTING_BYTES +
                         w106_parameterized_tree_and_path_charge("id") +
                         fixed_leaf_owner_charge + fixed_owner_charge
    fixed_plan.materialization_charge(0_u64, 0_u64).not_nil!.should eq(fixed_empty_charge)
    (fixed_plan.materialization_charge(1_u64, 0_u64).not_nil! -
      fixed_plan.materialization_charge(0_u64, 0_u64).not_nil!).should eq(
      CrystalClick::WideTupleTypePlan::RESULT_ROW_ACCOUNTING_BYTES + sizeof(CrystalClick::FixedStringValue).to_u64
    )
    (fixed_plan.materialization_charge(1_u64, 4_u64).not_nil! -
      fixed_plan.materialization_charge(1_u64, 0_u64).not_nil!).should eq(4_u64)

    enum_plan = CrystalClick::WideTupleTypePlan.for_type(
      "Tuple(state Enum8('idle' = -1, 'run' = 2))"
    ).not_nil!
    enum_owner = enum_plan.fields[0].parameterized_type.not_nil!.as(CrystalClick::WideTupleEnumType)
    enum_definition = enum_owner.definition
    enum_entries = enum_definition.entries
    enum_label_bytes = 0_u64
    enum_entries.each do |entry|
      label = entry[0]
      enum_label_bytes += instance_sizeof(String).to_u64 + label.bytesize.to_u64 + 1_u64
    end
    enum_type_name = enum_definition.type_name
    enum_definition_charge = instance_sizeof(CrystalClick::WideTupleEnumDefinition).to_u64 +
                             instance_sizeof(Array(CrystalClick::WideTupleEnumDefinition::Entry)).to_u64 +
                             enum_entries.size.to_u64 * sizeof(CrystalClick::WideTupleEnumDefinition::Entry).to_u64 +
                             enum_label_bytes + instance_sizeof(String).to_u64 +
                             enum_type_name.bytesize.to_u64 + 1_u64
    enum_owner_charge = instance_sizeof(CrystalClick::WideTupleEnumType).to_u64 + enum_definition_charge
    enum_leaf_owner_charge = w101_leaf_descriptor_charge("Enum8('idle' = -1, 'run' = 2)")
    enum_owner.logical_charge.should eq(enum_owner_charge)
    enum_empty_charge = CrystalClick::WideTupleTypePlan::RESULT_CONTAINER_ACCOUNTING_BYTES +
                        CrystalClick::WideTupleTypePlan::FIELD_CONTAINER_ACCOUNTING_BYTES +
                        w106_parameterized_tree_and_path_charge("state") +
                        enum_leaf_owner_charge + enum_owner_charge
    enum_plan.materialization_charge(0_u64, 0_u64).not_nil!.should eq(enum_empty_charge)
    (enum_plan.materialization_charge(1_u64, 0_u64).not_nil! -
      enum_plan.materialization_charge(0_u64, 0_u64).not_nil!).should eq(
      CrystalClick::WideTupleTypePlan::RESULT_ROW_ACCOUNTING_BYTES + sizeof(CrystalClick::Enum8Value).to_u64
    )

    [
      {"Decimal(9, 2)", sizeof(CrystalClick::Decimal32Value)},
      {"Decimal(18, 2)", sizeof(CrystalClick::Decimal64Value)},
      {"Decimal(38, 2)", sizeof(CrystalClick::Decimal128Value)},
      {"Decimal(76, 2)", sizeof(CrystalClick::Decimal256TupleValue)},
    ].each do |declaration, wrapper_bytes|
      plan = CrystalClick::WideTupleTypePlan.for_type("Tuple(amount #{declaration})").not_nil!
      owner = plan.fields[0].parameterized_type.not_nil!.as(CrystalClick::WideTupleDecimalType)
      owner_name = owner.type_name
      owner_charge = instance_sizeof(CrystalClick::WideTupleDecimalType).to_u64 +
                     instance_sizeof(String).to_u64 + owner_name.bytesize.to_u64 + 1_u64
      leaf_owner_charge = w101_leaf_descriptor_charge(declaration)
      owner.logical_charge.should eq(owner_charge)
      empty_charge = CrystalClick::WideTupleTypePlan::RESULT_CONTAINER_ACCOUNTING_BYTES +
                     CrystalClick::WideTupleTypePlan::FIELD_CONTAINER_ACCOUNTING_BYTES +
                     w106_parameterized_tree_and_path_charge("amount") +
                     leaf_owner_charge + owner_charge
      plan.materialization_charge(0_u64, 0_u64).not_nil!.should eq(empty_charge)
      (plan.materialization_charge(1_u64, 0_u64).not_nil! -
        plan.materialization_charge(0_u64, 0_u64).not_nil!).should eq(
        CrystalClick::WideTupleTypePlan::RESULT_ROW_ACCOUNTING_BYTES + wrapper_bytes.to_u64
      )
    end
  end

  it "owns Enum labels and returns independent label copies" do
    source_label = String.new("alpha".to_slice)
    source_entries = [{source_label, 7_i16}, {"zero", 0_i16}] of Tuple(String, Int16)
    definition = CrystalClick::WideTupleEnumDefinition.new(:enum8, source_entries)
    w101own_mutate_string(source_label, 0x58_u8)
    source_entries.clear

    definition.entries.map(&.[0]).should eq(["zero", "alpha"])
    exposed_entries = definition.entries
    w101own_mutate_string(exposed_entries[1][0], 0x59_u8)
    definition.entries.map(&.[0]).should eq(["zero", "alpha"])

    value = CrystalClick::Enum8Value.new(definition, 7_i8)
    exposed_label = value.label
    w101own_mutate_string(exposed_label, 0x5a_u8)
    value.label.should eq("alpha")
    value.code.should eq(7_i8)
    expect_raises(ArgumentError) { CrystalClick::Enum8Value.new(definition, 1_i8) }
  end

  it "compares Enum maps semantically and rebinds equal per-row maps to one leaf owner" do
    first = CrystalClick::WideTupleEnumDefinition.new(
      :enum8,
      [{"inactive", -1_i16}, {"active", 3_i16}] of Tuple(String, Int16)
    )
    second = CrystalClick::WideTupleEnumDefinition.new(
      :enum8,
      [{"active", 3_i16}, {"inactive", -1_i16}] of Tuple(String, Int16)
    )
    first.should eq(second)
    first.hash.should eq(second.hash)
    first.entries.should eq(second.entries)

    equal_value = CrystalClick::Enum8Value.new(second, -1_i8)
    equal_value.should eq(CrystalClick::Enum8Value.new(first, -1_i8))
    equal_value.hash.should eq(CrystalClick::Enum8Value.new(first, -1_i8).hash)
    equal_value.should_not eq(CrystalClick::Enum8Value.new(first, 3_i8))
    rebound_value = equal_value.with_definition(first)
    rebound_value.definition.same?(first).should be_true
    {rebound_value.code, rebound_value.label}.should eq({-1_i8, "inactive"})

    first_type = CrystalClick::WideTupleEnumType.new(first)
    second_type = CrystalClick::WideTupleEnumType.new(second)
    first_type.should eq(second_type)
    first_type.hash.should eq(second_type.hash)
    first_type.type_name.should eq("Enum8('inactive' = -1, 'active' = 3)")

    descriptor_definition = CrystalClick::WideTupleEnumDefinition.new(
      :enum8,
      [{"inactive", -1_i16}, {"active", 3_i16}] of Tuple(String, Int16)
    )
    descriptor = CrystalClick::WideTupleEnumType.new(descriptor_definition)
    input = [
      CrystalClick::Enum8Value.new(first, -1_i8),
      CrystalClick::Enum8Value.new(second, 3_i8),
    ]
    column = CrystalClick::WideTupleLeafColumn.new("state", descriptor, input)
    input.clear

    owned = column.values_as(CrystalClick::Enum8Value)
    owned.map(&.code).should eq([-1_i8, 3_i8])
    owned.each { |value| value.definition.same?(descriptor.definition).should be_true }
    copy = column.owned_copy
    copy.values_as(CrystalClick::Enum8Value).each do |value|
      value.definition.same?(descriptor.definition).should be_true
    end

    plan = CrystalClick::WideTupleTypePlan.for_type(
      "Tuple(state Enum8('inactive' = -1, 'active' = 3))"
    ).not_nil!
    plan_definition = plan.fields[0].parameterized_type.not_nil!.as(CrystalClick::WideTupleEnumType).definition
    plan_definition.same?(descriptor.definition).should be_false
    data = CrystalClick::WideTupleColumnData.new(plan, [column])
    data.columns[0].values_as(CrystalClick::Enum8Value).each do |value|
      value.definition.same?(plan_definition).should be_true
    end

    wrong_definition = CrystalClick::WideTupleEnumDefinition.new(
      :enum8,
      [{"inactive", -1_i16}, {"active", 4_i16}] of Tuple(String, Int16)
    )
    expect_raises(ArgumentError) do
      CrystalClick::WideTupleLeafColumn.new(
        "state",
        descriptor,
        [CrystalClick::Enum8Value.new(wrong_definition, -1_i8)]
      )
    end
    expect_raises(ArgumentError) do
      CrystalClick::WideTupleEnumDefinition.new(
        :enum8,
        [{"same", 1_i16}, {"same", 2_i16}] of Tuple(String, Int16)
      )
    end
    expect_raises(ArgumentError) do
      CrystalClick::WideTupleEnumDefinition.new(
        :enum8,
        [{"one", 1_i16}, {"two", 1_i16}] of Tuple(String, Int16)
      )
    end
  end

  it "preserves Enum8 and Enum16 code bounds and detached/empty descriptor identity" do
    enum8 = CrystalClick::WideTupleEnumDefinition.new(
      :enum8,
      [{"min", -128_i16}, {"max", 127_i16}] of Tuple(String, Int16)
    )
    enum16 = CrystalClick::WideTupleEnumDefinition.new(
      :enum16,
      [{"min", -32_768_i16}, {"max", 32_767_i16}] of Tuple(String, Int16)
    )
    CrystalClick::Enum8Value.new(enum8, -128_i8).code.should eq(-128_i8)
    CrystalClick::Enum8Value.new(enum8, 127_i8).code.should eq(127_i8)
    CrystalClick::Enum16Value.new(enum16, -32_768_i16).code.should eq(-32_768_i16)
    CrystalClick::Enum16Value.new(enum16, 32_767_i16).code.should eq(32_767_i16)
    expect_raises(ArgumentError) { CrystalClick::WideTupleEnumDefinition.new(:enum8, [{"too high", 128_i16}]) }
    expect_raises(ArgumentError) { CrystalClick::WideTupleEnumDefinition.new(:enum32, [{"unsupported", 0_i16}]) }
    expect_raises(ArgumentError) { CrystalClick::WideTupleEnumDefinition.new(:enum16, [] of Tuple(String, Int16)) }

    plan = CrystalClick::WideTupleTypePlan.for_type(
      "Tuple(state Enum8('inactive' = -1, 'active' = 3))"
    ).not_nil!
    exact_type = plan.fields[0].parameterized_type.not_nil!.as(CrystalClick::WideTupleEnumType)
    empty = CrystalClick::WideTupleLeafColumn.new("state", exact_type, [] of CrystalClick::Enum8Value)
    empty_copy = empty.owned_copy.parameterized_type.not_nil!.as(CrystalClick::WideTupleEnumType)
    empty_copy.definition.same?(exact_type.definition).should be_true
    CrystalClick::WideTupleColumnData.new(plan, [empty]).row_count.should eq(0)

    detached = w101own_detached_enum_value
    detached.code.should eq(3_i8)
    detached.label.should eq("active")
    detached.definition.entries.map(&.[0]).should eq(["inactive", "active"])
  end

  it "retains Decimal precision and scale in every raw-width wrapper and descriptor" do
    decimal32 = CrystalClick::Decimal32Value.new(Int32::MIN, 9_i32, 9_i32)
    decimal64 = CrystalClick::Decimal64Value.new(Int64::MAX, 18_i32, 0_i32)
    decimal128 = CrystalClick::Decimal128Value.new(Int128::MIN, 38_i32, 19_i32)
    decimal256_raw = CrystalClick::Decimal256Value.from_words(1_u64, 2_u64, 3_u64, 4_u64)
    decimal256 = CrystalClick::Decimal256TupleValue.new(decimal256_raw, 76_i32, 76_i32)

    decimal32.raw.should eq(Int32::MIN)
    {decimal32.precision, decimal32.scale}.should eq({9, 9})
    decimal64.raw.should eq(Int64::MAX)
    {decimal64.precision, decimal64.scale}.should eq({18, 0})
    decimal128.raw.should eq(Int128::MIN)
    {decimal128.precision, decimal128.scale}.should eq({38, 19})
    decimal256.raw.should eq(decimal256_raw)
    {decimal256.precision, decimal256.scale}.should eq({76, 76})

    [
      {1_i32, 4_i32}, {9_i32, 4_i32},
      {10_i32, 8_i32}, {18_i32, 8_i32},
      {19_i32, 16_i32}, {38_i32, 16_i32},
      {39_i32, 32_i32}, {76_i32, 32_i32},
    ].each do |precision, storage_width|
      owner = CrystalClick::WideTupleDecimalType.new(precision, 0_i32)
      owner.precision.should eq(precision)
      owner.storage_width.should eq(storage_width)
    end

    exact = CrystalClick::Decimal32Value.new(17_i32, 9_i32, 2_i32)
    exact.should eq(CrystalClick::Decimal32Value.new(17_i32, 9_i32, 2_i32))
    exact.hash.should eq(CrystalClick::Decimal32Value.new(17_i32, 9_i32, 2_i32).hash)
    exact.should_not eq(CrystalClick::Decimal32Value.new(17_i32, 8_i32, 2_i32))
    exact.should_not eq(CrystalClick::Decimal32Value.new(17_i32, 9_i32, 3_i32))
    exact.should_not eq(CrystalClick::Decimal32Value.new(18_i32, 9_i32, 2_i32))

    same = CrystalClick::WideTupleDecimalType.new(20_i32, 4_i32)
    same.should eq(CrystalClick::WideTupleDecimalType.new(20_i32, 4_i32))
    same.hash.should eq(CrystalClick::WideTupleDecimalType.new(20_i32, 4_i32).hash)
    same.should_not eq(CrystalClick::WideTupleDecimalType.new(20_i32, 5_i32))
    same.should_not eq(CrystalClick::WideTupleDecimalType.new(21_i32, 4_i32))

    expect_raises(ArgumentError) { CrystalClick::Decimal32Value.new(0_i32, 10_i32, 0_i32) }
    expect_raises(ArgumentError) { CrystalClick::Decimal64Value.new(0_i64, 9_i32, 0_i32) }
    expect_raises(ArgumentError) { CrystalClick::Decimal128Value.new(0_i128, 39_i32, 0_i32) }
    expect_raises(ArgumentError) { CrystalClick::Decimal256TupleValue.new(decimal256_raw, 38_i32, 0_i32) }
    expect_raises(ArgumentError) { CrystalClick::Decimal32Value.new(0_i32, 1_i32, -1_i32) }
    expect_raises(ArgumentError) { CrystalClick::Decimal32Value.new(0_i32, 1_i32, 2_i32) }
  end

  it "retains exact Decimal metadata for empty leaves, owned copies, and detached values" do
    plan = CrystalClick::WideTupleTypePlan.for_type("Tuple(amount Decimal(20, 4))").not_nil!
    exact_type = plan.fields[0].parameterized_type.not_nil!.as(CrystalClick::WideTupleDecimalType)
    empty = CrystalClick::WideTupleLeafColumn.new("amount", exact_type, [] of CrystalClick::Decimal128Value)
    copied_type = empty.owned_copy.parameterized_type.not_nil!.as(CrystalClick::WideTupleDecimalType)
    {copied_type.precision, copied_type.scale, copied_type.storage_width}.should eq({20, 4, 16})
    CrystalClick::WideTupleColumnData.new(plan, [empty]).row_count.should eq(0)

    wrong_empty = CrystalClick::WideTupleLeafColumn.new(
      "amount",
      CrystalClick::WideTupleDecimalType.new(21_i32, 4_i32),
      [] of CrystalClick::Decimal128Value
    )
    expect_raises(ArgumentError) { CrystalClick::WideTupleColumnData.new(plan, [wrong_empty]) }
    expect_raises(ArgumentError) do
      CrystalClick::WideTupleLeafColumn.new(
        "amount",
        exact_type,
        [CrystalClick::Decimal128Value.new(7_i128, 19_i32, 4_i32)]
      )
    end

    detached = w101own_detached_decimal_value
    detached.raw.should eq(CrystalClick::Decimal256Value.from_words(1_u64, 2_u64, 3_u64, 4_u64))
    {detached.precision, detached.scale}.should eq({70, 6})
  end

  it "rejects raw carriers instead of relabeling them as parameterized nominal values" do
    fixed = CrystalClick::WideTupleFixedStringType.new(4_i32)
    enum_definition = CrystalClick::WideTupleEnumDefinition.new(
      :enum8,
      [{"active", 1_i16}] of Tuple(String, Int16)
    )
    enum_type = CrystalClick::WideTupleEnumType.new(enum_definition)
    decimal32 = CrystalClick::WideTupleDecimalType.new(9_i32, 2_i32)
    decimal256 = CrystalClick::WideTupleDecimalType.new(70_i32, 2_i32)

    expect_raises(ArgumentError) do
      CrystalClick::WideTupleLeafColumn.new("id", fixed, ["ABCD"] of String)
    end
    expect_raises(ArgumentError) do
      CrystalClick::WideTupleLeafColumn.new("state", enum_type, [1_i8] of Int8)
    end
    expect_raises(ArgumentError) do
      CrystalClick::WideTupleLeafColumn.new("amount", decimal32, [7_i32] of Int32)
    end
    expect_raises(ArgumentError) do
      CrystalClick::WideTupleLeafColumn.new(
        "amount",
        decimal256,
        [CrystalClick::Decimal128Value.new(7_i128, 38_i32, 2_i32)] of CrystalClick::Decimal128Value
      )
    end

    {
      {{ CrystalClick::WideTupleLeafColumn::Buffer.union_types.includes?(Array(CrystalClick::Decimal256TupleValue)) }},
      {{ CrystalClick::WideTupleLeafColumn::Buffer.union_types.includes?(Array(CrystalClick::Decimal256Value)) }},
      {{ CrystalClick::WideTupleNumericType::Buffer.union_types.includes?(Array(CrystalClick::Decimal256TupleValue)) }},
    }.should eq({true, false, false})
  end

  it "keeps Enum quoted text opaque to leaf lexical guards and bounds malformed integers" do
    quoted = "Tuple(state Enum8('DateTime64 (3)' = -1, 'UInt64()' = 2))"
    fields = CrystalClick::WideTupleSchemaParser.parse(quoted)
    fields.should_not be_nil
    if fields
      fields.size.should eq(1)
      fields[0].type_name.should eq("Enum8('DateTime64 (3)' = -1, 'UInt64()' = 2)")
      fields[0].parameterized_type.not_nil!.as(CrystalClick::WideTupleEnumType).width.should eq(1)
    end

    huge_code = "9" * 500
    [
      "Tuple(value Enum8('too-large' = #{huge_code}))",
      "Tuple(value FixedString(#{huge_code}))",
      "Tuple(value Decimal(#{huge_code}, 0))",
      "Tuple(value Enum8('bad\\q' = 0))",
      "Tuple(value Enum8('unterminated = 0))",
      "Tuple(value Tuple(inner Array(UInt64)))",
      "Tuple(UInt64, String)",
    ].each do |source|
      CrystalClick::WideTupleSchemaParser.parse(source).should be_nil
    end

    too_long = "Tuple(value FixedString(4))" + (" " * 4_100)
    CrystalClick::WideTupleSchemaParser.parse(too_long).should be_nil

    nested_enum = CrystalClick::WideTupleSchemaParser.parse(
      "Tuple(group Tuple(state Enum8('DateTime64 (3)' = -1, 'UInt64()' = 2)))"
    ).not_nil!
    nested_enum.map(&.name).should eq(["group.state"])
    nested_enum.first.parameterized_type.not_nil!.as(CrystalClick::WideTupleEnumType).width.should eq(1)
  end

  it "preserves Tuple outer whitespace and applies the bounded node limit once per node" do
    whitespace_fields = CrystalClick::WideTupleSchemaParser.parse(
      "Tuple( value UInt64 , label String  )"
    ).not_nil!
    whitespace_fields.map(&.name).should eq(["value", "label"])

    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_".chars.map(&.to_s)
    names = alphabet.dup
    459.times do |index|
      names << "#{alphabet[index // alphabet.size]}#{alphabet[index % alphabet.size]}"
    end
    source_for = ->(count : Int32) {
      "Tuple(" + names[0, count].map { |name| "#{name} Bool" }.join(",") + ")"
    }
    accepted_source = source_for.call(511)
    rejected_source = source_for.call(512)
    accepted_source.bytesize.should be <= CrystalClick::WideTupleSchemaParser::MAX_SOURCE_BYTES
    rejected_source.bytesize.should be <= CrystalClick::WideTupleSchemaParser::MAX_SOURCE_BYTES
    CrystalClick::WideTupleSchemaParser.parse(accepted_source).not_nil!.size.should eq(511)
    CrystalClick::WideTupleSchemaParser.parse(rejected_source).should be_nil
  end

  it "applies one aggregate source, depth, and syntax-node budget through nested parses" do
    base = "Tuple(value UInt8)"
    exact_source = base + (" " * (CrystalClick::WideTupleSchemaParser::MAX_SOURCE_BYTES - base.bytesize))
    too_long_source = exact_source + " "
    exact_source.bytesize.should eq(CrystalClick::WideTupleSchemaParser::MAX_SOURCE_BYTES)
    CrystalClick::WideTupleSchemaParser.parse_tree(exact_source).should_not be_nil
    CrystalClick::WideTupleSchemaParser.parse_tree(too_long_source).should be_nil

    nested_for_depth = ->(target_depth : Int32) {
      source = "Tuple(value Bool)"
      (target_depth - 1).times { source = "Tuple(child #{source})" }
      source
    }
    CrystalClick::WideTupleSchemaParser.parse_tree(nested_for_depth.call(64)).should_not be_nil
    CrystalClick::WideTupleSchemaParser.parse_tree(nested_for_depth.call(65)).should be_nil

    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_".chars.map(&.to_s)
    outer_names = alphabet[0, 32]
    inner_names = alphabet[0, 15]
    nested_source_for = ->(last_group_leaf_count : Int32) {
      groups = [] of String
      outer_names.each_with_index do |group_name, group_index|
        leaf_count = group_index == outer_names.size - 1 ? last_group_leaf_count : inner_names.size
        leaves = inner_names[0, leaf_count].map_with_index do |leaf_name, leaf_index|
          leaf_type = if group_index == 0 && leaf_index == 0
                        "Nullable(DateTime64(3, 'UTC'))"
                      else
                        "Bool"
                      end
          "#{leaf_name} #{leaf_type}"
        end
        groups << "#{group_name} Tuple(#{leaves.join(",")})"
      end
      "Tuple(#{groups.join(",")})"
    }
    at_node_limit = nested_source_for.call(11)
    over_node_limit = nested_source_for.call(12)
    at_node_limit.bytesize.should be <= CrystalClick::WideTupleSchemaParser::MAX_SOURCE_BYTES
    over_node_limit.bytesize.should be <= CrystalClick::WideTupleSchemaParser::MAX_SOURCE_BYTES
    CrystalClick::WideTupleSchemaParser.parse_tree(at_node_limit).not_nil!.flattened_fields.size.should eq(476)
    CrystalClick::WideTupleSchemaParser.parse_tree(over_node_limit).should be_nil
  end
end
