require "./spec_helper"

private def w155_adv_empty_structure : Bytes
  # Dynamic V3, zero ordinary arms, no statistics.
  Bytes[0x04_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8]
end

private def w155_adv_u64_structure : Bytes
  # Dynamic V3 with one ordinary UInt64 arm.
  Bytes[0x04_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 1_u8, 0x04_u8, 0_u8]
end

private def w155_adv_string_structure : Bytes
  # Dynamic V3 with one ordinary String arm.
  Bytes[0x04_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 1_u8, 0x15_u8, 0_u8]
end

private def w155_adv_pair(
  structures : Hash(String, Bytes),
  mark_count : Int,
  lanes : Hash(String, CrystalClick::BinaryBulkStream),
) : CrystalClick::BinaryDynamicBulkStreams
  CrystalClick::BinaryDynamicBulkStreams.new(
    CrystalClick::BinaryDynamicStructureStreams.new(structures),
    CrystalClick::BinaryBulkStreams.new(mark_count, lanes),
  )
end

private def w155_adv_limits(
  max_depth : Int = 64,
  max_nodes : Int = 100_000,
  max_elements : Int = 300_000,
  max_bytes : Int = 64 * 1024 * 1024,
) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: max_depth,
    max_nodes: max_nodes,
    max_elements: max_elements,
    max_bytes: max_bytes,
  )
end

private def w155_adv_empty_roster_input(
  body : Bytes,
  body_offsets : Array(UInt64),
  discriminators : Bytes,
  discriminator_offsets : Array(UInt64),
) : CrystalClick::BinaryDynamicBulkStreams
  lanes = Hash(String, CrystalClick::BinaryBulkStream).new
  lanes["root.arm.0.data"] = CrystalClick::BinaryBulkStream.new(body, body_offsets)
  lanes["root.discriminators"] = CrystalClick::BinaryBulkStream.new(discriminators, discriminator_offsets)
  w155_adv_pair({"root" => w155_adv_empty_structure}, discriminator_offsets.size - 1, lanes)
end

