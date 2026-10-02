require "./spec_helper"

private def w123_root_bulk(bytes : Bytes, offsets : Array(UInt64), role : String = "root.data") : CrystalClick::BinaryBulkStreams
  CrystalClick::BinaryBulkStreams.new(3, {role => CrystalClick::BinaryBulkStream.new(bytes, offsets)})
end

# These are hand-authored bytes and grids, not encoder-generated expectations.
private def w123_root_literal_streams(bad_last_envelope : Bool = false) : CrystalClick::ObjectDocumentStreams
  metadata = CrystalClick::ObjectDynamicStructureStreams.new(
    Bytes[4, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0x64, 0, 0],
    {"d" => Bytes[4, 0, 0, 0, 0, 0, 0, 0, 1, 0x15, 0]}
  )
  typed = w123_root_bulk(
    Bytes[9, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0],
    [0_u64, 8_u64, 16_u64, 24_u64]
  )
  discriminators = CrystalClick::DynamicDiscriminatorStream.new(
    Bytes[0, 0, 0, 0, 0, 0, 0, 0, 1, 255, 1],
    [
      CrystalClick::DynamicDiscriminatorMark.new(8_u64, 1_u64),
      CrystalClick::DynamicDiscriminatorMark.new(9_u64, 1_u64),
      CrystalClick::DynamicDiscriminatorMark.new(10_u64, 1_u64),
      CrystalClick::DynamicDiscriminatorMark.new(11_u64, 0_u64),
    ]
  )
  dynamic = CrystalClick::DynamicValueStreams.new(discriminators, {
    "SharedVariant" => w123_root_bulk(Bytes.empty, [0_u64, 0_u64, 0_u64, 0_u64]),
    "String"        => w123_root_bulk(Bytes[4, 0x73, 0x6b, 0x69, 0x70, 3, 0x61, 0, 0x62], [0_u64, 5_u64, 5_u64, 9_u64]),
  })
  # Array(Tuple(paths String, values String)): empty first row; Bool true and
  # Int64 -7 in the selected rows, with independent binary envelopes.
  values = Bytes[2, 0x2d, 1, 9, 0x0a, 0xf9, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]
  values[4] = 0xff_u8 if bad_last_envelope
  shared = CrystalClick::BinaryBulkStreams.new(3, {
    "root.sizes"                 => CrystalClick::BinaryBulkStream.new(Bytes[0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0], [0_u64, 8_u64, 16_u64, 24_u64]),
    "root.elements.field.0.data" => CrystalClick::BinaryBulkStream.new(Bytes[3, 0x73, 0x2e, 0x78, 3, 0x73, 0x2e, 0x78], [0_u64, 0_u64, 4_u64, 8_u64]),
    "root.elements.field.1.data" => CrystalClick::BinaryBulkStream.new(values, [0_u64, 0_u64, 3_u64, 13_u64]),
  })
  CrystalClick::ObjectDocumentStreams.new(metadata, [1_u64, 1_u64, 1_u64], {"t" => typed}, {"d" => dynamic}, shared)
end

