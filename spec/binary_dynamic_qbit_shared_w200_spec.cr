require "./spec_helper"

private def w200_shared_copy_qbit_type : CrystalClick::QBitType
  CrystalClick::QBitType.new("Int8", 16_u64, 8_u64)
end

private def w200_shared_copy_qbit_raw : Bytes
  # Distinct stride groups and bit planes are visible in both directions.
  Bytes[
    0x80_u8, 0x40_u8, 0x20_u8, 0x10_u8, 0x08_u8, 0x04_u8, 0x02_u8, 0x01_u8,
    0x01_u8, 0x02_u8, 0x04_u8, 0x08_u8, 0x10_u8, 0x20_u8, 0x40_u8, 0x80_u8,
  ]
end

private def w200_shared_copy_structure : Array(CrystalClick::ObjectSharedChunkStructure)
  [
    CrystalClick::ObjectSharedChunkStructure.new(
      1_u64,
      ["q"] of String,
      {0_u64, 0_u64},
      {0_u64, 0_u64},
      {0_u64, 0_u64},
    ),
  ] of CrystalClick::ObjectSharedChunkStructure
end

private def w200_shared_copy_row(value : CrystalClick::BinaryValue) : Array(CrystalClick::ObjectSharedMapRow)
  [
    CrystalClick::ObjectSharedMapRow.new([
      CrystalClick::ObjectSharedMapEntry.new("q".to_slice, value),
    ] of CrystalClick::ObjectSharedMapEntry),
  ] of CrystalClick::ObjectSharedMapRow
end

private def w200_shared_copy_limits(max_bytes : Int) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: 64,
    max_nodes: 4_096,
    max_elements: 100_000,
    max_bytes: max_bytes,
  )
end

private def w200_shared_copy_value_envelope : Bytes
  # One exact descriptor/value child, without a Dynamic wrapper:
  # QBitWithStride(Int8, dimension=16, stride=8), then raw little-endian bits.
  Bytes[
    0x37_u8, 0x07_u8, 0x10_u8, 0x08_u8, 0x10_u8,
    0x80_u8, 0x40_u8, 0x20_u8, 0x10_u8, 0x08_u8, 0x04_u8, 0x02_u8, 0x01_u8,
    0x01_u8, 0x02_u8, 0x04_u8, 0x08_u8, 0x10_u8, 0x20_u8, 0x40_u8, 0x80_u8,
  ]
end

private def w200_shared_copy_sizes : Bytes
  Bytes[0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8]
end

private def w200_shared_copy_indexes : Bytes
  Bytes[0x00_u8]
end

private def w200_shared_copy_values : Bytes
  # VarUInt envelope length (21), followed by the independently authored child.
  Bytes[
    0x15_u8,
    0x37_u8, 0x07_u8, 0x10_u8, 0x08_u8, 0x10_u8,
    0x80_u8, 0x40_u8, 0x20_u8, 0x10_u8, 0x08_u8, 0x04_u8, 0x02_u8, 0x01_u8,
    0x01_u8, 0x02_u8, 0x04_u8, 0x08_u8, 0x10_u8, 0x20_u8, 0x40_u8, 0x80_u8,
  ]
end

