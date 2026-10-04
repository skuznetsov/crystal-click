require "./spec_helper"

private def w149_adv_escape(raw : String) : String
  hex = "0123456789ABCDEF"
  String.build do |io|
    raw.to_slice.each do |byte|
      word = (byte >= 'A'.ord.to_u8 && byte <= 'Z'.ord.to_u8) ||
             (byte >= 'a'.ord.to_u8 && byte <= 'z'.ord.to_u8) ||
             (byte >= '0'.ord.to_u8 && byte <= '9'.ord.to_u8) ||
             byte == '_'.ord.to_u8
      if word
        io.write_byte(byte)
      else
        io.write_byte('%'.ord.to_u8)
        io.write_byte(hex.byte_at((byte >> 4).to_i))
        io.write_byte(hex.byte_at((byte & 0x0f).to_i))
      end
    end
  end
end

private def w149_adv_component(prefix : String, raw : String) : String
  "#{prefix}.#{w149_adv_escape(raw)}"
end

private def w149_adv_field(prefix : String, raw : String) : String
  "#{prefix}%2E#{w149_adv_escape(raw)}"
end

private def w149_adv_limits(
  max_depth : Int = 8,
  max_nodes : Int = 64,
  max_elements : Int = 256,
  max_bytes : Int = 16_384,
) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: max_depth,
    max_nodes: max_nodes,
    max_elements: max_elements,
    max_bytes: max_bytes,
  )
end

private def w149_adv_empty_object_streams : CrystalClick::ObjectDocumentStreams
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new([] of String),
    {} of String => CrystalClick::DynamicStructure,
  )
  metadata = CrystalClick::ObjectDynamicStructureCodec.encode(structures)
  shared = CrystalClick::BinaryBulkStreams.new(
    0,
    {} of String => CrystalClick::BinaryBulkStream,
  )
  CrystalClick::ObjectDocumentStreams.new(
    metadata,
    [] of UInt64,
    {} of String => CrystalClick::BinaryBulkStreams,
    {} of String => CrystalClick::DynamicValueStreams,
    shared,
  )
end

