require "./spec_helper"

private def w179ob_structures : CrystalClick::ObjectDynamicStructureSet
  CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new([] of String),
    {} of String => CrystalClick::DynamicStructure,
  )
end

private def w179ob_qbit_type : CrystalClick::QBitType
  CrystalClick::QBitType.new("Int8", 3_u64)
end

private def w179ob_qbit_descriptor : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.qbit(w179ob_qbit_type)
end

private def w179ob_qbit_value : CrystalClick::BinaryValue
  raw = CrystalClick::QBitValue.new(w179ob_qbit_type, Bytes[1_u8, 2_u8, 3_u8])
  CrystalClick::BinaryValue.qbit(raw)
end

private def w179ob_seed_streams(rows_per_mark : Array(UInt64)) : CrystalClick::ObjectDocumentStreams
  structures = w179ob_structures
  empty_plan = CrystalClick::ObjectDocumentPlan.new(
    structures,
    {} of String => CrystalClick::BinaryDataType,
  )
  empty_rows = Array(Array(CrystalClick::ObjectDocument)).new(rows_per_mark.size)
  rows_per_mark.each do |row_count|
    mark = Array(CrystalClick::ObjectDocument).new
    row_count.to_i.times do
      mark << CrystalClick::ObjectDocument.new({} of String => CrystalClick::BinaryValue)
    end
    empty_rows << mark
  end
  CrystalClick::ObjectDocumentCodec.encode(empty_plan, empty_rows)
end

private def w179ob_qbit_streams(
  type : CrystalClick::BinaryDataType,
  values : Array(Array(CrystalClick::BinaryValue)),
) : CrystalClick::ObjectDocumentStreams
  row_counts = values.map { |mark| mark.size.to_u64 }
  seed = w179ob_seed_streams(row_counts)
  typed = CrystalClick::BinaryBulkCodec.encode(type, values)
  CrystalClick::ObjectDocumentStreams.new(
    seed.structures,
    seed.rows_per_mark,
    {"payload" => typed},
    {} of String => CrystalClick::DynamicValueStreams,
    seed.shared,
  )
end

private def w179ob_shared_streams(envelope : Bytes) : CrystalClick::ObjectDocumentStreams
  string = CrystalClick::BinaryDataType.primitive("String")
  tuple = CrystalClick::BinaryDataType.tuple(
    [string, string] of CrystalClick::BinaryDataType,
    ["paths", "values"] of String,
  )
  shared_type = CrystalClick::BinaryDataType.array(tuple)
  entry = CrystalClick::BinaryValue.tuple(tuple, [
    CrystalClick::BinaryValue.string("payload"),
    CrystalClick::BinaryValue.string(String.new(envelope)),
  ] of CrystalClick::BinaryValue)
  row = CrystalClick::BinaryValue.array(shared_type, [entry] of CrystalClick::BinaryValue)
  shared = CrystalClick::BinaryBulkCodec.encode(shared_type, [[row]] of Array(CrystalClick::BinaryValue))
  metadata = CrystalClick::ObjectDynamicStructureCodec.encode(w179ob_structures)
  CrystalClick::ObjectDocumentStreams.new(
    metadata,
    [1_u64],
    {} of String => CrystalClick::BinaryBulkStreams,
    {} of String => CrystalClick::DynamicValueStreams,
    shared,
  )
end

