require "./spec_helper"

private def w199_qbit_type : CrystalClick::QBitType
  CrystalClick::QBitType.new("Int8", 16_u64, 8_u64)
end

private def w199_qbit_raw_row : Bytes
  # Descending then ascending single-bit bytes make the two stride groups and
  # the element-bit planes independently distinguishable.
  Bytes[
    0x80_u8, 0x40_u8, 0x20_u8, 0x10_u8, 0x08_u8, 0x04_u8, 0x02_u8, 0x01_u8,
    0x01_u8, 0x02_u8, 0x04_u8, 0x08_u8, 0x10_u8, 0x20_u8, 0x40_u8, 0x80_u8,
  ]
end

private def w199_dynamic_qbit_envelope : Bytes
  Bytes[
    0x2b_u8, 0x01_u8,                   # Dynamic(max_types=1)
    0x37_u8, 0x07_u8, 0x10_u8, 0x08_u8, # QBit(Int8, 16, 8)
    0x10_u8,                            # dimension in the scalar value
    0x80_u8, 0x40_u8, 0x20_u8, 0x10_u8, 0x08_u8, 0x04_u8, 0x02_u8, 0x01_u8,
    0x01_u8, 0x02_u8, 0x04_u8, 0x08_u8, 0x10_u8, 0x20_u8, 0x40_u8, 0x80_u8,
  ]
end

private def w199_dynamic_qbit_structure : Bytes
  # Full Dynamic bulk metadata adds its statistics flag after the descriptor.
  Bytes[
    0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    0x01_u8, 0x37_u8, 0x07_u8, 0x10_u8, 0x08_u8, 0x00_u8,
  ]
end

private def w199_dynamic_qbit_bulk_streams : CrystalClick::BinaryDynamicBulkStreams
  lanes = Hash(String, CrystalClick::BinaryBulkStream).new
  lanes["root.discriminators"] = CrystalClick::BinaryBulkStream.new(Bytes[0x00_u8], [0_u64, 1_u64])
  16.times do |plane|
    lanes["root.arm.0.qbit_plane.#{plane}"] = CrystalClick::BinaryBulkStream.new(
      Bytes[0x00_u8], [0_u64, 1_u64],
    )
  end
  # The implicit SharedVariant arm is not selected for the literal row.
  lanes["root.arm.1.data"] = CrystalClick::BinaryBulkStream.new(Bytes.empty, [0_u64, 0_u64])
  CrystalClick::BinaryDynamicBulkStreams.new(
    CrystalClick::BinaryDynamicStructureStreams.new({"root" => w199_dynamic_qbit_structure}),
    CrystalClick::BinaryBulkStreams.new(1, lanes),
  )
end

private def w199_qbit_dynamic_path_data : Bytes
  Bytes[
    # Dynamic V3 no-stat prefix, one QBit ordinary arm.
    0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    0x01_u8, 0x37_u8, 0x07_u8, 0x10_u8, 0x08_u8,
    # COMPACT discriminator prefix and one uniform ordinary-arm tag (QBit is
    # canonical arm zero, before the implicit SharedVariant).
    0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    0x01_u8, 0x01_u8, 0x00_u8,
    # Group-major QBit planes, independently derived from the raw row above.
    0x01_u8, 0x02_u8, 0x04_u8, 0x08_u8, 0x10_u8, 0x20_u8, 0x40_u8, 0x80_u8,
    0x80_u8, 0x40_u8, 0x20_u8, 0x10_u8, 0x08_u8, 0x04_u8, 0x02_u8, 0x01_u8,
  ]
end

private def w199_qbit_dynamic_path_events : Array(CrystalClick::ObjectSharedPathSubstreamEvent)
  events = [
    CrystalClick::ObjectSharedPathSubstreamEvent.new(".dynamic_structure", 0_u64),
    CrystalClick::ObjectSharedPathSubstreamEvent.new(".variant_discr_prefix", 13_u64),
    CrystalClick::ObjectSharedPathSubstreamEvent.new(".variant_discr", 21_u64),
  ] of CrystalClick::ObjectSharedPathSubstreamEvent
  16.times do |plane|
    events << CrystalClick::ObjectSharedPathSubstreamEvent.new(
      ".QBit(Int8, 16, 8)%2E#{plane + 1}",
      24_u64 + plane.to_u64,
    )
  end
  # Compact String callbacks for the unselected implicit SharedVariant arm
  # still occur and own empty ranges at the end of the exact Data slice.
  events << CrystalClick::ObjectSharedPathSubstreamEvent.new(".SharedVariant.size", 40_u64)
  events << CrystalClick::ObjectSharedPathSubstreamEvent.new(".SharedVariant", 40_u64)
  events
