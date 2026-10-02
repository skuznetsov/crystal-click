require "./spec_helper"

private def w122dv_u64_le(value : UInt64) : Bytes
  Bytes[
    (value & 0xff_u64).to_u8,
    ((value >> 8) & 0xff_u64).to_u8,
    ((value >> 16) & 0xff_u64).to_u8,
    ((value >> 24) & 0xff_u64).to_u8,
    ((value >> 32) & 0xff_u64).to_u8,
    ((value >> 40) & 0xff_u64).to_u8,
    ((value >> 48) & 0xff_u64).to_u8,
    ((value >> 56) & 0xff_u64).to_u8,
  ]
end

private def w122dv_concat(parts : Array(Bytes)) : Bytes
  bytes = [] of UInt8
  parts.each { |part| part.each { |byte| bytes << byte } }
  Bytes.new(bytes.size) { |index| bytes[index] }
end

private def w122dv_marks(pairs : Array(Tuple(UInt64, UInt64))) : Array(CrystalClick::DynamicDiscriminatorMark)
  pairs.map { |offset, rows| CrystalClick::DynamicDiscriminatorMark.new(offset, rows) }
end

describe "W122 Dynamic logical values" do
  it "routes exact arms, writes independent bulk lanes, and decodes a nonzero-origin window" do
    string_type = CrystalClick::BinaryDataType.primitive("String")
    nullable_string_type = CrystalClick::BinaryDataType.nullable(string_type)
    array_type = CrystalClick::BinaryDataType.array(nullable_string_type)
    structure = CrystalClick::DynamicStructure.new([
      array_type,
      string_type,
    ] of CrystalClick::BinaryDataType)

    # SQL-name order is Array(Nullable(String))=0, SharedVariant=1,
    # String=2; top-level NULL uses the distinct discriminator 255.
    structure.canonical_variant_names.should eq([
      "Array(Nullable(String))", "SharedVariant", "String",
    ] of String)

    skipped_string = CrystalClick::BinaryValue.string("skip")
    empty_array = CrystalClick::BinaryValue.array(array_type, [] of CrystalClick::BinaryValue)
    null_and_x = CrystalClick::BinaryValue.array(array_type, [
      CrystalClick::BinaryValue.nullable(nullable_string_type),
      CrystalClick::BinaryValue.nullable(nullable_string_type, CrystalClick::BinaryValue.string("x")),
    ] of CrystalClick::BinaryValue)
    granules = [
      [skipped_string] of CrystalClick::BinaryValue,
      [empty_array, null_and_x] of CrystalClick::BinaryValue,
      [empty_array, CrystalClick::BinaryValue.null] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)

    # Independent COMPACT discriminator bytes: mark 0 is a String; mark 1
    # holds two Arrays; mark 2 has an empty Array and distinct NULL tag 255.
    discriminator_bytes = Bytes[
      0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x01_u8, 0x01_u8, 0x02_u8,
      0x02_u8, 0x01_u8, 0x00_u8,
      0x02_u8, 0x00_u8, 0x00_u8, 0xff_u8,
    ]
    discriminator = CrystalClick::DynamicDiscriminatorStream.new(
      discriminator_bytes,
      w122dv_marks([
        {8_u64, 1_u64}, {11_u64, 2_u64}, {14_u64, 2_u64}, {18_u64, 0_u64},
      ] of Tuple(UInt64, UInt64))
    )

    # Array arm: per-occurrence UInt64 lengths [0, 2, 0], Nullable flags
    # [NULL, non-NULL], and String nested payloads [empty default, "x"].
    array_lanes = CrystalClick::BinaryBulkStreams.new(
      mark_count: 3,
      streams: {
        "root.sizes" => CrystalClick::BinaryBulkStream.new(
          w122dv_concat([
            w122dv_u64_le(0_u64), w122dv_u64_le(2_u64), w122dv_u64_le(0_u64),
          ] of Bytes),
          [0_u64, 0_u64, 16_u64, 24_u64]
        ),
        "root.elements.nulls" => CrystalClick::BinaryBulkStream.new(
          Bytes[0x01_u8, 0x00_u8],
          [0_u64, 0_u64, 2_u64, 2_u64]
        ),
        "root.elements.nested.data" => CrystalClick::BinaryBulkStream.new(
          Bytes[0x00_u8, 0x01_u8, 0x78_u8],
          [0_u64, 0_u64, 3_u64, 3_u64]
        ),
      } of String => CrystalClick::BinaryBulkStream
    )
    string_lanes = CrystalClick::BinaryBulkStreams.new(
      mark_count: 3,
      streams: {
        "root.data" => CrystalClick::BinaryBulkStream.new(
          Bytes[0x04_u8, 0x73_u8, 0x6b_u8, 0x69_u8, 0x70_u8],
          [0_u64, 5_u64, 5_u64, 5_u64]
        ),
      } of String => CrystalClick::BinaryBulkStream
    )
    shared_lanes = CrystalClick::BinaryBulkStreams.new(
      mark_count: 3,
      streams: {
        "root.data" => CrystalClick::BinaryBulkStream.new(
          Bytes.empty,
          [0_u64, 0_u64, 0_u64, 0_u64]
        ),
      } of String => CrystalClick::BinaryBulkStream
    )
    literal = CrystalClick::DynamicValueStreams.new(
      discriminators: discriminator,
      arms: {
        "Array(Nullable(String))" => array_lanes,
        "String"                  => string_lanes,
        "SharedVariant"           => shared_lanes,
      } of String => CrystalClick::BinaryBulkStreams
    )

    encoded = CrystalClick::DynamicValueCodec.encode(structure, granules, mode: 1_u64)
    encoded.discriminators.bytes.should eq(discriminator_bytes)
    encoded.discriminators.marks.map { |mark| {mark.offset, mark.rows} }.should eq([
      {8_u64, 1_u64}, {11_u64, 2_u64}, {14_u64, 2_u64}, {18_u64, 0_u64},
    ])
    encoded.arm_names.sort.should eq(["Array(Nullable(String))", "SharedVariant", "String"] of String)
    ["Array(Nullable(String))", "SharedVariant", "String"].each do |name|
      actual = encoded.arm(name)
      expected = literal.arm(name)
      actual.mark_count.should eq(3)
      actual.roles.sort.should eq(expected.roles.sort)
      expected.roles.each do |role|
        actual_stream = actual.stream(role)
        expected_stream = expected.stream(role)
        actual_stream.bytes.should eq(expected_stream.bytes)
        actual_stream.offsets.should eq(expected_stream.offsets)
      end
    end

    selected = CrystalClick::DynamicValueCodec.decode(
      structure,
      literal,
      first_mark: 1,
      mark_count: 2
    )
    selected.size.should eq(2)
    selected[0].size.should eq(2)
    selected[0][0].type.should eq(array_type)
    selected[0][0].element_count.should eq(0)
    selected[0][1].element_count.should eq(2)
    selected[0][1].element_at(0).is_null?.should be_true
    selected[0][1].element_at(0).element_count.should eq(0)
    selected[0][1].element_at(1).is_null?.should be_false
    selected[0][1].element_at(1).child_at(0).as_string.should eq("x")
    selected[1].size.should eq(2)
    selected[1][0].type.should eq(array_type)
    selected[1][0].element_count.should eq(0)
    selected[1][1].type.tag.should eq(CrystalClick::BinaryDataType::TAG_NOTHING)
    selected[1][1].is_null?.should be_true
  end

  it "decodes a shared envelope whose nominal type is also an ordinary arm" do
    string_type = CrystalClick::BinaryDataType.primitive("String")
    structure = CrystalClick::DynamicStructure.new([string_type] of CrystalClick::BinaryDataType)
    discriminator = CrystalClick::DynamicDiscriminatorStream.new(
      Bytes[
        0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
        0x01_u8, 0x01_u8, 0x00_u8,
      ],
      w122dv_marks([{8_u64, 1_u64}, {11_u64, 0_u64}] of Tuple(UInt64, UInt64))
    )
    ordinary = CrystalClick::BinaryBulkStreams.new(
      mark_count: 1,
      streams: {
        "root.data" => CrystalClick::BinaryBulkStream.new(Bytes.empty, [0_u64, 0_u64]),
      } of String => CrystalClick::BinaryBulkStream
    )
    # SharedVariant String envelope is three bytes (15 01 78); its outer
    # single-stream String frame is four bytes including the 03 length prefix.
    shared = CrystalClick::BinaryBulkStreams.new(
      mark_count: 1,
      streams: {
        "root.data" => CrystalClick::BinaryBulkStream.new(
          Bytes[0x03_u8, 0x15_u8, 0x01_u8, 0x78_u8],
          [0_u64, 4_u64]
        ),
      } of String => CrystalClick::BinaryBulkStream
    )
    literal = CrystalClick::DynamicValueStreams.new(
      discriminator,
      {
        "SharedVariant" => shared,
        "String"        => ordinary,
      } of String => CrystalClick::BinaryBulkStreams
    )

    decoded = CrystalClick::DynamicValueCodec.decode(structure, literal)
    decoded[0][0].as_string.should eq("x")

    # Rewriting is canonical and may route that same logical value into the
    # ordinary arm; the decoder must not require physical roster assignment.
    rewritten = CrystalClick::DynamicValueCodec.encode(structure, decoded)
    rewritten.discriminators.byte_at(10).should eq(1_u8)
  end

  it "uses a typed SharedVariant spill and rejects top-level Nullable envelopes" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    structure = CrystalClick::DynamicStructure.new([uint8] of CrystalClick::BinaryDataType)
    encoded = CrystalClick::DynamicValueCodec.encode(structure, [
      [CrystalClick::BinaryValue.bool(true)] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue))
    encoded.discriminators.byte_at(10).should eq(0_u8)
    encoded.arm("SharedVariant").stream("root.data").bytes.should eq(Bytes[0x02_u8, 0x2d_u8, 0x01_u8])
    decoded = CrystalClick::DynamicValueCodec.decode(structure, encoded)
    decoded[0][0].as_bool.should be_true

    nullable = CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.primitive("String"))
    empty_structure = CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::DynamicValueCodec.encode(empty_structure, [
        [CrystalClick::BinaryValue.nullable(nullable)] of CrystalClick::BinaryValue,
      ] of Array(CrystalClick::BinaryValue))
    end

    # A typed top-level Nullable(String) NULL envelope is a valid scalar
    # envelope grammar but outside this normalized Dynamic producer profile.
    bad_discriminator = CrystalClick::DynamicDiscriminatorStream.new(
      Bytes[
        0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
        0x01_u8, 0x01_u8, 0x00_u8,
      ],
      w122dv_marks([{8_u64, 1_u64}, {11_u64, 0_u64}] of Tuple(UInt64, UInt64))
    )
    bad_shared = CrystalClick::BinaryBulkStreams.new(
      mark_count: 1,
      streams: {
        "root.data" => CrystalClick::BinaryBulkStream.new(
          Bytes[0x03_u8, 0x23_u8, 0x15_u8, 0x01_u8],
          [0_u64, 4_u64]
        ),
      } of String => CrystalClick::BinaryBulkStream
    )
    malformed = CrystalClick::DynamicValueStreams.new(
      bad_discriminator,
      {"SharedVariant" => bad_shared} of String => CrystalClick::BinaryBulkStreams
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicValueCodec.decode(empty_structure, malformed)
    end
  end

  it "rejects a depth-limited spilled descriptor before routing it by name" do
    type = CrystalClick::BinaryDataType.primitive("UInt8")
    value = CrystalClick::BinaryValue.fixed(type, Bytes[0x01_u8])
    6.times do
      type = CrystalClick::BinaryDataType.array(type)
      value = CrystalClick::BinaryValue.array(type, [value] of CrystalClick::BinaryValue)
    end
    structure = CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)
    limits = CrystalClick::BinaryCodecLimits.new(
      max_depth: 4,
      max_nodes: 1000,
      max_elements: 1000,
      max_bytes: 4096
    )

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::DynamicValueCodec.encode(
        structure,
        [[value] of CrystalClick::BinaryValue] of Array(CrystalClick::BinaryValue),
        limits: limits
      )
    end
  end
end