describe "W179 QBit Object and shared-envelope boundary" do
  it "rejects QBit and Nullable(QBit) from typed Object and JSON schema declarations" do
    qbit = w179ob_qbit_descriptor
    nullable_qbit = CrystalClick::BinaryDataType.nullable(qbit)

    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentPlan.new(w179ob_structures, {"payload" => qbit})
    end
    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentPlan.new(w179ob_structures, {"payload" => nullable_qbit})
    end
    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentSchema.new({"payload" => qbit})
    end
    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentSchema.new({"payload" => nullable_qbit})
    end
  end

  it "rejects typed writes before producing streams, including empty and NULL-only batches" do
    qbit = w179ob_qbit_descriptor
    document = CrystalClick::ObjectDocument.new({"payload" => w179ob_qbit_value} of String => CrystalClick::BinaryValue)
    published : CrystalClick::ObjectDocumentStreams? = nil
    expect_raises(ArgumentError) do
      plan = CrystalClick::ObjectDocumentPlan.new(w179ob_structures, {"payload" => qbit})
      published = CrystalClick::ObjectDocumentCodec.encode(plan, [[document]] of Array(CrystalClick::ObjectDocument))
    end
    published.should be_nil

    # The descriptor gate is schema-level, not data-dependent: even no marks
    # cannot make a typed QBit Object profile eligible for publication.
    expect_raises(ArgumentError) do
      plan = CrystalClick::ObjectDocumentPlan.new(w179ob_structures, {"payload" => qbit})
      CrystalClick::ObjectDocumentCodec.encode(plan, [] of Array(CrystalClick::ObjectDocument))
    end

    nullable_qbit = CrystalClick::BinaryDataType.nullable(qbit)
    null_document = CrystalClick::ObjectDocument.new({
      "payload" => CrystalClick::BinaryValue.null(nullable_qbit),
    } of String => CrystalClick::BinaryValue)
    expect_raises(ArgumentError) do
      plan = CrystalClick::ObjectDocumentPlan.new(w179ob_structures, {"payload" => nullable_qbit})
      CrystalClick::ObjectDocumentCodec.encode(plan, [[null_document]] of Array(CrystalClick::ObjectDocument))
    end
  end

  it "rejects caller-supplied typed QBit schemas before empty-window or NULL-only decoding" do
    qbit = w179ob_qbit_descriptor
    one_value = [[w179ob_qbit_value]] of Array(CrystalClick::BinaryValue)
    one_mark = w179ob_qbit_streams(qbit, one_value)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentCodec.decode({"payload" => qbit}, one_mark, first_mark: 0, mark_count: 0)
    end

    no_marks = w179ob_qbit_streams(qbit, [] of Array(CrystalClick::BinaryValue))
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentCodec.decode({"payload" => qbit}, no_marks)
    end

    nullable_qbit = CrystalClick::BinaryDataType.nullable(qbit)
    nulls = [[CrystalClick::BinaryValue.null(nullable_qbit)]] of Array(CrystalClick::BinaryValue)
    null_only = w179ob_qbit_streams(nullable_qbit, nulls)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentCodec.decode({"payload" => nullable_qbit}, null_only)
    end
  end

  it "keeps QBit out of shared borrowed envelopes while ordinary scalars still round-trip" do
    empty_plan = CrystalClick::ObjectDocumentPlan.new(
      w179ob_structures,
      {} of String => CrystalClick::BinaryDataType,
    )
    qbit_document = CrystalClick::ObjectDocument.new({"payload" => w179ob_qbit_value} of String => CrystalClick::BinaryValue)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentCodec.encode(empty_plan, [[qbit_document]] of Array(CrystalClick::ObjectDocument))
    end

    qbit_envelope = CrystalClick::BinaryValueCodec.encode(w179ob_qbit_value)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentCodec.decode(
        {} of String => CrystalClick::BinaryDataType,
        w179ob_shared_streams(qbit_envelope),
      )
    end

    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    normal_plan = CrystalClick::ObjectDocumentPlan.new(w179ob_structures, {"id" => uint64})
    normal_document = CrystalClick::ObjectDocument.new({
      "id"      => CrystalClick::BinaryValue.uint64(42_u64),
      "payload" => CrystalClick::BinaryValue.string("ordinary shared value"),
    } of String => CrystalClick::BinaryValue)
    encoded = CrystalClick::ObjectDocumentCodec.encode(normal_plan, [[normal_document]] of Array(CrystalClick::ObjectDocument))
    decoded = CrystalClick::ObjectDocumentCodec.decode({"id" => uint64}, encoded)
    decoded[0][0].value_for("id").as_uint64.should eq(42_u64)
    decoded[0][0].value_for("payload").as_string.should eq("ordinary shared value")
  end
end
