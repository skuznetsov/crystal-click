require "./spec_helper"

private def w263_string_size_validator_bindings(
  owner_kind : Symbol,
  owner_path : String,
  role_stem : String,
  size_callback : String,
  data_callback : String,
) : Array(CrystalClick::ObjectDocumentInlineCallbackOrder::BodyLaneBinding)
  [
    {size_callback, owner_kind, owner_path, "#{role_stem}.string_sizes"},
    {data_callback, owner_kind, owner_path, "#{role_stem}.data"},
  ] of CrystalClick::ObjectDocumentInlineCallbackOrder::BodyLaneBinding
end

private def w263_string_size_validator_words(values : Array(UInt64)) : Bytes
  bytes = Bytes.new(values.size * 8, 0_u8)
  values.each_with_index do |value, index|
    8.times do |byte_index|
      bytes[index * 8 + byte_index] = ((value >> (byte_index * 8)) & 0xff_u64).to_u8
    end
  end
  bytes
end

private def w263_string_size_validator_callbacks(
  bindings : Array(CrystalClick::ObjectDocumentInlineCallbackOrder::BodyLaneBinding),
  sizes : Bytes,
  data : Bytes,
) : Array(Tuple(String, Bytes))
  [
    {bindings[0][0], sizes},
    {bindings[1][0], data},
  ] of Tuple(String, Bytes)
end