end

describe "W199 direct Dynamic QBit composition" do
  it "admits a QBit as an owned scalar Dynamic actual while keeping the exact descriptor and bits" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    qbit_type = CrystalClick::BinaryDataType.qbit(w199_qbit_type)
    qbit = CrystalClick::BinaryValue.qbit(
      qbit_type,
      CrystalClick::QBitValue.new(w199_qbit_type, w199_qbit_raw_row),
    )
    candidate = begin
      CrystalClick::BinaryValue.dynamic(dynamic, qbit)
    rescue ex : ArgumentError
      nil
    end

    candidate.should_not be_nil
    value = candidate.not_nil!
    value.type.should eq(dynamic)
    value.child_at(0).type.should eq(qbit_type)
    value.child_at(0).qbit_value.should eq(CrystalClick::QBitValue.new(w199_qbit_type, w199_qbit_raw_row))
    CrystalClick::BinaryValueCodec.encode(value).should eq(w199_dynamic_qbit_envelope)
    decoded = CrystalClick::BinaryValueCodec.decode(w199_dynamic_qbit_envelope)
    decoded.type.should eq(dynamic)
    decoded.child_at(0).type.should eq(qbit_type)
    decoded.child_at(0).qbit_value.should eq(CrystalClick::QBitValue.new(w199_qbit_type, w199_qbit_raw_row))
    CrystalClick::BinaryValueCodec.encode(decoded).should eq(w199_dynamic_qbit_envelope)
  end

  it "decodes a literal owned Dynamic QBit envelope without relying on the writer constructor" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    candidate = begin
      CrystalClick::BinaryValueCodec.decode(w199_dynamic_qbit_envelope)
    rescue ex : ArgumentError | CrystalClick::CorruptPartError | CrystalClick::UnsupportedFormatError
      nil
    end

    candidate.should_not be_nil
    value = candidate.not_nil!
    value.type.should eq(dynamic)
    value.child_at(0).type.should eq(CrystalClick::BinaryDataType.qbit(w199_qbit_type))
    value.child_at(0).qbit_value.should eq(CrystalClick::QBitValue.new(w199_qbit_type, w199_qbit_raw_row))
  end

  it "plans a direct QBit actual arm in the normalized Dynamic bulk lanes" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    qbit = CrystalClick::BinaryDataType.qbit(w199_qbit_type)
    structure = CrystalClick::DynamicStructure.new([qbit] of CrystalClick::BinaryDataType)
    candidate = begin
      CrystalClick::BinaryDynamicBulkPlan.new(dynamic, {"root" => structure})
    rescue ex : CrystalClick::UnsupportedFormatError
      nil
    end

    candidate.should_not be_nil
    plan = candidate.not_nil!
    plan.structure_for("root").type_at(0).should eq(qbit)
    plan.data_roles.should contain("root.arm.0.qbit_plane.0")
    plan.data_roles.should contain("root.arm.0.qbit_plane.15")
    sites = plan.qbit_sites
    sites.size.should eq(1)
    sites[0].path.should eq("root.arm.0")
    sites[0].plane_roles.size.should eq(16)
    sites[0].plane_roles.clear
    sites.clear
    plan.qbit_sites[0].plane_roles.size.should eq(16)
    plan.qbit_sites[0].plane_roles[0].should eq("root.arm.0.qbit_plane.0")
  end

  it "decodes independently supplied direct-QBit Dynamic bulk lanes" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    candidate = begin
      CrystalClick::BinaryDynamicBulkCodec.decode(
        dynamic,
        w199_dynamic_qbit_bulk_streams,
        [1_u64],
      )
    rescue ex : ArgumentError | CrystalClick::CorruptPartError | CrystalClick::UnsupportedFormatError
      nil
    end

    candidate.should_not be_nil
    decoded = candidate.not_nil!
    decoded.size.should eq(1)
    decoded[0].size.should eq(1)
    value = decoded[0][0]
    value.type.should eq(dynamic)
    value.is_null?.should be_false
    value.child_at(0).type.should eq(CrystalClick::BinaryDataType.qbit(w199_qbit_type))
    value.child_at(0).qbit_value.should eq(
      CrystalClick::QBitValue.new(w199_qbit_type, Bytes.new(16, 0_u8)),
    )
  end

  it "preflights QBit materialization across distinct actual sites as one aggregate" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 2)
    int8 = CrystalClick::QBitType.new("Int8", 8192_u64)
    float32 = CrystalClick::QBitType.new("Float32", 8192_u64)
    int8_type = CrystalClick::BinaryDataType.qbit(int8)
    float32_type = CrystalClick::BinaryDataType.qbit(float32)
    structures = {
      "root" => CrystalClick::DynamicStructure.new([int8_type, float32_type] of CrystalClick::BinaryDataType),
    }
    first = CrystalClick::BinaryValue.dynamic(
      dynamic,
      CrystalClick::BinaryValue.qbit(int8_type, CrystalClick::QBitValue.new(int8, Bytes.new(int8.raw_row_bytes, 0_u8))),
    )
    second = CrystalClick::BinaryValue.dynamic(
      dynamic,
      CrystalClick::BinaryValue.qbit(float32_type, CrystalClick::QBitValue.new(float32, Bytes.new(float32.raw_row_bytes, 0_u8))),
    )
    streams = CrystalClick::BinaryDynamicBulkCodec.encode(
      dynamic,
      structures,
      [[first, second] of CrystalClick::BinaryValue],
    )

    decoded = CrystalClick::BinaryDynamicBulkCodec.decode(dynamic, streams, [2_u64])
    decoded.size.should eq(1)
    decoded[0].size.should eq(2)
    decoded[0][0].child_at(0).type.should eq(int8_type)
    decoded[0][0].child_at(0).qbit_value.raw_bytesize.should eq(int8.raw_row_bytes)
    decoded[0][0].child_at(0).qbit_value.raw_byte_at(0).should eq(0_u8)
    decoded[0][1].child_at(0).type.should eq(float32_type)
    decoded[0][1].child_at(0).qbit_value.raw_bytesize.should eq(float32.raw_row_bytes)
    decoded[0][1].child_at(0).qbit_value.raw_byte_at(float32.raw_row_bytes - 1).should eq(0_u8)

    first_charge = CrystalClick::QBitColumnType.new(int8).materialization_charge(1_u64)
    second_charge = CrystalClick::QBitColumnType.new(float32).materialization_charge(1_u64)
    single_site_limit = first_charge > second_charge ? first_charge : second_charge
    first_charge.should be <= single_site_limit
    second_charge.should be <= single_site_limit
    (first_charge + second_charge).should be > single_site_limit

    limits = CrystalClick::BinaryCodecLimits.new(
      max_depth: 64,
      max_nodes: 100_000,
      max_elements: 100_000,
      max_bytes: single_site_limit.to_i64,
    )
    error = expect_raises(CrystalClick::CorruptPartError, "Dynamic QBit aggregate materialization exceeds configured byte limit") do
      CrystalClick::BinaryDynamicBulkCodec.decode(dynamic, streams, [2_u64], limits: limits)
    end
    error.message.not_nil!.should contain("aggregate materialization")
  end

  it "counts flattened QBit children in a selected middle Array(Dynamic) mark" do
    qbit = CrystalClick::QBitType.new("Int8", 8192_u64)
    qbit_type = CrystalClick::BinaryDataType.qbit(qbit)
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    array_type = CrystalClick::BinaryDataType.array(dynamic)
    structures = {
      "root.elements" => CrystalClick::DynamicStructure.new([qbit_type] of CrystalClick::BinaryDataType),
    }
    dynamic_qbit = ->(raw : UInt8) do
      CrystalClick::BinaryValue.dynamic(
        dynamic,
        CrystalClick::BinaryValue.qbit(
          qbit_type,
          CrystalClick::QBitValue.new(qbit, Bytes.new(qbit.raw_row_bytes) { |index| index == 0 ? raw : 0_u8 }),
        ),
      )
    end
    empty = CrystalClick::BinaryValue.array(array_type, [] of CrystalClick::BinaryValue)
    middle = CrystalClick::BinaryValue.array(array_type, [dynamic_qbit.call(0x07_u8), dynamic_qbit.call(0x09_u8)])
    last = CrystalClick::BinaryValue.array(array_type, [dynamic_qbit.call(0x0b_u8)])
    streams = CrystalClick::BinaryDynamicBulkCodec.encode(
      array_type,
      structures,
      [[empty] of CrystalClick::BinaryValue, [middle] of CrystalClick::BinaryValue, [last] of CrystalClick::BinaryValue],
    )
    row_counts = [1_u64, 1_u64, 1_u64]

    selected = CrystalClick::BinaryDynamicBulkCodec.decode(
      array_type,
      streams,
      row_counts,
      first_mark: 1,
      mark_count: 1,
    )
    selected[0][0].element_count.should eq(2)
    selected[0][0].element_at(0).child_at(0).qbit_value.raw_bytesize.should eq(qbit.raw_row_bytes)
    selected[0][0].element_at(0).child_at(0).qbit_value.raw_byte_at(0).should eq(0x07_u8)
    selected[0][0].element_at(1).child_at(0).qbit_value.raw_bytesize.should eq(qbit.raw_row_bytes)
    selected[0][0].element_at(1).child_at(0).qbit_value.raw_byte_at(0).should eq(0x09_u8)

    single_site_row_limit = CrystalClick::QBitColumnType.new(qbit).materialization_charge(1_u64)
    single_site_row_limit.should be < CrystalClick::QBitColumnType.new(qbit).materialization_charge(2_u64)
    tight_limits = CrystalClick::BinaryCodecLimits.new(
      max_depth: 64,
      max_nodes: 100_000,
      max_elements: 100_000,
      max_bytes: single_site_row_limit.to_i64,
    )
    tight_error = expect_raises(CrystalClick::CorruptPartError, "Dynamic QBit aggregate materialization exceeds configured byte limit") do
      CrystalClick::BinaryDynamicBulkCodec.decode(
        array_type,
        streams,
        row_counts,
        first_mark: 1,
        mark_count: 1,
        limits: tight_limits,
      )
    end
    tight_error.message.not_nil!.should contain("aggregate materialization")

    one_child = CrystalClick::BinaryDynamicBulkCodec.decode(
      array_type,
      streams,
      row_counts,
      first_mark: 2,
      mark_count: 1,
      limits: tight_limits,
    )
    one_child[0][0].element_count.should eq(1)
    one_child[0][0].element_at(0).child_at(0).qbit_value.raw_bytesize.should eq(qbit.raw_row_bytes)
    one_child[0][0].element_at(0).child_at(0).qbit_value.raw_byte_at(0).should eq(0x0b_u8)
  end

  it "keeps a no-QBit Dynamic bulk plan usable at a strict measured budget" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    structures = {"root" => CrystalClick::DynamicStructure.new([uint8] of CrystalClick::BinaryDataType)}
    rows = [[CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.fixed(uint8, Bytes[0x2a_u8]))] of CrystalClick::BinaryValue]

    generous = CrystalClick::BinaryCodecLimits.default
    measured = CrystalClick::BinaryCodecBudget.new(generous, true)
    CrystalClick::BinaryDynamicBulkCodec.encode_with_budget(dynamic, structures, rows, measured)
    measured_counts = {measured.node_count, measured.element_count, measured.wire_byte_count}
    measured_counts[0].should be > 0_i64
    measured_counts[1].should be > 0_i64

    strict = CrystalClick::BinaryCodecLimits.new(
      max_depth: generous.max_depth,
      max_nodes: measured.node_count,
      max_elements: measured.element_count,
      max_bytes: measured.wire_byte_count,
    )
    exact = CrystalClick::BinaryCodecBudget.new(strict, true)
    CrystalClick::BinaryDynamicBulkCodec.encode_with_budget(dynamic, structures, rows, exact)
    {exact.node_count, exact.element_count, exact.wire_byte_count}.should eq(measured_counts)
  end

  it "writes independent padded Int8 and exact Float32 plane literals" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)

    padded = CrystalClick::QBitType.new("Int8", 9_u64)
    padded_type = CrystalClick::BinaryDataType.qbit(padded)
    padded_raw = Bytes[0x80_u8, 0x40_u8, 0x20_u8, 0x10_u8, 0x08_u8, 0x04_u8, 0x02_u8, 0x01_u8, 0x80_u8]
    padded_value = CrystalClick::BinaryValue.dynamic(
      dynamic,
      CrystalClick::BinaryValue.qbit(padded_type, CrystalClick::QBitValue.new(padded, padded_raw)),
    )
    padded_streams = CrystalClick::BinaryDynamicBulkCodec.encode(
      dynamic,
      {"root" => CrystalClick::DynamicStructure.new([padded_type] of CrystalClick::BinaryDataType)},
      [[padded_value] of CrystalClick::BinaryValue],
    )
    padded_planes = [
      Bytes[0x01_u8, 0x01_u8],
      Bytes[0x00_u8, 0x02_u8],
      Bytes[0x00_u8, 0x04_u8],
      Bytes[0x00_u8, 0x08_u8],
      Bytes[0x00_u8, 0x10_u8],
      Bytes[0x00_u8, 0x20_u8],
      Bytes[0x00_u8, 0x40_u8],
      Bytes[0x00_u8, 0x80_u8],
    ]
    padded_planes.each_with_index do |expected, plane|
      stream = padded_streams.data.stream("root.arm.0.qbit_plane.#{plane}")
      stream.bytes.should eq(expected)
      stream.offsets.should eq([0_u64, 2_u64])
    end
    padded_decoded = CrystalClick::BinaryDynamicBulkCodec.decode(dynamic, padded_streams, [1_u64])
    padded_decoded[0][0].child_at(0).type.should eq(padded_type)
    padded_decoded[0][0].child_at(0).qbit_value.raw_bytes.should eq(padded_raw)

    float32 = CrystalClick::QBitType.new("Float32", 1_u64)
    float32_type = CrystalClick::BinaryDataType.qbit(float32)
    negative_zero = Bytes[0x00_u8, 0x00_u8, 0x00_u8, 0x80_u8]
    nan_payload = Bytes[0x01_u8, 0x00_u8, 0xc0_u8, 0x7f_u8]
    float_rows = [negative_zero, nan_payload].map do |raw|
      CrystalClick::BinaryValue.dynamic(
        dynamic,
        CrystalClick::BinaryValue.qbit(float32_type, CrystalClick::QBitValue.new(float32, raw)),
      )
    end
    float_streams = CrystalClick::BinaryDynamicBulkCodec.encode(
      dynamic,
      {"root" => CrystalClick::DynamicStructure.new([float32_type] of CrystalClick::BinaryDataType)},
      [float_rows],
    )
    expected_float_planes = [Bytes[0x01_u8, 0x00_u8]]
    9.times { expected_float_planes << Bytes[0x00_u8, 0x01_u8] }
    21.times { expected_float_planes << Bytes[0x00_u8, 0x00_u8] }
    expected_float_planes << Bytes[0x00_u8, 0x01_u8]
    expected_float_planes.size.should eq(32)
    expected_float_planes.each_with_index do |expected, plane|
      stream = float_streams.data.stream("root.arm.0.qbit_plane.#{plane}")
      stream.bytes.should eq(expected)
      stream.offsets.should eq([0_u64, 2_u64])
    end
    float_decoded = CrystalClick::BinaryDynamicBulkCodec.decode(dynamic, float_streams, [2_u64])
    float_decoded[0][0].child_at(0).qbit_value.raw_bytes.should eq(negative_zero)
    float_decoded[0][1].child_at(0).qbit_value.raw_bytes.should eq(nan_payload)
  end

  it "rejects misaligned and divergent QBit plane spans even for a zero selection" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    qbit = CrystalClick::QBitType.new("Int8", 9_u64)
    qbit_type = CrystalClick::BinaryDataType.qbit(qbit)
    value = CrystalClick::BinaryValue.dynamic(
      dynamic,
      CrystalClick::BinaryValue.qbit(
        qbit_type,
        CrystalClick::QBitValue.new(qbit, Bytes[1_u8, 2, 3, 4, 5, 6, 7, 8, 9]),
      ),
    )
    encoded = CrystalClick::BinaryDynamicBulkCodec.encode(
      dynamic,
      {"root" => CrystalClick::DynamicStructure.new([qbit_type] of CrystalClick::BinaryDataType)},
      [[value] of CrystalClick::BinaryValue],
    )
    source_lanes = encoded.data
    first_plane = "root.arm.0.qbit_plane.0"
    second_plane = "root.arm.0.qbit_plane.1"

    misaligned_lanes = Hash(String, CrystalClick::BinaryBulkStream).new
    source_lanes.roles.each { |role| misaligned_lanes[role] = source_lanes.stream(role) }
    misaligned_lanes[first_plane] = CrystalClick::BinaryBulkStream.new(Bytes[encoded.data.stream(first_plane).byte_at(0)], [0_u64, 1_u64])
    misaligned = CrystalClick::BinaryDynamicBulkStreams.new(
      encoded.structures,
      CrystalClick::BinaryBulkStreams.new(source_lanes.mark_count, misaligned_lanes),
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDynamicBulkCodec.decode(
        dynamic,
        misaligned,
        [1_u64],
        first_mark: 0,
        mark_count: 0,
      )
    end

    divergent_lanes = Hash(String, CrystalClick::BinaryBulkStream).new
    source_lanes.roles.each { |role| divergent_lanes[role] = source_lanes.stream(role) }
    divergent_lanes[second_plane] = CrystalClick::BinaryBulkStream.new(Bytes.empty, [0_u64, 0_u64])
    divergent = CrystalClick::BinaryDynamicBulkStreams.new(
      encoded.structures,
      CrystalClick::BinaryBulkStreams.new(source_lanes.mark_count, divergent_lanes),
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDynamicBulkCodec.decode(
        dynamic,
        divergent,
        [1_u64],
        first_mark: 0,
        mark_count: 0,
      )
    end
  end
end
