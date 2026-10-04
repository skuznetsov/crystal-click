require "./spec_helper"

private def w149_variant_string_uint64 : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.variant([
    CrystalClick::BinaryDataType.primitive("String"),
    CrystalClick::BinaryDataType.primitive("UInt64"),
  ] of CrystalClick::BinaryDataType)
end

private def w149_variant_lc_string_uint64 : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.variant([
    CrystalClick::BinaryDataType.low_cardinality(CrystalClick::BinaryDataType.primitive("String")),
    CrystalClick::BinaryDataType.primitive("UInt64"),
  ] of CrystalClick::BinaryDataType)
end

describe "W149 generic Variant physical stream binding" do
  it "binds direct canonical arms and discriminator lanes under both String profiles" do
    type = w149_variant_string_uint64
    single = CrystalClick::BinaryBulkPhysicalPlan.new(type, "v")
    single.stream_names.should eq({
      "root.discriminators" => "v.variant_discr",
      "root.arm.0.data"     => "v.String",
      "root.arm.1.data"     => "v.UInt64",
    })
    single.prefix_size_for("root.discriminators").should eq(8)
    single.prefix_size_for("root.arm.0.data").should eq(0)
    single.prefix_size_for("root.arm.1.data").should eq(0)

    sized = CrystalClick::BinaryBulkPhysicalPlan.new(
      type,
      "v",
      profile: CrystalClick::BinaryBulkProfile.with_size_stream
    )
    sized.stream_names.should eq({
      "root.discriminators"     => "v.variant_discr",
      "root.arm.0.data"         => "v.String",
      "root.arm.0.string_sizes" => "v.String.size",
      "root.arm.1.data"         => "v.UInt64",
    })
    sized.prefix_size_for("root.discriminators").should eq(8)
    sized.prefix_size_for("root.arm.0.data").should eq(0)
    sized.prefix_size_for("root.arm.0.string_sizes").should eq(0)
    sized.prefix_size_for("root.arm.1.data").should eq(0)
  end

  it "binds Array-of-Variant sizes, discriminator, and an LC arm stop-site" do
    type = CrystalClick::BinaryDataType.array(w149_variant_lc_string_uint64)
    plan = CrystalClick::BinaryBulkPhysicalPlan.new(type, "v")

    plan.stream_names.should eq({
      "root.sizes"                     => "v.size0",
      "root.elements.discriminators"   => "v.variant_discr",
      "root.elements.arm.0.dictionary" => "v.LowCardinality%28String%29.dict",
      "root.elements.arm.0.indexes"    => "v.LowCardinality%28String%29",
      "root.elements.arm.1.data"       => "v.UInt64",
    })
    plan.prefix_size_for("root.sizes").should eq(0)
    plan.prefix_size_for("root.elements.discriminators").should eq(8)
    plan.prefix_size_for("root.elements.arm.0.dictionary").should eq(8)
    plan.prefix_size_for("root.elements.arm.0.indexes").should eq(0)
    plan.prefix_size_for("root.elements.arm.1.data").should eq(0)
  end

  it "distinguishes raw and escaped prefixes, hashes complete names, and detaches names" do
    type = w149_variant_string_uint64
    raw = CrystalClick::BinaryBulkPhysicalPlan.new(type, "doc.path/name%")
    raw.stream_names.should eq({
      "root.discriminators" => "doc%2Epath%2Fname%25.variant_discr",
      "root.arm.0.data"     => "doc%2Epath%2Fname%25.String",
      "root.arm.1.data"     => "doc%2Epath%2Fname%25.UInt64",
    })
    raw.data_file_for("root.discriminators").should eq("doc%2Epath%2Fname%25.variant_discr.bin")
    raw.marks_file_for("root.discriminators").should eq("doc%2Epath%2Fname%25.variant_discr.mrk2")
    raw.data_file_for("root.discriminators", hashed: true).should eq(
      "#{CrystalClick::StreamName.hash("doc%2Epath%2Fname%25.variant_discr")}.bin"
    )
    raw.marks_file_for("root.arm.0.data", hashed: true).should eq(
      "#{CrystalClick::StreamName.hash("doc%2Epath%2Fname%25.String")}.mrk2"
    )

    escaped = CrystalClick::BinaryBulkPhysicalPlan.from_escaped_prefix(
      type, "doc.path%2Fname%25"
    )
    escaped.stream_names.should eq({
      "root.discriminators" => "doc.path%2Fname%25.variant_discr",
      "root.arm.0.data"     => "doc.path%2Fname%25.String",
      "root.arm.1.data"     => "doc.path%2Fname%25.UInt64",
    })

    column_name = String.new("owned/path%".to_slice)
    retained = CrystalClick::BinaryBulkPhysicalPlan.new(type, column_name)
    column_name.to_unsafe[0] = 'X'.ord.to_u8
    detached = retained.stream_names
    role_key = detached.keys.find { |role| role == "root.discriminators" }.not_nil!
    role_name = detached["root.discriminators"].not_nil!
    role_key.to_unsafe[0] = 'X'.ord.to_u8
    role_name.to_unsafe[0] = 'Y'.ord.to_u8
    returned = retained.stream_name_for("root.arm.0.data")
    returned.to_unsafe[0] = 'Z'.ord.to_u8

    retained.stream_names.should eq({
      "root.discriminators" => "owned%2Fpath%25.variant_discr",
      "root.arm.0.data"     => "owned%2Fpath%25.String",
      "root.arm.1.data"     => "owned%2Fpath%25.UInt64",
    })
    retained.stream_name_for("root.arm.0.data").should eq("owned%2Fpath%25.String")
  end
end