describe "Object document String-size body validator (W263)" do
  it "accepts exact empty, zero-length, and non-UTF-8 extents for ordinary owners" do
    cases = [] of Tuple(Symbol, String, String, String, String)
    cases << {:typed, "label", "root.label", "root.label.size", "root.label"}
    cases << {:typed_dynamic, "payload", "root.arm.0", "root.payload.String.size", "root.payload.String"}
    cases << {:root_dynamic, "sample", "root.arm.1", "root.sample.String.size", "root.sample.String"}

    cases.each do |owner_kind, owner_path, role_stem, size_callback, data_callback|
      bindings = w263_string_size_validator_bindings(owner_kind, owner_path, role_stem, size_callback, data_callback)

      CrystalClick::ObjectDocumentStringSizeBodyValidator.validate!(
        bindings,
        w263_string_size_validator_callbacks(bindings, w263_string_size_validator_words([] of UInt64), Bytes.new(0)),
      )
      CrystalClick::ObjectDocumentStringSizeBodyValidator.validate!(
        bindings,
        w263_string_size_validator_callbacks(bindings, w263_string_size_validator_words([0_u64, 0_u64]), Bytes.new(0)),
      )
      CrystalClick::ObjectDocumentStringSizeBodyValidator.validate!(
        bindings,
        w263_string_size_validator_callbacks(
          bindings,
          w263_string_size_validator_words([0_u64, 3_u64]),
          Bytes[0x00_u8, 0xff_u8, 0x80_u8],
        ),
      )
    end
  end

  it "accepts an extra zero length because this guard certifies extent, not row cardinality" do
    bindings = w263_string_size_validator_bindings(:typed, "label", "root.label", "root.label.size", "root.label")
    callbacks = w263_string_size_validator_callbacks(
      bindings,
      w263_string_size_validator_words([1_u64, 0_u64]),
      Bytes[0xa5_u8],
    )

    CrystalClick::ObjectDocumentStringSizeBodyValidator.validate!(bindings, callbacks)
  end

  it "rejects a String-size callback that is not a whole UInt64 vector" do
    bindings = w263_string_size_validator_bindings(:typed, "label", "root.label", "root.label.size", "root.label")
    callbacks = w263_string_size_validator_callbacks(bindings, Bytes.new(7, 0_u8), Bytes[0x41_u8])

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectDocumentStringSizeBodyValidator.validate!(bindings, callbacks)
    end
  end

  it "rejects UInt64::MAX when the declared total cannot fit the captured payload" do
    bindings = w263_string_size_validator_bindings(:typed, "label", "root.label", "root.label.size", "root.label")
    callbacks = w263_string_size_validator_callbacks(
      bindings,
      w263_string_size_validator_words([UInt64::MAX]),
      Bytes.new(0),
    )

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectDocumentStringSizeBodyValidator.validate!(bindings, callbacks)
    end
  end

  it "rejects a size sum that overruns the exact data callback extent" do
    bindings = w263_string_size_validator_bindings(:typed, "label", "root.label", "root.label.size", "root.label")
    callbacks = w263_string_size_validator_callbacks(
      bindings,
      w263_string_size_validator_words([2_u64]),
      Bytes[0x41_u8],
    )

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectDocumentStringSizeBodyValidator.validate!(bindings, callbacks)
    end
  end

  it "rejects a size sum that leaves bytes unconsumed in the data callback" do
    bindings = w263_string_size_validator_bindings(:typed, "label", "root.label", "root.label.size", "root.label")
    callbacks = w263_string_size_validator_callbacks(
      bindings,
      w263_string_size_validator_words([1_u64]),
      Bytes[0x41_u8, 0x42_u8],
    )

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectDocumentStringSizeBodyValidator.validate!(bindings, callbacks)
    end
  end

  it "rejects a missing data callback instead of treating the size lane as a complete pair" do
    bindings = w263_string_size_validator_bindings(:typed, "label", "root.label", "root.label.size", "root.label")
    callbacks = [{bindings[0][0], w263_string_size_validator_words([1_u64])}] of Tuple(String, Bytes)

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectDocumentStringSizeBodyValidator.validate!(bindings, callbacks)
    end
  end

  it "rejects adjacent-looking bindings with a foreign logical role stem" do
    bindings = w263_string_size_validator_bindings(:typed, "label", "root.label", "root.label.size", "root.label")
    bindings[1] = {bindings[1][0], :typed, "label", "root.other.data"}
    callbacks = w263_string_size_validator_callbacks(bindings, w263_string_size_validator_words([1_u64]), Bytes[0x41_u8])

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectDocumentStringSizeBodyValidator.validate!(bindings, callbacks)
    end
  end

  it "rejects matching role stems owned by different Object paths" do
    bindings = w263_string_size_validator_bindings(:typed, "label", "root.label", "root.label.size", "root.label")
    bindings[1] = {bindings[1][0], :typed, "other", "root.label.data"}
    callbacks = w263_string_size_validator_callbacks(bindings, w263_string_size_validator_words([1_u64]), Bytes[0x41_u8])

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectDocumentStringSizeBodyValidator.validate!(bindings, callbacks)
    end
  end

  it "rejects matching owner paths and role stems with different owner kinds" do
    bindings = w263_string_size_validator_bindings(:typed, "label", "root.label", "root.label.size", "root.label")
    bindings[1] = {bindings[1][0], :typed_dynamic, "label", "root.label.data"}
    callbacks = w263_string_size_validator_callbacks(bindings, w263_string_size_validator_words([1_u64]), Bytes[0x41_u8])

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectDocumentStringSizeBodyValidator.validate!(bindings, callbacks)
    end
  end

  it "rejects callback bytes not named by the corresponding body binding" do
    bindings = w263_string_size_validator_bindings(:typed, "label", "root.label", "root.label.size", "root.label")
    callbacks = [
      {bindings[0][0], w263_string_size_validator_words([1_u64])},
      {"root.label.length", Bytes[0x41_u8]},
    ] of Tuple(String, Bytes)

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectDocumentStringSizeBodyValidator.validate!(bindings, callbacks)
    end
  end

  it "rejects a size callback separated from its data callback by another binding" do
    pair = w263_string_size_validator_bindings(:typed, "label", "root.label", "root.label.size", "root.label")
    bindings = [
      pair[0],
      {"root.id", :typed, "id", "root.id.data"},
      pair[1],
    ] of CrystalClick::ObjectDocumentInlineCallbackOrder::BodyLaneBinding
    callbacks = [
      {bindings[0][0], w263_string_size_validator_words([1_u64])},
      {bindings[1][0], Bytes[0x01_u8]},
      {bindings[2][0], Bytes[0x41_u8]},
    ] of Tuple(String, Bytes)

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectDocumentStringSizeBodyValidator.validate!(bindings, callbacks)
    end
  end

  it "does not reinterpret shared-owner lanes as ordinary String-size pairs" do
    # This deliberately gives a shared owner ordinary-looking suffixes: the
    # authenticated owner kind, not the role spelling alone, excludes MAP and
    # other shared-layout bytes from this ordinary String extent guard.
    bindings = w263_string_size_validator_bindings(
      :shared,
      "0",
      "root.arm.0",
      "root.object_shared_data.0.shared_string.size",
      "root.object_shared_data.0.shared_string",
    )
    callbacks = w263_string_size_validator_callbacks(bindings, Bytes.new(7, 0_u8), Bytes[0x41_u8])

    CrystalClick::ObjectDocumentStringSizeBodyValidator.validate!(bindings, callbacks)
  end
end