describe "W200 direct QBit Object shared Copy child" do
  it "round-trips a literal scalar child and preserves exact type, stride, and raw bytes" do
    qbit_type = w200_shared_copy_qbit_type
    qbit_data_type = CrystalClick::BinaryDataType.qbit(qbit_type)
    qbit_value = CrystalClick::QBitValue.new(qbit_type, w200_shared_copy_qbit_raw)
    value = CrystalClick::BinaryValue.qbit(qbit_data_type, qbit_value)
    structures = w200_shared_copy_structure
    limits = w200_shared_copy_limits(31)

    child_budget = CrystalClick::BinaryCodecBudget.new(limits, true)
    CrystalClick::BinaryValueCodec.encode_dynamic_bulk_child(value, child_budget, 1).should eq(
      w200_shared_copy_value_envelope,
    )

    encode_budget = CrystalClick::BinaryCodecBudget.new(limits, true)
    encoded = CrystalClick::ObjectSharedCopyCodec.encode_with_budget(
      w200_shared_copy_row(value),
      structures,
      encode_budget,
    )
    encoded.sizes.should eq(w200_shared_copy_sizes)
    encoded.indexes.should eq(w200_shared_copy_indexes)
    encoded.values.should eq(w200_shared_copy_values)
    encode_budget.wire_byte_count.should eq(31_i64)

    decode_budget = CrystalClick::BinaryCodecBudget.new(limits)
    decoded = CrystalClick::ObjectSharedCopyCodec.decode_with_budget(
      w200_shared_copy_sizes,
      w200_shared_copy_indexes,
      w200_shared_copy_values,
      structures,
      decode_budget,
    )
    decode_budget.wire_byte_count.should eq(31_i64)
    decoded.size.should eq(1)
    decoded[0].entry_count.should eq(1)
    decoded_value = decoded[0].entry_at(0).value
    decoded_value.type.should eq(qbit_data_type)
    decoded_value.type.name.should eq("QBit(Int8, 16, 8)")
    decoded_value.type.qbit_type.should eq(qbit_type)
    decoded_value.qbit_value.type.should eq(qbit_type)
    decoded_value.qbit_value.type.stride.should eq(8_u64)
    decoded_value.qbit_value.raw_bytes.should eq(w200_shared_copy_qbit_raw)

    reencoded = CrystalClick::ObjectSharedCopyCodec.encode(decoded, structures, limits)
    reencoded.sizes.should eq(w200_shared_copy_sizes)
    reencoded.indexes.should eq(w200_shared_copy_indexes)
    reencoded.values.should eq(w200_shared_copy_values)

    direct_type, direct_value = CrystalClick::BinaryValueCodec.decode_dynamic_bulk_child(
      w200_shared_copy_value_envelope,
      CrystalClick::BinaryCodecBudget.new(limits),
      1,
    )
    direct_type.should eq(qbit_data_type)
    direct_value.not_nil!.qbit_value.raw_bytes.should eq(w200_shared_copy_qbit_raw)

    bad_dimension = Bytes.new(w200_shared_copy_value_envelope.size) do |index|
      index == 4 ? 0x0f_u8 : w200_shared_copy_value_envelope[index]
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_dynamic_bulk_child(
        bad_dimension,
        CrystalClick::BinaryCodecBudget.new(limits),
        1,
      )
    end

    truncated = w200_shared_copy_value_envelope[0, w200_shared_copy_value_envelope.size - 1]
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_dynamic_bulk_child(
        truncated,
        CrystalClick::BinaryCodecBudget.new(limits),
        1,
      )
    end
    trailing_byte = Bytes.new(w200_shared_copy_value_envelope.size + 1) do |index|
      index == w200_shared_copy_value_envelope.size ? 0xee_u8 : w200_shared_copy_value_envelope[index]
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_dynamic_bulk_child(
        trailing_byte,
        CrystalClick::BinaryCodecBudget.new(limits),
        1,
      )
    end
  end

  it "charges all Copy lanes against one exact aggregate wire-byte budget" do
    qbit_type = w200_shared_copy_qbit_type
    qbit_value = CrystalClick::BinaryValue.qbit(
      CrystalClick::BinaryDataType.qbit(qbit_type),
      CrystalClick::QBitValue.new(qbit_type, w200_shared_copy_qbit_raw),
    )
    structures = w200_shared_copy_structure
    rows = w200_shared_copy_row(qbit_value)

    # sizes (8) + dictionary index (1) + framed QBit child (22) = 31 bytes.
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectSharedCopyCodec.encode(
        rows,
        structures,
        w200_shared_copy_limits(30),
      )
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedCopyCodec.decode(
        w200_shared_copy_sizes,
        w200_shared_copy_indexes,
        w200_shared_copy_values,
        structures,
        w200_shared_copy_limits(30),
      )
    end
  end

  it "keeps wrong nominal payloads and Array(QBit) outside Dynamic child admission" do
    qbit_type = w200_shared_copy_qbit_type
    qbit_value = CrystalClick::QBitValue.new(qbit_type, w200_shared_copy_qbit_raw)
    wrong_type = CrystalClick::QBitType.new("Float32", 16_u64, 8_u64)

    expect_raises(ArgumentError) do
      CrystalClick::BinaryValue.qbit(CrystalClick::BinaryDataType.qbit(wrong_type), qbit_value)
    end
    context = CrystalClick::BinaryCodecContext.new(CrystalClick::BinaryCodecLimits.default, nil, true)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryQBitValueCodec.write(qbit_value, wrong_type, context)
    end

    qbit_data_type = CrystalClick::BinaryDataType.qbit(qbit_type)
    nullable_qbit_type = CrystalClick::BinaryDataType.nullable(qbit_data_type)
    nullable_qbit_value = CrystalClick::BinaryValue.nullable(
      nullable_qbit_type,
      CrystalClick::BinaryValue.qbit(qbit_data_type, qbit_value),
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode_dynamic_bulk_child(
        nullable_qbit_value,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
        1,
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.decode_dynamic_bulk_child(
        CrystalClick::BinaryValueCodec.encode(nullable_qbit_value),
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
        1,
      )
    end

    array_qbit_type = CrystalClick::BinaryDataType.array(qbit_data_type)
    array_qbit_type.name.should eq("Array(QBit(Int8, 16, 8))")
    array_qbit_value = CrystalClick::BinaryValue.array(
      array_qbit_type,
      [CrystalClick::BinaryValue.qbit(qbit_data_type, qbit_value)] of CrystalClick::BinaryValue,
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode_dynamic_bulk_child(
        array_qbit_value,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
        1,
      )
    end

    # Also test the retained wire-side guard independently of the public
    # constructor, so a forged Copy child cannot smuggle in Array(QBit).
    array_qbit_child = Bytes[
      0x1e_u8, 0x37_u8, 0x07_u8, 0x10_u8, 0x08_u8, 0x01_u8, 0x10_u8,
      0x80_u8, 0x40_u8, 0x20_u8, 0x10_u8, 0x08_u8, 0x04_u8, 0x02_u8, 0x01_u8,
      0x01_u8, 0x02_u8, 0x04_u8, 0x08_u8, 0x10_u8, 0x20_u8, 0x40_u8, 0x80_u8,
    ]
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.decode_dynamic_bulk_child(
        array_qbit_child,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
        1,
      )
    end
  end
end