describe "W123 independent Object document composition" do
  it "admits the complete outer grid budget before walking a late malformed row count" do
    structure = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure
    )
    metadata = CrystalClick::ObjectDynamicStructureCodec.encode(structure)
    rows = Array(UInt64).new(20, 1_u64)
    rows[19] = UInt64::MAX
    streams = CrystalClick::ObjectDocumentStreams.new(
      metadata, rows,
      {} of String => CrystalClick::BinaryBulkStreams,
      {} of String => CrystalClick::DynamicValueStreams,
      CrystalClick::BinaryBulkStreams.new(20, {} of String => CrystalClick::BinaryBulkStream)
    )
    limits = CrystalClick::BinaryCodecLimits.new(max_depth: 64, max_nodes: 10, max_elements: 1_000, max_bytes: 1_000)
    error = expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectDocumentCodec.decode({} of String => CrystalClick::BinaryDataType, streams, mark_count: 0, limits: limits)
    end
    error.message.should eq("binary codec node limit exceeded")
  end

  it "rejects zero-row real Object marks even without Dynamic lanes" do
    structure = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure
    )
    plan = CrystalClick::ObjectDocumentPlan.new(structure, {} of String => CrystalClick::BinaryDataType)
    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentCodec.encode(plan, [[] of CrystalClick::ObjectDocument])
    end
    metadata = CrystalClick::ObjectDynamicStructureCodec.encode(structure)
    shared = CrystalClick::BinaryBulkStreams.new(1, {
      "root.sizes"                 => CrystalClick::BinaryBulkStream.new(Bytes.empty, [0_u64, 0_u64]),
      "root.elements.field.0.data" => CrystalClick::BinaryBulkStream.new(Bytes.empty, [0_u64, 0_u64]),
      "root.elements.field.1.data" => CrystalClick::BinaryBulkStream.new(Bytes.empty, [0_u64, 0_u64]),
    })
    streams = CrystalClick::ObjectDocumentStreams.new(metadata, [0_u64], {} of String => CrystalClick::BinaryBulkStreams,
      {} of String => CrystalClick::DynamicValueStreams, shared)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectDocumentCodec.decode({} of String => CrystalClick::BinaryDataType, streams, mark_count: 0)
    end
    empty = CrystalClick::ObjectDocumentCodec.encode(plan, [] of Array(CrystalClick::ObjectDocument))
    CrystalClick::ObjectDocumentCodec.decode({} of String => CrystalClick::BinaryDataType, empty).should be_empty
  end

  it "distinguishes a recognized unadmitted Object profile from malformed input" do
    structure = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String, shared_data_version: 1_u64, bucket_count: 2_u64),
      {} of String => CrystalClick::DynamicStructure
    )
    metadata = CrystalClick::ObjectDynamicStructureCodec.encode(structure)
    streams = CrystalClick::ObjectDocumentStreams.new(metadata, [] of UInt64,
      {} of String => CrystalClick::BinaryBulkStreams, {} of String => CrystalClick::DynamicValueStreams,
      CrystalClick::BinaryBulkStreams.new(0, {} of String => CrystalClick::BinaryBulkStream))
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentCodec.decode({} of String => CrystalClick::BinaryDataType, streams)
    end
  end

  it "decodes independent full lane literals and validates the last selected envelope before returning" do
    schema = {"t" => CrystalClick::BinaryDataType.primitive("UInt64")}
    selected = CrystalClick::ObjectDocumentCodec.decode(schema, w123_root_literal_streams, first_mark: 1, mark_count: 2)
    selected[0][0].paths.should eq(["s.x", "t"])
    selected[0][0].value_for("s.x").as_bool.should be_true
    selected[1][0].value_for("d").as_string.should eq("a\0b")
    selected[1][0].value_for("s.x").as_int64.should eq(-7_i64)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectDocumentCodec.decode(schema, w123_root_literal_streams(true), first_mark: 1, mark_count: 2)
    end
  end

  it "charges each literal physical byte once across metadata and all selected children" do
    schema = {"t" => CrystalClick::BinaryDataType.primitive("UInt64")}
    limits = CrystalClick::BinaryCodecLimits.new(max_depth: 64, max_nodes: 1_000_000, max_elements: 3_000_000, max_bytes: 113)
    # Full input: metadata 24 + typed 24 + discriminator 11 + arm 9 +
    # shared sizes 24 + paths 8 + framed envelopes 13 = 113 bytes.
    CrystalClick::ObjectDocumentCodec.decode(schema, w123_root_literal_streams, limits: limits).size.should eq(3)
    short = CrystalClick::BinaryCodecLimits.new(max_depth: 64, max_nodes: 1_000_000, max_elements: 3_000_000, max_bytes: 112)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectDocumentCodec.decode(schema, w123_root_literal_streams, limits: short)
    end
    # Window excludes typed row 0 (8), Dynamic tag 0 (1), "skip" frame (5)
    # and shared sizes row 0 (8). Metadata and mode header still belong to it.
    selected_exact = CrystalClick::BinaryCodecLimits.new(max_depth: 64, max_nodes: 1_000_000, max_elements: 3_000_000, max_bytes: 91)
    CrystalClick::ObjectDocumentCodec.decode(schema, w123_root_literal_streams, first_mark: 1, mark_count: 2, limits: selected_exact).size.should eq(2)
    selected_short = CrystalClick::BinaryCodecLimits.new(max_depth: 64, max_nodes: 1_000_000, max_elements: 3_000_000, max_bytes: 90)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectDocumentCodec.decode(schema, w123_root_literal_streams, first_mark: 1, mark_count: 2, limits: selected_short)
    end
  end

  it "combines typed, Dynamic and shared fields with NULL omission over a nonzero window" do
    u64 = CrystalClick::BinaryDataType.primitive("UInt64")
    string = CrystalClick::BinaryDataType.primitive("String")
    structure = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["d"]),
      {"d" => CrystalClick::DynamicStructure.new([string])}
    )
    plan = CrystalClick::ObjectDocumentPlan.new(structure, {"t" => u64})
    documents = [
      [CrystalClick::ObjectDocument.new({"t" => CrystalClick::BinaryValue.uint64(9_u64), "d" => CrystalClick::BinaryValue.string("skip")})],
      [CrystalClick::ObjectDocument.new({"t" => CrystalClick::BinaryValue.uint64(2_u64), "d" => CrystalClick::BinaryValue.null, "s.x" => CrystalClick::BinaryValue.bool(true)})],
      [CrystalClick::ObjectDocument.new({"t" => CrystalClick::BinaryValue.uint64(3_u64), "d" => CrystalClick::BinaryValue.string("a\0b"), "s.x" => CrystalClick::BinaryValue.int64(-7_i64)})],
    ]
    encoded = CrystalClick::ObjectDocumentCodec.encode(plan, documents)
    selected = CrystalClick::ObjectDocumentCodec.decode({"t" => u64}, encoded, first_mark: 1, mark_count: 2)
    selected.size.should eq(2)
    selected[0][0].paths.should eq(["s.x", "t"])
    selected[0][0].value_for("s.x").as_bool.should be_true
    selected[0][0].value_for("t").as_uint64.should eq(2_u64)
    selected[1][0].paths.should eq(["d", "s.x", "t"])
    selected[1][0].value_for("d").as_string.should eq("a\0b")
    selected[1][0].value_for("s.x").as_int64.should eq(-7_i64)

    # Compare emitted physical lanes with the independent literal fixture,
    # not just the result of decoding the writer's own output.
    basic = CrystalClick::ObjectDocumentCodec.encode(plan, documents, mode: 0_u64)
    literal = w123_root_literal_streams
    basic.structures.object.should eq(literal.structures.object)
    basic.structures.dynamics.should eq(literal.structures.dynamics)
    basic.typed_for("t").stream("root.data").bytes.should eq(literal.typed_for("t").stream("root.data").bytes)
    basic.dynamic_for("d").discriminators.bytes.should eq(literal.dynamic_for("d").discriminators.bytes)
    literal.shared.roles.each do |role|
      basic.shared.stream(role).bytes.should eq(literal.shared.stream(role).bytes)
      basic.shared.stream(role).offsets.should eq(literal.shared.stream(role).offsets)
    end
  end
end