describe "W155 paired Dynamic bulk adversary controls" do
  it "decodes valid swapped site values, leaving expected site identity to the caller" do
    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    tuple_type = CrystalClick::BinaryDataType.tuple([dynamic_type, dynamic_type] of CrystalClick::BinaryDataType)
    uint64_type = CrystalClick::BinaryDataType.primitive("UInt64")
    string_type = CrystalClick::BinaryDataType.primitive("String")

    # Each occurrence remains internally valid, but the independently supplied
    # actual structures and ordinary payloads are exchanged between site keys.
    lanes = Hash(String, CrystalClick::BinaryBulkStream).new
    lanes["root.field.0.arm.0.data"] = CrystalClick::BinaryBulkStream.new(Bytes.empty, [0_u64, 0_u64])
    lanes["root.field.0.arm.1.data"] = CrystalClick::BinaryBulkStream.new(Bytes[0x01_u8, 0x78_u8], [0_u64, 2_u64])
    lanes["root.field.0.discriminators"] = CrystalClick::BinaryBulkStream.new(Bytes[0x01_u8], [0_u64, 1_u64])
    lanes["root.field.1.arm.0.data"] = CrystalClick::BinaryBulkStream.new(Bytes.empty, [0_u64, 0_u64])
    lanes["root.field.1.arm.1.data"] = CrystalClick::BinaryBulkStream.new(
      Bytes[0x2a_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8],
      [0_u64, 8_u64],
    )
    lanes["root.field.1.discriminators"] = CrystalClick::BinaryBulkStream.new(Bytes[0x01_u8], [0_u64, 1_u64])
    source = w155_adv_pair(
      {
        "root.field.0" => w155_adv_string_structure,
        "root.field.1" => w155_adv_u64_structure,
      },
      1,
      lanes,
    )

    decoded = CrystalClick::BinaryDynamicBulkCodec.decode(tuple_type, source, [1_u64])
    first = decoded[0][0].child_at(0)
    second = decoded[0][0].child_at(1)
    first.type.should eq(dynamic_type)
    first.child_at(0).type.should eq(string_type)
    first.child_at(0).as_string.should eq("x")
    second.type.should eq(dynamic_type)
    second.child_at(0).type.should eq(uint64_type)
    second.child_at(0).as_uint64.should eq(42_u64)

    expected_site_types = {
      "root.field.0" => uint64_type,
      "root.field.1" => string_type,
    }
    observed_site_types = {
      "root.field.0" => first.child_at(0).type,
      "root.field.1" => second.child_at(0).type,
    }
    observed_site_types.should_not eq(expected_site_types)
  end

  it "rejects invalid discriminators, malformed coordinates, and malformed shared envelopes" do
    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 0)

    invalid_tag = w155_adv_empty_roster_input(
      Bytes.empty,
      [0_u64, 0_u64],
      Bytes[0x01_u8],
      [0_u64, 1_u64],
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDynamicBulkCodec.decode(dynamic_type, invalid_tag, [1_u64])
    end

    malformed_offsets = w155_adv_empty_roster_input(
      Bytes.empty,
      [0_u64, 0_u64],
      Bytes[0x00_u8],
      [1_u64, 0_u64],
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDynamicBulkCodec.decode(dynamic_type, malformed_offsets, [1_u64])
    end

    # SingleStream frame says one envelope byte, but UInt8 needs tag and value.
    truncated_envelope = w155_adv_empty_roster_input(
      Bytes[0x01_u8, 0x01_u8],
      [0_u64, 2_u64],
      Bytes[0x00_u8],
      [0_u64, 1_u64],
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDynamicBulkCodec.decode(dynamic_type, truncated_envelope, [1_u64])
    end

    bad_envelope_tag = w155_adv_empty_roster_input(
      Bytes[0x02_u8, 0xff_u8, 0x01_u8],
      [0_u64, 3_u64],
      Bytes[0x00_u8],
      [0_u64, 1_u64],
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDynamicBulkCodec.decode(dynamic_type, bad_envelope_tag, [1_u64])
    end

    # The declared three-byte UInt8 envelope has one trailing byte after value.
    trailing_envelope = w155_adv_empty_roster_input(
      Bytes[0x03_u8, 0x01_u8, 0x01_u8, 0xee_u8],
      [0_u64, 4_u64],
      Bytes[0x00_u8],
      [0_u64, 1_u64],
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDynamicBulkCodec.decode(dynamic_type, trailing_envelope, [1_u64])
    end
  end

  it "requires exact structure-site and data-role closure" do
    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    empty_structure = w155_adv_empty_structure
    valid_lanes = Hash(String, CrystalClick::BinaryBulkStream).new
    valid_lanes["root.arm.0.data"] = CrystalClick::BinaryBulkStream.new(
      Bytes[0x02_u8, 0x01_u8, 0x01_u8],
      [0_u64, 3_u64],
    )
    valid_lanes["root.discriminators"] = CrystalClick::BinaryBulkStream.new(Bytes[0x00_u8], [0_u64, 1_u64])

    missing_site = w155_adv_pair({} of String => Bytes, 1, valid_lanes)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDynamicBulkCodec.decode(dynamic_type, missing_site, [1_u64])
    end

    extra_site = w155_adv_pair(
      {"root" => empty_structure, "root.unexpected" => empty_structure},
      1,
      valid_lanes,
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDynamicBulkCodec.decode(dynamic_type, extra_site, [1_u64])
    end

    missing_role_lanes = valid_lanes.dup
    missing_role_lanes.delete("root.discriminators")
    missing_role = w155_adv_pair({"root" => empty_structure}, 1, missing_role_lanes)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDynamicBulkCodec.decode(dynamic_type, missing_role, [1_u64])
    end

    extra_role_lanes = valid_lanes.dup
    extra_role_lanes["root.unexpected"] = CrystalClick::BinaryBulkStream.new(Bytes.empty, [0_u64, 0_u64])
    extra_role = w155_adv_pair({"root" => empty_structure}, 1, extra_role_lanes)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDynamicBulkCodec.decode(dynamic_type, extra_role, [1_u64])
    end
  end

  it "rebases a nested shared envelope through its containing depth" do
    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    uint8_type = CrystalClick::BinaryDataType.primitive("UInt8")
    dynamic_tuple_type = CrystalClick::BinaryDataType.tuple([dynamic_type] of CrystalClick::BinaryDataType)
    variant_type = CrystalClick::BinaryDataType.variant(
      [uint8_type, dynamic_tuple_type] of CrystalClick::BinaryDataType,
    )
    # Variant forbids Dynamic as a direct arm. The legal Tuple(Dynamic) arm
    # retains the nested Dynamic below the same recursive shared envelope.
    dynamic_tuple_index = variant_type.children.index(dynamic_tuple_type).not_nil!
    dynamic_tuple_index.should eq(0)
    element_tuple_type = CrystalClick::BinaryDataType.tuple([variant_type] of CrystalClick::BinaryDataType)
    array_type = CrystalClick::BinaryDataType.array(element_tuple_type)
    root_type = CrystalClick::BinaryDataType.tuple([dynamic_type] of CrystalClick::BinaryDataType)

    inner_dynamic = CrystalClick::BinaryValue.dynamic(
      dynamic_type,
      CrystalClick::BinaryValue.bool(true),
    )
    selected_tuple = CrystalClick::BinaryValue.tuple(
      dynamic_tuple_type,
      [inner_dynamic] of CrystalClick::BinaryValue,
    )
    selected_variant = CrystalClick::BinaryValue.variant(variant_type, dynamic_tuple_index, selected_tuple)
    selected_element_tuple = CrystalClick::BinaryValue.tuple(
      element_tuple_type,
      [selected_variant] of CrystalClick::BinaryValue,
    )
    selected_array = CrystalClick::BinaryValue.array(
      array_type,
      [selected_element_tuple] of CrystalClick::BinaryValue,
    )
    outer_dynamic = CrystalClick::BinaryValue.dynamic(dynamic_type, selected_array)
    row = CrystalClick::BinaryValue.tuple(root_type, [outer_dynamic] of CrystalClick::BinaryValue)
    granules = [[row] of CrystalClick::BinaryValue] of Array(CrystalClick::BinaryValue)
    structures = {"root.field.0" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)}

    exact_limits = w155_adv_limits(max_depth: 8)
    encoded = CrystalClick::BinaryDynamicBulkCodec.encode(root_type, structures, granules, limits: exact_limits)
    # Literal shared frame: length 14; Array(Tuple(Variant(Tuple(Dynamic), UInt8)))
    # descriptor, then one Array element, canonical Variant arm 0, and
    # Dynamic→Bool.
    shared_lane = Bytes[
      0x0e_u8,
      0x1e_u8, 0x1f_u8, 0x01_u8,
      0x2a_u8, 0x02_u8,
      0x1f_u8, 0x01_u8, 0x2b_u8, 0x00_u8,
      0x01_u8,
      0x01_u8, 0x00_u8, 0x2d_u8, 0x01_u8,
    ]
    encoded.structures.site_paths.should eq(["root.field.0"] of String)
    encoded.data.stream("root.field.0.discriminators").bytes.should eq(Bytes[0x00_u8])
    encoded.data.stream("root.field.0.arm.0.data").bytes.should eq(shared_lane)
    encoded.data.stream("root.field.0.arm.0.data").offsets.should eq([0_u64, 15_u64])

    # Decode separately authored lanes so the expected typed envelope is not
    # generated by the encoder under test.
    literal_lanes = Hash(String, CrystalClick::BinaryBulkStream).new
    literal_lanes["root.field.0.arm.0.data"] = CrystalClick::BinaryBulkStream.new(
      shared_lane,
      [0_u64, 15_u64],
    )
    literal_lanes["root.field.0.discriminators"] = CrystalClick::BinaryBulkStream.new(
      Bytes[0x00_u8],
      [0_u64, 1_u64],
    )
    literal = w155_adv_pair(
      {"root.field.0" => w155_adv_empty_structure},
      1,
      literal_lanes,
    )
    decoded = CrystalClick::BinaryDynamicBulkCodec.decode(
      root_type,
      literal,
      [1_u64],
      limits: exact_limits,
    )
    decoded_inner = decoded[0][0].child_at(0).child_at(0).element_at(0).child_at(0).variant_child?.not_nil!.child_at(0)
    decoded_inner.type.should eq(dynamic_type)
    decoded_inner.child_at(0).as_bool.should be_true

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDynamicBulkCodec.encode(
        root_type,
        structures,
        granules,
        limits: w155_adv_limits(max_depth: 7),
      )
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDynamicBulkCodec.decode(
        root_type,
        literal,
        [1_u64],
        limits: w155_adv_limits(max_depth: 7),
      )
    end
  end

  it "still validates populated stream closure and planning budget for a zero-length window" do
    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    valid_lanes = Hash(String, CrystalClick::BinaryBulkStream).new
    # One valid Shared Bool row, independently authored: frame length 2,
    # Bool tag/value, and one shared discriminator.
    valid_lanes["root.arm.0.data"] = CrystalClick::BinaryBulkStream.new(
      Bytes[0x02_u8, 0x2d_u8, 0x01_u8],
      [0_u64, 3_u64],
    )
    valid_lanes["root.discriminators"] = CrystalClick::BinaryBulkStream.new(
      Bytes[0x00_u8],
      [0_u64, 1_u64],
    )
    source = w155_adv_pair({"root" => w155_adv_empty_structure}, 1, valid_lanes)

    selected_empty = CrystalClick::BinaryDynamicBulkCodec.decode(
      dynamic_type,
      source,
      [1_u64],
      first_mark: 1,
      mark_count: 0,
    )
    selected_empty.should be_empty

    extra_role_lanes = valid_lanes.dup
    extra_role_lanes["root.unexpected"] = CrystalClick::BinaryBulkStream.new(
      Bytes.empty,
      [0_u64, 0_u64],
    )
    extra_role = w155_adv_pair({"root" => w155_adv_empty_structure}, 1, extra_role_lanes)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDynamicBulkCodec.decode(
        dynamic_type,
        extra_role,
        [1_u64],
        first_mark: 1,
        mark_count: 0,
      )
    end

    # Even with no selected rows, the Dynamic root/site planning work is
    # subject to the caller's operation budget.
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDynamicBulkCodec.decode(
        dynamic_type,
        source,
        [1_u64],
        first_mark: 1,
        mark_count: 0,
        limits: w155_adv_limits(max_nodes: 0),
      )
    end
  end

  it "detaches mutable source streams and returned path, byte, and offset snapshots" do
    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    prefix = w155_adv_empty_structure
    envelope = Bytes[0x02_u8, 0x01_u8, 0x01_u8]
    envelope_offsets = [0_u64, 3_u64]
    discriminator = Bytes[0x00_u8]
    discriminator_offsets = [0_u64, 1_u64]

    input_lanes = Hash(String, CrystalClick::BinaryBulkStream).new
    input_lanes["root.arm.0.data"] = CrystalClick::BinaryBulkStream.new(envelope, envelope_offsets)
    input_lanes["root.discriminators"] = CrystalClick::BinaryBulkStream.new(discriminator, discriminator_offsets)
    source = w155_adv_pair({"root" => prefix}, 1, input_lanes)

    # Mutating all caller-owned arrays/slices after construction must not alter
    # the detached paired stream owners.
    prefix[0] = 0xff_u8
    envelope[0] = 0xff_u8
    envelope_offsets[1] = 0_u64
    discriminator[0] = 0xff_u8
    discriminator_offsets[1] = 0_u64

    returned_prefix = source.structures.structure_bytes_for("root")
    returned_prefix[0] = 0xff_u8
    returned_envelope = source.data.stream("root.arm.0.data").bytes
    returned_envelope[0] = 0xff_u8
    returned_offsets = source.data.stream("root.arm.0.data").offsets
    returned_offsets[1] = 0_u64
    returned_roles = source.data.roles
    returned_roles << "root.injected"
    source.data.roles.should eq(["root.arm.0.data", "root.discriminators"] of String)

    source.structures.structure_bytes_for("root")[0].should eq(0x04_u8)
    source.data.stream("root.arm.0.data").bytes.should eq(Bytes[0x02_u8, 0x01_u8, 0x01_u8])
    source.data.stream("root.arm.0.data").offsets.should eq([0_u64, 3_u64])
    source.data.stream("root.discriminators").bytes.should eq(Bytes[0x00_u8])
    source.data.stream("root.discriminators").offsets.should eq([0_u64, 1_u64])

    decoded = CrystalClick::BinaryDynamicBulkCodec.decode(dynamic_type, source, [1_u64])
    decoded[0][0].type.should eq(dynamic_type)
    decoded[0][0].child_at(0).bytes.should eq(Bytes[0x01_u8])
  end
end
