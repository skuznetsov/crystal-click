require "./spec_helper"

private def w206a_json_type : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.json
end

private def w206a_json_value(type : CrystalClick::BinaryDataType) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.json(
    type,
    CrystalClick::BinaryJsonRow.new(
      type,
      [] of Tuple(String, CrystalClick::BinaryValue),
    ),
  )
end

private def w206a_empty_object_metadata : CrystalClick::ObjectDynamicStructureSet
  CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new([] of String),
    {} of String => CrystalClick::DynamicStructure,
  )
end

describe "W206 direct JSON Dynamic metadata adversaries" do
  it "rejects an unused direct JSON actual before bare Dynamic lanes are inspected" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    json = w206a_json_type
    # Keep the JSON arm unused: only the ordinary UInt8 value is selected.
    # This detects a metadata-only allowance that accidentally becomes a
    # value-ready bare Dynamic roster.
    structure = CrystalClick::DynamicStructure.new(
      [uint8, json] of CrystalClick::BinaryDataType,
    )
    ordinary = CrystalClick::BinaryValue.fixed(uint8, Bytes[0x2a_u8])
    granules = [[ordinary] of CrystalClick::BinaryValue] of Array(CrystalClick::BinaryValue)

    encode_error = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::DynamicValueCodec.encode(structure, granules)
    end
    encode_error.message.to_s.should contain("JSON")

    # Empty lane/discriminator owners make the descriptor-tree guard the only
    # valid failure point; decode must reject before arm lookup or row work.
    empty_streams = CrystalClick::DynamicValueStreams.new(
      CrystalClick::DynamicDiscriminatorStream.new(
        Bytes.empty,
        [] of CrystalClick::DynamicDiscriminatorMark,
      ),
      {} of String => CrystalClick::BinaryBulkStreams,
    )
    decode_error = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::DynamicValueCodec.decode(structure, empty_streams)
    end
    decode_error.message.to_s.should contain("JSON")
  end

  it "rejects unused root Object/Dynamic metadata while retaining the typed-Dynamic guard" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    json = w206a_json_type
    root_structure = CrystalClick::DynamicStructure.new(
      [uint8, json] of CrystalClick::BinaryDataType,
    )
    root_set = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["root"] of String),
      {"root" => root_structure},
    )

    root_error = expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentPlan.new(
        root_set,
        {} of String => CrystalClick::BinaryDataType,
      )
    end
    root_error.message.to_s.should contain("JSON")

    # Typed Object Dynamic has a distinct declaration owner and remains
    # narrower even though metadata Dynamic actuals can name direct JSON.
    typed_structure = CrystalClick::DynamicStructure.new([json] of CrystalClick::BinaryDataType)
    typed_dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    typed_error = expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentPlan.new(
        w206a_empty_object_metadata,
        {"typed" => typed_dynamic},
        {"typed" => typed_structure},
      )
    end
    typed_error.message.to_s.should contain("JSON")
  end

  it "keeps direct JSON excluded from bare child envelopes and SharedVariant" do
    json = w206a_json_type
    json_value = w206a_json_value(json)

    encode_child_error = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode_dynamic_bulk_child(
        json_value,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true),
        1,
      )
    end
    encode_child_error.message.to_s.should contain("JSON")

    # Independently authored default-JSON descriptor: tag 0x30, v0, 1024
    # max paths, 32 max types, and empty typed/SKIP/regexp rosters.
    json_descriptor = Bytes[
      0x30_u8, 0x00_u8, 0x80_u8, 0x08_u8, 0x20_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    ]
    decode_child_error = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.decode_dynamic_bulk_child(
        json_descriptor,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS),
        1,
      )
    end
    decode_child_error.message.to_s.should contain("JSON")

    borrowed_encode_error = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode_borrowed(
        json_value,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
      )
    end
    borrowed_encode_error.message.to_s.should contain("JSON")
    borrowed_decode_error = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.decode_borrowed(
        CrystalClick::BinaryValueCodec.encode(json_value),
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
      )
    end
    borrowed_decode_error.message.to_s.should contain("JSON")

    # With no JSON ordinary arm, the value routes to SharedVariant. Inline
    # JSON remains forbidden at the borrowed-envelope owner.
    shared_error = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::DynamicValueCodec.encode(
        CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType),
        [[json_value] of CrystalClick::BinaryValue] of Array(CrystalClick::BinaryValue),
      )
    end
    shared_error.message.to_s.should contain("JSON")
  end

  it "retains the direct-JSON actual guard in BinaryDynamicBulkPlan" do
    json = w206a_json_type
    structure = CrystalClick::DynamicStructure.new([json] of CrystalClick::BinaryDataType)
    plan_error = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDynamicBulkPlan.new(
        CrystalClick::BinaryDataType.dynamic(max_types: 1),
        {"root" => structure},
      )
    end
    plan_error.message.to_s.should contain("JSON")
  end

  it "preserves scalar RowBinary Dynamic(JSON) encode/decode independently of bulk admission" do
    json = w206a_json_type
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    value = CrystalClick::BinaryValue.dynamic(dynamic, w206a_json_value(json))
    # Dynamic descriptor, selected JSON descriptor, and the empty JSON row.
    scalar_wire = Bytes[
      0x2b_u8, 0x00_u8,
      0x30_u8, 0x00_u8, 0x80_u8, 0x08_u8, 0x20_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x00_u8,
    ]

    CrystalClick::BinaryValueCodec.encode(value).should eq(scalar_wire)
    decoded = CrystalClick::BinaryValueCodec.decode(scalar_wire)
    decoded.type.should eq(dynamic)
    decoded.is_null?.should be_false
    decoded_json = decoded.child_at(0)
    decoded_json.type.should eq(json)
    decoded_json.json_row.empty?.should be_true
    CrystalClick::BinaryValueCodec.encode(decoded).should eq(scalar_wire)
  end
end
