require "./spec_helper"

private def w179_qbit_scalar(dimension : UInt8, raw : Bytes) : Bytes
  scalar = IO::Memory.new(raw.size + 1)
  scalar.write_byte(dimension)
  scalar.write(raw)
  scalar.to_slice
end

private def w179_varuint(value : UInt64) : Bytes
  output = IO::Memory.new
  remaining = value
  loop do
    byte = (remaining & 0x7f_u64).to_u8
    remaining >>= 7
    output.write_byte(byte | (remaining == 0_u64 ? 0_u8 : 0x80_u8))
    break if remaining == 0_u64
  end
  output.to_slice
end

describe "QBit binary descriptor and scalar kernel" do
  carriers = [
    {"Int8", 0x07_u8, 1},
    {"BFloat16", 0x31_u8, 2},
    {"Float32", 0x0d_u8, 4},
    {"Float64", 0x0e_u8, 8},
  ]
  shapes = [
    {3_u64, nil.as(UInt64?)},
    {9_u64, nil.as(UInt64?)},
    {16_u64, 8_u64.as(UInt64?)},
  ]

  carriers.each do |element, element_tag, width|
    shapes.each do |dimension, stride|
      shape_name = stride ? "#{dimension}, #{stride}" : dimension.to_s
      it "round-trips #{element} QBit(#{shape_name}) descriptors, scalars and envelopes" do
        qbit_type = CrystalClick::QBitType.new(element, dimension, stride)
        descriptor = CrystalClick::BinaryDataType.qbit(qbit_type)
        value_type = CrystalClick::BinaryValue.qbit(
          CrystalClick::QBitValue.new(qbit_type, Bytes.new(qbit_type.raw_row_bytes) do |index|
            ((index * 37 + dimension.to_i) & 0xff).to_u8
          end)
        )

        descriptor.name.should eq(qbit_type.type_name)
        descriptor.qbit_type.should eq(qbit_type)
        descriptor.contains_qbit?.should be_true
        descriptor.child_count.should eq(0)
        descriptor.children.should be_empty
        descriptor.fixed_width.should be_nil
        value_type.type.should eq(descriptor)
        value_type.qbit_value.type.should eq(qbit_type)
        value_type.byte_size.should eq(dimension.to_i * width)

        expected_descriptor = if stride
                                Bytes[CrystalClick::BinaryDataType::TAG_QBIT_STRIDE, element_tag,
                                  dimension.to_u8, stride.to_u8]
                              else
                                Bytes[CrystalClick::BinaryDataType::TAG_QBIT, element_tag, dimension.to_u8]
                              end
        CrystalClick::BinaryDataTypeCodec.encode(descriptor).should eq(expected_descriptor)
        decoded_type = CrystalClick::BinaryDataTypeCodec.decode(expected_descriptor)
        decoded_type.should eq(descriptor)
        decoded_type.hash.should eq(descriptor.hash)

        raw = value_type.qbit_value.raw_bytes
        expected_scalar = Bytes.new(raw.size + 1) do |index|
          index == 0 ? dimension.to_u8 : raw[index - 1]
        end
        scalar = CrystalClick::BinaryValueCodec.encode_value(value_type)
        scalar.should eq(expected_scalar)
        decoded_value = CrystalClick::BinaryValueCodec.decode_value(descriptor, expected_scalar)
        decoded_value.should eq(value_type)
        decoded_value.qbit_value.raw_bytes.should eq(raw)

        envelope = IO::Memory.new
        envelope.write(expected_descriptor)
        envelope.write(expected_scalar)
        CrystalClick::BinaryValueCodec.encode(value_type).should eq(envelope.to_slice)
        CrystalClick::BinaryValueCodec.decode(envelope.to_slice).should eq(value_type)
      end
    end
  end

  it "preserves signed zero and distinct NaN payload bits for floating carriers" do
    bf16_type = CrystalClick::QBitType.new("BFloat16", 3_u64)
    bf16_raw = Bytes[0x00_u8, 0x80, 0xc1, 0x7f, 0xc2, 0x7f]
    bf16_value = CrystalClick::BinaryValue.qbit(CrystalClick::QBitValue.new(bf16_type, bf16_raw))
    CrystalClick::BinaryValueCodec.decode_value(
      CrystalClick::BinaryDataType.qbit(bf16_type),
      w179_qbit_scalar(0x03_u8, bf16_raw)
    ).qbit_value.raw_bytes.should eq(bf16_raw)
    bf16_value.qbit_value.raw_bytes.should eq(bf16_raw)

    f32_type = CrystalClick::QBitType.new("Float32", 3_u64)
    f32_raw = Bytes[0x00_u8, 0x00, 0x00, 0x80, 0x01, 0x00, 0xc0, 0x7f, 0x02, 0x00, 0xc0, 0x7f]
    f32_value = CrystalClick::BinaryValue.qbit(CrystalClick::QBitValue.new(f32_type, f32_raw))
    CrystalClick::BinaryValueCodec.decode_value(
      CrystalClick::BinaryDataType.qbit(f32_type),
      w179_qbit_scalar(0x03_u8, f32_raw)
    ).qbit_value.raw_bytes.should eq(f32_raw)
    f32_value.qbit_value.raw_bytes.should eq(f32_raw)

    f64_type = CrystalClick::QBitType.new("Float64", 2_u64)
    f64_raw = Bytes[
      0x00_u8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80,
      0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf8, 0x7f,
    ]
    f64_value = CrystalClick::BinaryValue.qbit(CrystalClick::QBitValue.new(f64_type, f64_raw))
    CrystalClick::BinaryValueCodec.decode_value(
      CrystalClick::BinaryDataType.qbit(f64_type),
      w179_qbit_scalar(0x02_u8, f64_raw)
    ).qbit_value.raw_bytes.should eq(f64_raw)
    f64_value.qbit_value.raw_bytes.should eq(f64_raw)
  end

  it "admits the minimum dimension and rejects locally oversized raw-row materialization" do
    minimum = CrystalClick::QBitType.new("Int8", 1_u64)
    descriptor = CrystalClick::BinaryDataType.qbit(minimum)
    descriptor.name.should eq("QBit(Int8, 1)")
    CrystalClick::BinaryDataTypeCodec.decode(CrystalClick::BinaryDataTypeCodec.encode(descriptor)).should eq(descriptor)
    CrystalClick::BinaryValueCodec.decode_value(descriptor, Bytes[0x01_u8, 0xff_u8]).qbit_value.raw_bytes.should eq(Bytes[0xff_u8])

    oversized = IO::Memory.new
    oversized.write(Bytes[CrystalClick::BinaryDataType::TAG_QBIT, 0x07_u8])
    oversized.write(w179_varuint(67_108_865_u64))
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.decode(oversized.to_slice)
    end
  end

  it "retains canonical stride identity, equality, hash and owned source bytes" do
    explicit_default = CrystalClick::QBitType.new("Float32", 16_u64, 16_u64)
    omitted_default = CrystalClick::QBitType.new("Float32", 16_u64)
    explicit_default.should eq(omitted_default)
    explicit_default.type_name.should eq("QBit(Float32, 16)")

    first = CrystalClick::BinaryDataType.qbit(explicit_default)
    second = CrystalClick::BinaryDataType.qbit(omitted_default)
    first.should eq(second)
    first.hash.should eq(second.hash)
    CrystalClick::BinaryDataTypeCodec.encode(first)[0].should eq(CrystalClick::BinaryDataType::TAG_QBIT)

    raw = Bytes[1_u8, 2_u8, 3_u8]
    source_type = CrystalClick::QBitType.new("Int8", 3_u64)
    value = CrystalClick::BinaryValue.qbit(CrystalClick::QBitValue.new(source_type, raw))
    raw[0] = 99_u8
    exposed = value.qbit_value.raw_bytes
    exposed[1] = 88_u8
    value.byte_at(0).should eq(1_u8)
    value.qbit_value.raw_bytes.should eq(Bytes[1_u8, 2_u8, 3_u8])

    distinct_dimension = CrystalClick::BinaryDataType.qbit(CrystalClick::QBitType.new("Float32", 32_u64, 8_u64))
    distinct_stride = CrystalClick::BinaryDataType.qbit(CrystalClick::QBitType.new("Float32", 16_u64, 8_u64))
    distinct_dimension.should_not eq(distinct_stride)
  end

  it "rejects malformed, unsupported, redundant and mismatched wire forms" do
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x36_u8, 0x07, 0x83, 0x00])
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x36_u8, 0x01, 0x03])
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x36_u8])
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x36_u8, 0x07])
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x36_u8, 0x07, 0x00])
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x37_u8, 0x07, 0x10, 0x10])
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x37_u8, 0x07, 0x10, 0x07])
    end

    type = CrystalClick::BinaryDataType.qbit(CrystalClick::QBitType.new("Int8", 3_u64))
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_value(type, Bytes[0x04_u8, 0xff, 0x00, 0x80])
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_value(type, Bytes[0x03_u8, 0xff, 0x00])
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_value(type, Bytes[0x03_u8, 0xff, 0x00, 0x80, 0x00])
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryValue.qbit(
        CrystalClick::QBitValue.new(CrystalClick::QBitType.new("Int8", 3_u64), Bytes[0_u8, 1, 2, 3])
      )
    end
  end

  it "charges element metadata and scalar bytes against aggregate codec budgets" do
    descriptor = CrystalClick::BinaryDataType.qbit(CrystalClick::QBitType.new("Int8", 3_u64))
    value = CrystalClick::BinaryValue.qbit(
      CrystalClick::QBitValue.new(CrystalClick::QBitType.new("Int8", 3_u64), Bytes[1_u8, 2, 3])
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.encode(descriptor,
        CrystalClick::BinaryCodecLimits.new(max_depth: 1, max_nodes: 8, max_elements: 8, max_bytes: 32))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.encode(descriptor,
        CrystalClick::BinaryCodecLimits.new(max_depth: 8, max_nodes: 1, max_elements: 8, max_bytes: 32))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.encode(descriptor,
        CrystalClick::BinaryCodecLimits.new(max_depth: 8, max_nodes: 8, max_elements: 0, max_bytes: 32))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode(value,
        CrystalClick::BinaryCodecLimits.new(max_depth: 8, max_nodes: 8, max_elements: 8, max_bytes: 5))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x36_u8, 0x07, 0x03],
        CrystalClick::BinaryCodecLimits.new(max_depth: 8, max_nodes: 8, max_elements: 8, max_bytes: 2))
    end
  end

  it "keeps static and borrowed QBit guards while admitting a direct owned Dynamic QBit" do
    qbit = CrystalClick::BinaryDataType.qbit(CrystalClick::QBitType.new("Int8", 3_u64))
    nullable = CrystalClick::BinaryDataType.nullable(qbit)
    nullable.contains_qbit?.should be_true
    nullable.child_count.should eq(1)
    nullable.child_at(0).should eq(qbit)

    recursive_array = CrystalClick::BinaryDataType.array(qbit)
    recursive_array.name.should eq("Array(QBit(Int8, 3))")
    tuple = CrystalClick::BinaryDataType.tuple([qbit] of CrystalClick::BinaryDataType)
    tuple.name.should eq("Tuple(QBit(Int8, 3))")
    map = CrystalClick::BinaryDataType.map(CrystalClick::BinaryDataType.primitive("UInt8"), qbit)
    map.name.should eq("Map(UInt8, QBit(Int8, 3))")
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.variant([qbit]) }
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.low_cardinality(qbit) }
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.simple_aggregate(CrystalClick::BinarySimpleAggregateType::Function::Sum, qbit) }

    qbit_value = CrystalClick::BinaryValue.qbit(
      CrystalClick::QBitValue.new(CrystalClick::QBitType.new("Int8", 3_u64), Bytes[1_u8, 2, 3])
    )
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    dynamic_value = CrystalClick::BinaryValue.dynamic(dynamic, qbit_value)
    dynamic_value.type.should eq(dynamic)
    dynamic_value.child_at(0).type.should eq(qbit)
    dynamic_value.child_at(0).qbit_value.should eq(qbit_value.qbit_value)

    nullable_qbit = CrystalClick::BinaryDataType.nullable(qbit)
    nullable_value = CrystalClick::BinaryValue.nullable(nullable_qbit, qbit_value)
    expect_raises(ArgumentError) do
      CrystalClick::BinaryValue.dynamic(dynamic, nullable_value)
    end

    borrowed_wire = CrystalClick::BinaryValueCodec.encode(qbit_value)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode_borrowed(
        qbit_value, CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true)
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.decode_borrowed(
        borrowed_wire, CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
      )
    end
    dynamic_wire = Bytes[0x2b_u8, 0x20, 0x36, 0x07, 0x03, 0x03, 1, 2, 3]
    decoded_dynamic = CrystalClick::BinaryValueCodec.decode(dynamic_wire)
    decoded_dynamic.type.tag.should eq(CrystalClick::BinaryDataType::TAG_DYNAMIC)
    decoded_dynamic.child_at(0).type.should eq(qbit)
    decoded_dynamic.child_at(0).qbit_value.should eq(qbit_value.qbit_value)
    CrystalClick::BinaryValueCodec.encode(decoded_dynamic).should eq(dynamic_wire)
  end
end
