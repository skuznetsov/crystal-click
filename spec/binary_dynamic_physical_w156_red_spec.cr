require "./spec_helper"

private def w156_legacy_dynamic_red(
  type : CrystalClick::BinaryDataType,
  column_name : String,
  expected : Hash(String, String),
) : Nil
  CrystalClick::BinaryBulkPhysicalPlan.new(type, column_name).stream_names.should eq(expected)
end

describe "W156 generic Dynamic physical bindings" do
  it "binds a root UInt64 roster with SharedVariant at canonical index zero" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    prepared = CrystalClick::BinaryDynamicBulkPlan.new(
      dynamic,
      {"root" => CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType)},
    )
    prepared.shared_index("root").should eq(0)
    prepared.select_arm("root", uint64).index.should eq(1)

    data_names = {
      "root.arm.0.data"     => "events%2Etotal.SharedVariant",
      "root.arm.1.data"     => "events%2Etotal.UInt64",
      "root.discriminators" => "events%2Etotal.variant_discr",
    }
    structure_names = {
      "root.dynamic_structure" => "events%2Etotal.dynamic_structure",
    }
    all_names = {
      "root.arm.0.data"        => "events%2Etotal.SharedVariant",
      "root.arm.1.data"        => "events%2Etotal.UInt64",
      "root.discriminators"    => "events%2Etotal.variant_discr",
      "root.dynamic_structure" => "events%2Etotal.dynamic_structure",
    }

    {% if CrystalClick.has_constant?("BinaryDynamicBulkPhysicalPlan") %}
      physical = CrystalClick::BinaryDynamicBulkPhysicalPlan.new(prepared, "events.total")
      physical.data_stream_names.should eq(data_names)
      physical.structure_stream_names.should eq(structure_names)
      physical.stream_names.should eq(all_names)
      physical.structure_name_for("root").should eq("events%2Etotal.dynamic_structure")
      physical.prefix_size_for("root.discriminators").should eq(8)
      physical.prefix_size_for("root.arm.0.data").should eq(0)
      expect_raises(KeyError) { physical.prefix_size_for("root.dynamic_structure") }
      physical.stream_name_for("root.dynamic_structure").should eq("events%2Etotal.dynamic_structure")
      physical.data_file_for("root.discriminators").should eq("events%2Etotal.variant_discr.bin")
      physical.marks_file_for("root.dynamic_structure", hashed: true).should eq(
        "#{CrystalClick::StreamName.hash("events%2Etotal.dynamic_structure")}.mrk2"
      )
      physical.data_file_for("root.discriminators", hashed: true).should eq(
        "#{CrystalClick::StreamName.hash("events%2Etotal.variant_discr")}.bin"
      )

      all_snapshot = physical.stream_names
      data_snapshot = physical.data_stream_names
      structure_snapshot = physical.structure_stream_names
      all_snapshot["root.dynamic_structure"].not_nil!.to_unsafe[0] = 'X'.ord.to_u8
      all_snapshot.keys.find { |role| role == "root.dynamic_structure" }.not_nil!.to_unsafe[0] = 'X'.ord.to_u8
      data_snapshot["root.arm.0.data"].not_nil!.to_unsafe[0] = 'X'.ord.to_u8
      data_snapshot.keys.find { |role| role == "root.arm.0.data" }.not_nil!.to_unsafe[0] = 'X'.ord.to_u8
      structure_snapshot["root.dynamic_structure"].not_nil!.to_unsafe[0] = 'X'.ord.to_u8
      structure_snapshot.keys.find { |role| role == "root.dynamic_structure" }.not_nil!.to_unsafe[0] = 'X'.ord.to_u8
      physical.stream_names.should eq(all_names)
      physical.data_stream_names.should eq(data_names)
      physical.structure_stream_names.should eq(structure_names)
    {% else %}
      w156_legacy_dynamic_red(dynamic, "events.total", all_names)
    {% end %}
  end

  it "binds equal nominal Tuple fields from their distinct UInt64 and String rosters" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    string = CrystalClick::BinaryDataType.primitive("String")
    tuple = CrystalClick::BinaryDataType.tuple(
      [dynamic, dynamic] of CrystalClick::BinaryDataType,
      ["left.value", "right.value"] of String,
    )
    prepared = CrystalClick::BinaryDynamicBulkPlan.new(tuple, {
      "root.field.0" => CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType),
      "root.field.1" => CrystalClick::DynamicStructure.new([string] of CrystalClick::BinaryDataType),
    })
    prepared.arm_type("root.field.0", 1).should eq(uint64)
    prepared.arm_type("root.field.1", 1).should eq(string)

    data_names = {
      "root.field.0.arm.0.data"     => "tuple%2Eleft%2Evalue.SharedVariant",
      "root.field.0.arm.1.data"     => "tuple%2Eleft%2Evalue.UInt64",
      "root.field.0.discriminators" => "tuple%2Eleft%2Evalue.variant_discr",
      "root.field.1.arm.0.data"     => "tuple%2Eright%2Evalue.SharedVariant",
      "root.field.1.arm.1.data"     => "tuple%2Eright%2Evalue.String",
      "root.field.1.discriminators" => "tuple%2Eright%2Evalue.variant_discr",
    }
    structure_names = {
      "root.field.0.dynamic_structure" => "tuple%2Eleft%2Evalue.dynamic_structure",
      "root.field.1.dynamic_structure" => "tuple%2Eright%2Evalue.dynamic_structure",
    }
    all_names = {
      "root.field.0.arm.0.data"        => "tuple%2Eleft%2Evalue.SharedVariant",
      "root.field.0.arm.1.data"        => "tuple%2Eleft%2Evalue.UInt64",
      "root.field.0.discriminators"    => "tuple%2Eleft%2Evalue.variant_discr",
      "root.field.0.dynamic_structure" => "tuple%2Eleft%2Evalue.dynamic_structure",
      "root.field.1.arm.0.data"        => "tuple%2Eright%2Evalue.SharedVariant",
      "root.field.1.arm.1.data"        => "tuple%2Eright%2Evalue.String",
      "root.field.1.discriminators"    => "tuple%2Eright%2Evalue.variant_discr",
      "root.field.1.dynamic_structure" => "tuple%2Eright%2Evalue.dynamic_structure",
    }

    {% if CrystalClick.has_constant?("BinaryDynamicBulkPhysicalPlan") %}
      physical = CrystalClick::BinaryDynamicBulkPhysicalPlan.new(prepared, "tuple")
      physical.data_stream_names.should eq(data_names)
      physical.structure_stream_names.should eq(structure_names)
      physical.stream_names.should eq(all_names)
      physical.structure_name_for("root.field.0").should eq("tuple%2Eleft%2Evalue.dynamic_structure")
      physical.structure_name_for("root.field.1").should eq("tuple%2Eright%2Evalue.dynamic_structure")
    {% else %}
      w156_legacy_dynamic_red(tuple, "tuple", all_names)
    {% end %}
  end

  it "preserves array levels through a Dynamic arm and static Variant with an unused nested site" do
    nested_dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 32)
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    tuple_dynamic = CrystalClick::BinaryDataType.tuple(
      [nested_dynamic] of CrystalClick::BinaryDataType,
    )
    static_variant = CrystalClick::BinaryDataType.variant(
      [tuple_dynamic, uint64] of CrystalClick::BinaryDataType,
    )
    dynamic_array_arm = CrystalClick::BinaryDataType.array(static_variant)
    outer_dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    declared = CrystalClick::BinaryDataType.array(outer_dynamic)
    nested_path = "root.elements.arm.0.elements.arm.0.field.0"
    prepared = CrystalClick::BinaryDynamicBulkPlan.new(declared, {
      "root.elements" => CrystalClick::DynamicStructure.new([dynamic_array_arm] of CrystalClick::BinaryDataType),
      nested_path     => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType),
    })
    prepared.site_paths.should eq(["root.elements", nested_path] of String)
    prepared.shared_index("root.elements").should eq(1)
    prepared.shared_index(nested_path).should eq(0)
    prepared.arm_count(nested_path).should eq(1)
    prepared.structure_for(nested_path).type_count.should eq(0)

    array_arm_prefix = "nested.Array%28Variant%28Tuple%28Dynamic%29%2C%20UInt64%29%29"
    nested_dynamic_prefix = "#{array_arm_prefix}.Tuple%28Dynamic%29%2E1"
    data_names = {
      "root.sizes"                                  => "nested.size0",
      "root.elements.discriminators"                => "nested.variant_discr",
      "root.elements.arm.0.sizes"                   => "#{array_arm_prefix}.size1",
      "root.elements.arm.0.elements.discriminators" => "#{array_arm_prefix}.variant_discr",
      "#{nested_path}.discriminators"               => "#{nested_dynamic_prefix}.variant_discr",
      "#{nested_path}.arm.0.data"                   => "#{nested_dynamic_prefix}.SharedVariant",
      "root.elements.arm.0.elements.arm.1.data"     => "#{array_arm_prefix}.UInt64",
      "root.elements.arm.1.data"                    => "nested.SharedVariant",
    }
    structure_names = {
      "root.elements.dynamic_structure"  => "nested.dynamic_structure",
      "#{nested_path}.dynamic_structure" => "#{nested_dynamic_prefix}.dynamic_structure",
    }
    all_names = {
      "root.sizes"                                  => "nested.size0",
      "root.elements.discriminators"                => "nested.variant_discr",
      "root.elements.arm.0.sizes"                   => "#{array_arm_prefix}.size1",
      "root.elements.arm.0.elements.discriminators" => "#{array_arm_prefix}.variant_discr",
      "#{nested_path}.discriminators"               => "#{nested_dynamic_prefix}.variant_discr",
      "#{nested_path}.arm.0.data"                   => "#{nested_dynamic_prefix}.SharedVariant",
      "root.elements.arm.0.elements.arm.1.data"     => "#{array_arm_prefix}.UInt64",
      "root.elements.arm.1.data"                    => "nested.SharedVariant",
      "root.elements.dynamic_structure"             => "nested.dynamic_structure",
      "#{nested_path}.dynamic_structure"            => "#{nested_dynamic_prefix}.dynamic_structure",
    }

    {% if CrystalClick.has_constant?("BinaryDynamicBulkPhysicalPlan") %}
      physical = CrystalClick::BinaryDynamicBulkPhysicalPlan.new(prepared, "nested")
      physical.data_stream_names.should eq(data_names)
      physical.structure_stream_names.should eq(structure_names)
      physical.stream_names.should eq(all_names)
      physical.structure_name_for("root.elements").should eq("nested.dynamic_structure")
      physical.structure_name_for(nested_path).should eq("#{nested_dynamic_prefix}.dynamic_structure")
    {% else %}
      w156_legacy_dynamic_red(declared, "nested", all_names)
    {% end %}
  end
end
