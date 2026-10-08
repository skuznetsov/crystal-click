require "./spec_helper"

private def w230_owner_qbit_argument_types : Array(CrystalClick::BinaryDataType)
  qbit = CrystalClick::BinaryDataType.qbit(CrystalClick::QBitType.new("Int8", 3_u64))
  nullable_qbit = CrystalClick::BinaryDataType.nullable(qbit)
  [
    qbit,
    CrystalClick::BinaryDataType.array(qbit),
    CrystalClick::BinaryDataType.array(nullable_qbit),
  ] of CrystalClick::BinaryDataType
end

private def w230_owner_qbit_tree_wire(argument : CrystalClick::BinaryDataType) : Bytes
  case argument.tag
  when CrystalClick::BinaryDataType::TAG_QBIT
    Bytes[0x36_u8, 0x07_u8, 0x03_u8]
  when CrystalClick::BinaryDataType::TAG_ARRAY
    child = argument.child_at(0)
    if child.tag == CrystalClick::BinaryDataType::TAG_QBIT
      Bytes[0x1e_u8, 0x36_u8, 0x07_u8, 0x03_u8]
    else
      Bytes[0x1e_u8, 0x23_u8, 0x36_u8, 0x07_u8, 0x03_u8]
    end
  else
    raise "unexpected W230 QBit Count witness"
  end
end

private def w230_owner_count_wire(argument : CrystalClick::BinaryDataType) : Bytes
  io = IO::Memory.new
  # AggregateFunction(count), version 0, function name "count", no function
  # parameters, one descriptor argument, then an independently literal QBit
  # argument tree.
  io.write(Bytes[0x25_u8, 0x00_u8, 0x05_u8, 0x63_u8, 0x6f_u8, 0x75_u8, 0x6e_u8, 0x74_u8, 0x00_u8, 0x01_u8])
  io.write(w230_owner_qbit_tree_wire(argument))
  io.to_slice
end

private def w230_owner_dynamic_structure_wire(actual_type : CrystalClick::BinaryDataType) : Bytes
  descriptor = w230_owner_qbit_tree_wire(actual_type)
  io = IO::Memory.new
  # Dynamic V3 full structure: little-endian version 4, one ordinary arm,
  # literal Array(QBit(...)) descriptor, no statistics.
  io.write(Bytes[0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x01_u8])
  io.write(descriptor)
  io.write(Bytes[0x00_u8])
  io.to_slice
end

describe "W230 recursive QBit downstream owner guards" do
  it "keeps QBit out of every Count argument-admission entry point" do
    w230_owner_qbit_argument_types.each do |argument|
      CrystalClick::BinaryAggregateCountArgumentPolicy.admitted?(argument).should be_false

      expect_raises(ArgumentError) do
        CrystalClick::BinaryAggregateCountType.new(argument)
      end
      expect_raises(ArgumentError) do
        CrystalClick::BinaryAggregateFunctionType.new("count", argument)
      end
    end
  end

  it "keeps the Count DataType factory, forged descriptor reader, and physical name parser closed" do
    w230_owner_qbit_argument_types.each do |argument|
      expect_raises(ArgumentError) do
        CrystalClick::BinaryDataType.aggregate_count(argument)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryDataTypeCodec.decode(w230_owner_count_wire(argument))
      end
      CrystalClick::WideAggregateCountStoragePlan.for_type_name(
        "AggregateFunction(count, #{argument.name})"
      ).should be_nil
    end

    # The generic AF constructor is also a Count entry point and must not
    # bypass the dedicated nominal constructor's QBit policy.
    qbit = w230_owner_qbit_argument_types.first
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.aggregate_function("count", qbit)
    end
  end

  it "rejects wrapped QBit actuals in complete Dynamic bulk write and read paths" do
    qbit = CrystalClick::BinaryDataType.qbit(CrystalClick::QBitType.new("Int8", 3_u64))
    wrapped_actuals = [
      CrystalClick::BinaryDataType.array(qbit),
      CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.nullable(qbit)),
    ] of CrystalClick::BinaryDataType
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)

    wrapped_actuals.each do |actual_type|
      structure = CrystalClick::DynamicStructure.new([actual_type] of CrystalClick::BinaryDataType)
      structures = {"root" => structure}

      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryDynamicBulkPlan.new(dynamic, structures)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryDynamicBulkCodec.encode(
          dynamic,
          structures,
          [] of Array(CrystalClick::BinaryValue),
        )
      end

      forged = CrystalClick::BinaryDynamicBulkStreams.new(
        CrystalClick::BinaryDynamicStructureStreams.new({
          "root" => w230_owner_dynamic_structure_wire(actual_type),
        }),
        CrystalClick::BinaryBulkStreams.new(
          0,
          {} of String => CrystalClick::BinaryBulkStream,
        ),
      )
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryDynamicBulkCodec.decode(dynamic, forged, [] of UInt64)
      end
    end
  end

  it "retains the direct QBit Dynamic actual positive control" do
    qbit_type = CrystalClick::QBitType.new("Int8", 3_u64)
    qbit = CrystalClick::BinaryDataType.qbit(qbit_type)
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    structure = CrystalClick::DynamicStructure.new([qbit] of CrystalClick::BinaryDataType)
    value = CrystalClick::BinaryValue.dynamic(
      dynamic,
      CrystalClick::BinaryValue.qbit(
        qbit,
        CrystalClick::QBitValue.new(qbit_type, Bytes[0x81_u8, 0x02_u8, 0xff_u8]),
      ),
    )

    plan = CrystalClick::BinaryDynamicBulkPlan.new(dynamic, {"root" => structure})
    plan.structure_for("root").type_at(0).should eq(qbit)
    streams = CrystalClick::BinaryDynamicBulkCodec.encode(
      dynamic,
      {"root" => structure},
      [[value] of CrystalClick::BinaryValue],
    )
    decoded = CrystalClick::BinaryDynamicBulkCodec.decode(dynamic, streams, [1_u64])
    decoded[0][0].child_at(0).type.should eq(qbit)
    decoded[0][0].child_at(0).qbit_value.raw_bytes.should eq(Bytes[0x81_u8, 0x02_u8, 0xff_u8])
  end

  it "keeps recursive QBit outside typed JSON, Object, and shared Dynamic-child boundaries" do
    qbit = CrystalClick::BinaryDataType.qbit(CrystalClick::QBitType.new("Int8", 3_u64))
    array_qbit = CrystalClick::BinaryDataType.array(qbit)

    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.json(typed_paths: {"items" => array_qbit})
    end
    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentSchema.new({"items" => array_qbit})
    end

    array_value = CrystalClick::BinaryValue.array(array_qbit, [] of CrystalClick::BinaryValue)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode_dynamic_bulk_child(
        array_value,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
        1,
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.decode_dynamic_bulk_child(
        CrystalClick::BinaryValueCodec.encode(array_value),
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
        1,
      )
    end
  end
end