describe "W149 generic Variant physical binding adversaries" do
  it "escapes complete Enum and temporal SQL spellings as arm path components" do
    enum_type = CrystalClick::BinaryDataType.enum8([
      {"label.with.dot", 1_i16},
    ] of CrystalClick::BinaryEnumDefinition::Entry)
    temporal = CrystalClick::BinaryDataType.datetime64(3, "America/New_York")
    enum_type.name.should eq("Enum8('label.with.dot' = 1)")
    temporal.name.should eq("DateTime64(3, 'America/New_York')")

    type = CrystalClick::BinaryDataType.variant([enum_type, temporal] of CrystalClick::BinaryDataType)
    plan = CrystalClick::BinaryBulkPhysicalPlan.new(type, "typed")
    expected = {"root.discriminators" => "typed.variant_discr"} of String => String
    type.child_count.times do |index|
      expected["root.arm.#{index}.data"] = w149_adv_component("typed", type.child_at(index).name)
    end

    plan.stream_names.should eq(expected)
    plan.prefix_size_for("root.discriminators").should eq(8)
    type.child_count.times do |index|
      plan.prefix_size_for("root.arm.#{index}.data").should eq(0)
    end
  end

  it "carries the enclosing Array level through VariantElement to a nested Array arm" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    nested_array = CrystalClick::BinaryDataType.array(uint64)
    variant = CrystalClick::BinaryDataType.variant([nested_array, uint8] of CrystalClick::BinaryDataType)
    type = CrystalClick::BinaryDataType.array(variant)
    plan = CrystalClick::BinaryBulkPhysicalPlan.new(type, "values")

    nested_array_prefix = w149_adv_component("values", nested_array.name)
    uint8_prefix = w149_adv_component("values", uint8.name)
    plan.stream_names.should eq({
      "root.sizes"                        => "values.size0",
      "root.elements.discriminators"      => "values.variant_discr",
      "root.elements.arm.0.sizes"         => "#{nested_array_prefix}.size1",
      "root.elements.arm.0.elements.data" => nested_array_prefix,
      "root.elements.arm.1.data"          => uint8_prefix,
    })
    plan.prefix_size_for("root.elements.discriminators").should eq(8)
  end

  it "preserves nested Variant arm spellings, discriminator ownership, and Array levels" do
    string = CrystalClick::BinaryDataType.primitive("String")
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    inner_variant = CrystalClick::BinaryDataType.variant([string, uint64] of CrystalClick::BinaryDataType)
    variant_array = CrystalClick::BinaryDataType.array(inner_variant)
    outer_variant = CrystalClick::BinaryDataType.variant([variant_array, uint64] of CrystalClick::BinaryDataType)
    type = CrystalClick::BinaryDataType.array(outer_variant)

    # Canonical arm order is by complete SQL spelling. The inner Variant is
    # reached through an Array arm, but its discriminator remains a distinct
    # role at that arm's SQL-name prefix.
    outer_arm_prefix = w149_adv_component("nested", variant_array.name)
    inner_string_prefix = w149_adv_component(outer_arm_prefix, string.name)
    inner_uint64_prefix = w149_adv_component(outer_arm_prefix, uint64.name)
    outer_uint64_prefix = w149_adv_component("nested", uint64.name)
    plan = CrystalClick::BinaryBulkPhysicalPlan.new(type, "nested")

    plan.stream_names.should eq({
      "root.sizes"                                  => "nested.size0",
      "root.elements.discriminators"                => "nested.variant_discr",
      "root.elements.arm.0.sizes"                   => "#{outer_arm_prefix}.size1",
      "root.elements.arm.0.elements.discriminators" => "#{outer_arm_prefix}.variant_discr",
      "root.elements.arm.0.elements.arm.0.data"     => inner_string_prefix,
      "root.elements.arm.0.elements.arm.1.data"     => inner_uint64_prefix,
      "root.elements.arm.1.data"                    => outer_uint64_prefix,
    })
    plan.prefix_size_for("root.elements.discriminators").should eq(8)
    plan.prefix_size_for("root.elements.arm.0.elements.discriminators").should eq(8)

    # A returned physical arm name is a detached String, not a mutable view of
    # the retained name cache or a later binding result.
    arm_role = "root.elements.arm.0.elements.arm.0.data"
    detached = plan.stream_name_for(arm_role)
    detached.to_unsafe[0] = 'X'.ord.to_u8
    plan.stream_name_for(arm_role).should eq(inner_string_prefix)
  end

  it "admits Nullable around a Tuple containing Variant without making Variant a direct Nullable child" do
    string = CrystalClick::BinaryDataType.primitive("String")
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    variant = CrystalClick::BinaryDataType.variant([string, uint64] of CrystalClick::BinaryDataType)
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    tuple = CrystalClick::BinaryDataType.tuple(
      [variant, uint8] of CrystalClick::BinaryDataType,
      ["payload", "flag"] of String,
    )
    nullable = CrystalClick::BinaryDataType.nullable(tuple)
    nullable.name.should eq("Nullable(Tuple(payload Variant(String, UInt64), flag UInt8))")

    payload_prefix = w149_adv_field("nullable", "payload")
    flag_prefix = w149_adv_field("nullable", "flag")
    plan = CrystalClick::BinaryBulkPhysicalPlan.new(nullable, "nullable")
    plan.stream_names.should eq({
      "root.nulls"                         => "nullable.null",
      "root.nested.field.0.discriminators" => "#{payload_prefix}.variant_discr",
      "root.nested.field.0.arm.0.data"     => w149_adv_component(payload_prefix, string.name),
      "root.nested.field.0.arm.1.data"     => w149_adv_component(payload_prefix, uint64.name),
      "root.nested.field.1.data"           => flag_prefix,
    })

    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.nullable(variant)
    end
  end

  it "composes Map, named Tuple, and Variant paths without conflating escaped sibling dots" do
    enum_type = CrystalClick::BinaryDataType.enum8([
      {"enum/path", 1_i16},
    ] of CrystalClick::BinaryEnumDefinition::Entry)
    temporal = CrystalClick::BinaryDataType.datetime64(9, "America/New_York")
    variant = CrystalClick::BinaryDataType.variant([enum_type, temporal] of CrystalClick::BinaryDataType)
    named = CrystalClick::BinaryDataType.tuple(
      [variant, CrystalClick::BinaryDataType.primitive("String")] of CrystalClick::BinaryDataType,
      ["label.with.dot", "label"] of String,
    )
    type = CrystalClick::BinaryDataType.map(CrystalClick::BinaryDataType.primitive("String"), named)
    plan = CrystalClick::BinaryBulkPhysicalPlan.new(type, "mapped")

    keys_prefix = w149_adv_field("mapped", "keys")
    values_prefix = w149_adv_field("mapped", "values")
    variant_prefix = w149_adv_field(values_prefix, "label.with.dot")
    sibling_prefix = w149_adv_field(values_prefix, "label")
    expected = {
      "root.sizes"                                   => "mapped.size0",
      "root.elements.field.0.data"                   => keys_prefix,
      "root.elements.field.1.field.0.discriminators" => "#{variant_prefix}.variant_discr",
      "root.elements.field.1.field.1.data"           => sibling_prefix,
    } of String => String
    variant.child_count.times do |index|
      expected["root.elements.field.1.field.0.arm.#{index}.data"] =
        w149_adv_component(variant_prefix, variant.child_at(index).name)
    end
    plan.stream_names.should eq(expected)

    # Tuple dots are escaped inside a field component, while Variant's
    # discriminator dot is structural. These sibling paths must stay distinct.
    sibling_variant = CrystalClick::BinaryDataType.variant([
      CrystalClick::BinaryDataType.primitive("String"),
      CrystalClick::BinaryDataType.primitive("UInt64"),
    ] of CrystalClick::BinaryDataType)
    siblings = CrystalClick::BinaryDataType.tuple(
      [CrystalClick::BinaryDataType.primitive("String"), sibling_variant] of CrystalClick::BinaryDataType,
      ["a.variant_discr", "a"] of String,
    )
    sibling_plan = CrystalClick::BinaryBulkPhysicalPlan.new(siblings, "s")
    sibling_plan.stream_name_for("root.field.0.data").should eq("s%2Ea%2Evariant_discr")
    sibling_plan.stream_name_for("root.field.1.discriminators").should eq("s%2Ea.variant_discr")
  end

  it "rejects true collisions between equivalent arm paths reached through different Tuple shapes" do
    variant = CrystalClick::BinaryDataType.variant([
      CrystalClick::BinaryDataType.primitive("String"),
      CrystalClick::BinaryDataType.primitive("UInt64"),
    ] of CrystalClick::BinaryDataType)
    nested = CrystalClick::BinaryDataType.tuple(
      [variant] of CrystalClick::BinaryDataType,
      ["b"] of String,
    )
    colliding = CrystalClick::BinaryDataType.tuple(
      [variant, nested] of CrystalClick::BinaryDataType,
      ["a.b", "a"] of String,
    )

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkPhysicalPlan.new(colliding, "column")
    end
  end

  it "keeps typed Object and Dynamic consumers closed after generic binding admission" do
    variant = CrystalClick::BinaryDataType.variant([
      CrystalClick::BinaryDataType.primitive("String"),
      CrystalClick::BinaryDataType.primitive("UInt64"),
    ] of CrystalClick::BinaryDataType)
    types = [
      variant,
      CrystalClick::BinaryDataType.array(variant),
      CrystalClick::BinaryDataType.tuple([variant] of CrystalClick::BinaryDataType),
      CrystalClick::BinaryDataType.map(CrystalClick::BinaryDataType.primitive("UInt8"), variant),
    ] of CrystalClick::BinaryDataType
    empty_structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    )
    empty_streams = w149_adv_empty_object_streams

    types.each do |type|
      dynamic_error = expect_raises(ArgumentError) do
        CrystalClick::DynamicStructure.new([type] of CrystalClick::BinaryDataType)
      end
      dynamic_error.message.not_nil!.should contain("Variant")

      plan = CrystalClick::ObjectDocumentPlan.new(empty_structures, {"typed" => type})
      physical_error = expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentPhysicalPlan.new("doc", plan)
      end
      physical_error.message.not_nil!.should contain("Variant")
      encode_error = expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentCodec.encode(plan, [] of Array(CrystalClick::ObjectDocument))
      end
      encode_error.message.not_nil!.should contain("Variant")
      decode_error = expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentCodec.decode({"typed" => type}, empty_streams)
      end
      decode_error.message.not_nil!.should contain("Variant")
      file_error = expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentFileReader.inspect(
          "/__w149_variant_guard_must_precede_filesystem__",
          "doc",
          {"typed" => type},
        )
      end
      file_error.message.not_nil!.should contain("Variant")
    end
  end

  it "still charges physical type depth, nodes, and role elements before binding" do
    type = CrystalClick::BinaryDataType.variant([
      CrystalClick::BinaryDataType.primitive("String"),
      CrystalClick::BinaryDataType.primitive("UInt64"),
    ] of CrystalClick::BinaryDataType)
    generous = CrystalClick::BinaryCodecLimits.new(
      max_depth: 8,
      max_nodes: 64,
      max_elements: 256,
      max_bytes: 16_384,
    )
    CrystalClick::BinaryBulkPhysicalPlan.new(type, "budgeted", limits: generous).stream_names.size.should eq(3)

    [
      CrystalClick::BinaryCodecLimits.new(max_depth: 0, max_nodes: 64, max_elements: 256, max_bytes: 16_384),
      CrystalClick::BinaryCodecLimits.new(max_depth: 8, max_nodes: 1, max_elements: 256, max_bytes: 16_384),
      CrystalClick::BinaryCodecLimits.new(max_depth: 8, max_nodes: 64, max_elements: 1, max_bytes: 16_384),
    ].each do |short|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryBulkPhysicalPlan.new(type, "budgeted", limits: short)
      end
    end
  end

  it "preflights conservative Variant name work exactly and aggregates shared contexts" do
    type = CrystalClick::BinaryDataType.variant([
      CrystalClick::BinaryDataType.primitive("String"),
      CrystalClick::BinaryDataType.primitive("UInt64"),
    ] of CrystalClick::BinaryDataType)

    # For this flat type: descriptor nodes are Variant + 2 arms (3); depth
    # is one arm below the root; elements are 2 child edges + 3 physical roles
    # + 1 Variant site + 2 arm-name occurrences + 1 discriminator-prefix key
    # (9). For bytes, the physical preflight is 49 role bytes + 115
    # conservative basenames (15 discriminator + 2 * (2-byte prefix +
    # 3 * 16-byte arm-name bound)) + 64 shared SQL-name work bytes + 19 bytes
    # for the discriminator-prefix role key (247). This is a conservative
    # admission bound, not an exact retained-allocation or RSS claim.
    exact = w149_adv_limits(max_depth: 1, max_nodes: 3, max_elements: 9, max_bytes: 247)
    CrystalClick::BinaryBulkPhysicalPlan.new(type, "v", limits: exact).stream_names.size.should eq(3)

    [
      w149_adv_limits(max_depth: 0, max_nodes: 3, max_elements: 9, max_bytes: 247),
      w149_adv_limits(max_depth: 1, max_nodes: 2, max_elements: 9, max_bytes: 247),
      w149_adv_limits(max_depth: 1, max_nodes: 3, max_elements: 8, max_bytes: 247),
      w149_adv_limits(max_depth: 1, max_nodes: 3, max_elements: 9, max_bytes: 246),
    ].each do |short|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryBulkPhysicalPlan.new(type, "v", limits: short)
      end
    end

    shared_exact = w149_adv_limits(max_depth: 1, max_nodes: 6, max_elements: 18, max_bytes: 410)
    exact_context = CrystalClick::PhysicalStreamPlanContext.new(shared_exact)
    CrystalClick::BinaryBulkPhysicalPlan.new(type, "v", limits: shared_exact, context: exact_context)
    CrystalClick::BinaryBulkPhysicalPlan.new(type, "v", limits: shared_exact, context: exact_context)

    short_bytes = w149_adv_limits(max_depth: 1, max_nodes: 6, max_elements: 18, max_bytes: 409)
    short_bytes_context = CrystalClick::PhysicalStreamPlanContext.new(short_bytes)
    CrystalClick::BinaryBulkPhysicalPlan.new(type, "v", limits: short_bytes, context: short_bytes_context)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkPhysicalPlan.new(type, "v", limits: short_bytes, context: short_bytes_context)
    end

    short_nodes = w149_adv_limits(max_depth: 1, max_nodes: 5, max_elements: 18, max_bytes: 410)
    short_nodes_context = CrystalClick::PhysicalStreamPlanContext.new(short_nodes)
    CrystalClick::BinaryBulkPhysicalPlan.new(type, "v", limits: short_nodes, context: short_nodes_context)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkPhysicalPlan.new(type, "v", limits: short_nodes, context: short_nodes_context)
    end

    short_elements = w149_adv_limits(max_depth: 1, max_nodes: 6, max_elements: 17, max_bytes: 410)
    short_elements_context = CrystalClick::PhysicalStreamPlanContext.new(short_elements)
    CrystalClick::BinaryBulkPhysicalPlan.new(type, "v", limits: short_elements, context: short_elements_context)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkPhysicalPlan.new(type, "v", limits: short_elements, context: short_elements_context)
    end
  end

  it "rejects an over-depth descriptor passed directly to the Variant name owner" do
    string = CrystalClick::BinaryDataType.primitive("String")
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    inner = CrystalClick::BinaryDataType.variant([string, uint64] of CrystalClick::BinaryDataType)
    type = CrystalClick::BinaryDataType.variant([
      CrystalClick::BinaryDataType.array(inner),
      uint64,
    ] of CrystalClick::BinaryDataType)
    shallow = w149_adv_limits(max_depth: 2, max_nodes: 64, max_elements: 256, max_bytes: 16_384)
    context = CrystalClick::PhysicalStreamPlanContext.new(shallow)

    # The deepest descriptor leaves are at depth 3. This directly exercises
    # the occurrence-name owner, not only BinaryBulkPhysicalPlan's outer
    # descriptor validator. It checks the refusal behavior, not allocation
    # timing.
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkVariantNamePlan.new(type, shallow, context)
    end
  end

  it "shares the auxiliary node budget across repeated nested arm-name occurrences" do
    string = CrystalClick::BinaryDataType.primitive("String")
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    inner = CrystalClick::BinaryDataType.variant([string, uint64] of CrystalClick::BinaryDataType)
    type = CrystalClick::BinaryDataType.variant([
      CrystalClick::BinaryDataType.array(inner),
      uint64,
    ] of CrystalClick::BinaryDataType)

    # The physical descriptor has 6 nodes. Rendering every Variant arm name
    # visits 7 nodes: the Array(Variant(...)) arm subtree (4), outer UInt64
    # arm (1), and the inner Variant's two arm names (2). A fresh budget per
    # arm would incorrectly admit max_nodes 6; one shared name budget needs 7.
    exact = w149_adv_limits(max_depth: 3, max_nodes: 7, max_elements: 256, max_bytes: 16_384)
    CrystalClick::BinaryBulkVariantNamePlan.new(
      type, exact, CrystalClick::PhysicalStreamPlanContext.new(exact)
    )

    short = w149_adv_limits(max_depth: 3, max_nodes: 6, max_elements: 256, max_bytes: 16_384)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkVariantNamePlan.new(
        type, short, CrystalClick::PhysicalStreamPlanContext.new(short)
      )
    end
  end

  it "charges directly materialized Variant names to the shared physical byte context" do
    type = CrystalClick::BinaryDataType.variant([
      CrystalClick::BinaryDataType.primitive("String"),
      CrystalClick::BinaryDataType.primitive("UInt64"),
    ] of CrystalClick::BinaryDataType)
    limits = w149_adv_limits(max_depth: 8, max_nodes: 64, max_elements: 256, max_bytes: 247)

    exact_context = CrystalClick::PhysicalStreamPlanContext.new(limits)
    exact_context.charge_name_bytes(183_u64)
    exact_names = CrystalClick::BinaryBulkVariantNamePlan.new(type, limits, exact_context)
    exact_names.materialize! # 183 already charged + 64 name-work bytes = 247

    short_context = CrystalClick::PhysicalStreamPlanContext.new(limits)
    short_context.charge_name_bytes(184_u64)
    short_names = CrystalClick::BinaryBulkVariantNamePlan.new(type, limits, short_context)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      short_names.materialize! # One byte beyond the shared context limit.
    end
  end

  it "returns fresh prefixes rather than mutable aliases to cached arm SQL names" do
    type = CrystalClick::BinaryDataType.variant([
      CrystalClick::BinaryDataType.primitive("String"),
      CrystalClick::BinaryDataType.primitive("UInt64"),
    ] of CrystalClick::BinaryDataType)
    limits = w149_adv_limits()
    names = CrystalClick::BinaryBulkVariantNamePlan.new(
      type, limits, CrystalClick::PhysicalStreamPlanContext.new(limits)
    )
    names.materialize!
    site = names.next_append_site

    rendered = names.append_escaped_arm_prefix("v", site, 0)
    rendered.to_unsafe[0] = 'X'.ord.to_u8
    names.append_escaped_arm_prefix("v", site, 0).should eq("v.String")
  end
end
