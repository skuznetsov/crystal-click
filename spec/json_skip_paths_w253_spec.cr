require "./spec_helper"

describe "W253 JSON SKIP path admission RED" do
  it "decodes the independently specified nonempty binary SKIP descriptor" do
    # JSON(id UInt8, SKIP a): v0, max_dynamic_paths=1024,
    # max_dynamic_types=32, one typed path, one SKIP path, no regexps.
    wire = Bytes[
      0x30_u8, 0x00, 0x80, 0x08, 0x20, 0x01,
      0x02, 0x69, 0x64, 0x01,
      0x01, 0x01, 0x61, 0x00,
    ]

    decoded = CrystalClick::BinaryDataTypeCodec.decode(wire)
    decoded.name.should eq("JSON(id UInt8, SKIP a)")
  end

  it "parses the independently specified canonical SQL type name" do
    parsed = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(
      "JSON(id UInt8, SKIP a)",
    )

    parsed.should_not be_nil
    parsed.not_nil!.name.should eq("JSON(id UInt8, SKIP a)")
  end

  it "accepts the same declaration through the root Object schema parser" do
    schema = CrystalClick::ObjectDocumentSchemaParser.parse("JSON(id UInt8, SKIP a)")

    schema.declaration.should eq("JSON(id UInt8, SKIP a)")
  end
end

private def w253_json_limits(
  max_depth : Int = 64,
  max_nodes : Int = 4_096,
  max_elements : Int = 1_000_000,
  max_bytes : Int = 64 * 1024 * 1024,
) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: max_depth,
    max_nodes: max_nodes,
    max_elements: max_elements,
    max_bytes: max_bytes,
  )
end

describe "W253 JSON SKIP descriptor identity and RowBinary policy" do
  it "preserves reserved raw SKIP words in canonical names and literal wire bytes" do
    skip_word = CrystalClick::BinaryDataType.json(skip_paths: ["SKIP"])
    skip_word_wire = Bytes[
      0x30_u8, 0x00, 0x80, 0x08, 0x20, 0x00,
      0x01, 0x04, 0x53, 0x4b, 0x49, 0x50, 0x00,
    ]
    skip_word.name.should eq("JSON(SKIP SKIP)")
    CrystalClick::BinaryDataTypeCodec.encode(skip_word).should eq(skip_word_wire)
    CrystalClick::BinaryDataTypeCodec.decode(skip_word_wire).should eq(skip_word)
    CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(skip_word.name).should eq(skip_word)

    # The raw descriptor codec can preserve names that stock getName emits in
    # a form its SQL type parser cannot bind unambiguously as a SKIP path.
    # Keep wire identity, but do not promote those spellings into the shared
    # canonical SQL-name grammar or Object owner.
    regexp_wire = Bytes[
      0x30_u8, 0x00, 0x80, 0x08, 0x20, 0x00,
      0x01, 0x06, 0x52, 0x45, 0x47, 0x45, 0x58, 0x50, 0x00,
    ]
    ["REGEXP", "RegExp", "regexp"].each do |raw_path|
      descriptor = CrystalClick::BinaryDataType.json(skip_paths: [raw_path])
      descriptor.json_type.not_nil!.skip_paths.should eq([raw_path])
      encoded = CrystalClick::BinaryDataTypeCodec.encode(descriptor)
      if raw_path == "REGEXP"
        encoded.should eq(regexp_wire)
        encoded.should eq(CrystalClick::BinaryDataTypeCodec.encode(CrystalClick::BinaryDataTypeCodec.decode(regexp_wire)))
        descriptor.name.should eq("JSON(SKIP REGEXP)")
      end
      CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical("JSON(SKIP #{raw_path})").should be_nil
      expect_raises(ArgumentError) do
        CrystalClick::ObjectDocumentSchema.new(
          {} of String => CrystalClick::BinaryDataType,
          skip_paths: [raw_path],
        )
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(SKIP #{raw_path})")
      end
    end

    regexp_descriptor = CrystalClick::BinaryDataType.json(skip_paths: ["REGEXP"])
    legacy = CrystalClick::DynamicStructure.new(
      [regexp_descriptor] of CrystalClick::BinaryDataType,
      version: CrystalClick::DynamicStructure::VERSION_V1,
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::DynamicStructureCodec.encode_prefix_without_statistics(legacy)
    end

    lowercase = CrystalClick::BinaryDataType.json(skip_paths: ["skip"])
    lowercase.name.should eq("JSON(SKIP skip)")
    CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(lowercase.name).should eq(lowercase)
  end

  it "roundtrips sorted, deduplicated SKIP identity through literal descriptor bytes and canonical names" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    source_paths = ["z", "a", "z"]
    type = CrystalClick::BinaryDataType.json(
      typed_paths: {"id" => uint8},
      skip_paths: source_paths,
    )
    source_paths.clear

    # Independently authored v0 descriptor for JSON(id UInt8, SKIP a, SKIP z).
    wire = Bytes[
      0x30_u8, 0x00, 0x80, 0x08, 0x20, 0x01,
      0x02, 0x69, 0x64, 0x01,
      0x02, 0x01, 0x61, 0x01, 0x7a,
      0x00,
    ]
    type.name.should eq("JSON(id UInt8, SKIP a, SKIP z)")
    CrystalClick::BinaryDataTypeCodec.encode(type).should eq(wire)

    decoded = CrystalClick::BinaryDataTypeCodec.decode(wire)
    decoded.should eq(type)
    decoded.hash.should eq(type.hash)
    decoded.name.should eq("JSON(id UInt8, SKIP a, SKIP z)")
    decoded.json_type.not_nil!.skip_paths.should eq(["a", "z"])
    CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(type.name).should eq(type)

    returned = decoded.json_type.not_nil!.skip_paths
    returned.clear
    decoded.json_type.not_nil!.skip_paths.should eq(["a", "z"])
  end

  it "detaches mutable source and returned SKIP names" do
    mutable = String.new(Bytes[0x61_u8])
    source_paths = [mutable]
    type = CrystalClick::BinaryDataType.json(skip_paths: source_paths)

    mutable.to_unsafe[0] = 0x78_u8
    source_paths.clear
    type.json_type.not_nil!.skip_paths.should eq(["a"])

    returned = type.json_type.not_nil!.skip_paths
    returned[0].to_unsafe[0] = 0x79_u8
    type.json_type.not_nil!.skip_paths.should eq(["a"])
  end

  it "rejects a typed descendant of a SKIP path but permits the reverse prefix" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.json(typed_paths: {"secretary" => uint8}, skip_paths: ["secret"])
    end

    # Stock rejects only when typed_path.starts_with?(skip_path); the reverse
    # prefix does not hide the typed path and remains admissible.
    accepted = CrystalClick::BinaryDataType.json(
      typed_paths: {"secret" => uint8},
      skip_paths: ["secretary"],
    )
    accepted.name.should eq("JSON(secret UInt8, SKIP secretary)")
  end

  it "charges supplied duplicate SKIP entries against node, element, and byte budgets" do
    duplicate_paths = ["a", "a"]

    node_budget = CrystalClick::BinaryCodecBudget.new(w253_json_limits(max_nodes: 1), true)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::JsonSkipPaths.new(duplicate_paths, node_budget)
    end
    node_budget.node_count.should eq(0_i64)

    element_budget = CrystalClick::BinaryCodecBudget.new(w253_json_limits(max_elements: 1), true)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::JsonSkipPaths.new(duplicate_paths, element_budget)
    end
    element_budget.element_count.should eq(0_i64)

    # Two one-byte entries each have a one-byte VarUInt length prefix.
    byte_budget = CrystalClick::BinaryCodecBudget.new(w253_json_limits(max_bytes: 3), true)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::JsonSkipPaths.new(duplicate_paths, byte_budget)
    end
    byte_budget.node_count.should eq(2_i64)
    byte_budget.element_count.should eq(2_i64)
    byte_budget.wire_byte_count.should eq(0_i64)
  end

  it "preflights duplicate SKIP entries in the root Object schema owner" do
    duplicate_paths = ["a", "a"]
    typed_paths = {} of String => CrystalClick::BinaryDataType

    node_budget = CrystalClick::BinaryCodecBudget.new(w253_json_limits(max_nodes: 2), true)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentSchema.new(typed_paths, 1, 1, node_budget, 1, duplicate_paths)
    end

    element_budget = CrystalClick::BinaryCodecBudget.new(w253_json_limits(max_elements: 1), true)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentSchema.new(typed_paths, 1, 1, element_budget, 1, duplicate_paths)
    end

    byte_budget = CrystalClick::BinaryCodecBudget.new(w253_json_limits(max_bytes: 3), true)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentSchema.new(typed_paths, 1, 1, byte_budget, 1, duplicate_paths)
    end
  end

  it "charges duplicate descriptor entries before deduplicating retained identity" do
    duplicate_wire = Bytes[
      0x30_u8, 0x00, 0x80, 0x08, 0x20, 0x00,
      0x02, 0x01, 0x61, 0x01, 0x61, 0x00,
    ]
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(duplicate_wire, w253_json_limits(max_elements: 1))
    end

    decoded = CrystalClick::BinaryDataTypeCodec.decode(duplicate_wire, w253_json_limits(max_elements: 2))
    decoded.json_type.not_nil!.skip_paths.should eq(["a"])
    decoded.name.should eq("JSON(SKIP a)")
  end

  it "renders and parses a default-capacity Object schema containing only SKIP clauses" do
    empty = {} of String => CrystalClick::BinaryDataType
    schema = CrystalClick::ObjectDocumentSchema.new(empty, skip_paths: ["a"])
    schema.declaration.should eq("JSON(SKIP a)")
    schema.typed_paths.should be_empty
    schema.skip_paths.should eq(["a"])
    parsed = CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(SKIP a)")
    parsed.declaration.should eq("JSON(SKIP a)")
    parsed.skip_paths.should eq(["a"])

    # The raw name is itself the reserved clause word, and remains an opaque
    # path argument rather than changing the clause's identity.
    reserved = CrystalClick::ObjectDocumentSchema.new(empty, skip_paths: ["SKIP"])
    reserved.declaration.should eq("JSON(SKIP SKIP)")
    CrystalClick::ObjectDocumentSchema.parse_declaration(reserved.declaration).skip_paths.should eq(["SKIP"])
  end

  it "preserves every encoded path but applies the source-backed lower-bound law on scalar decode" do
    type = CrystalClick::BinaryDataType.json(skip_paths: ["a", "z"])
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    entries = [
      {"a", CrystalClick::BinaryValue.fixed(uint8, Bytes[1_u8])},
      {"ab", CrystalClick::BinaryValue.fixed(uint8, Bytes[2_u8])},
      {"b", CrystalClick::BinaryValue.fixed(uint8, Bytes[5_u8])},
      {"z", CrystalClick::BinaryValue.fixed(uint8, Bytes[3_u8])},
      {"zx", CrystalClick::BinaryValue.fixed(uint8, Bytes[4_u8])},
    ] of Tuple(String, CrystalClick::BinaryValue)
    row = CrystalClick::BinaryJsonRow.new(type, entries)
    value = CrystalClick::BinaryValue.json(type, row)

    # RowBinary writer preserves an already-materialized row. The decoder's
    # raw lower_bound law drops exact a/z and interior prefix ab, but retains
    # zx because its lower_bound is the end iterator.
    row_wire = Bytes[
      0x05_u8,
      0x01, 0x61, 0x01, 0x01,
      0x02, 0x61, 0x62, 0x01, 0x02,
      0x01, 0x62, 0x01, 0x05,
      0x01, 0x7a, 0x01, 0x03,
      0x02, 0x7a, 0x78, 0x01, 0x04,
    ]
    CrystalClick::BinaryValueCodec.encode_value(value).should eq(row_wire)

    decoded = CrystalClick::BinaryValueCodec.decode_value(type, row_wire)
    decoded_row = decoded.json_row
    decoded_paths = (0...decoded_row.path_count).map { |index| decoded_row.path_at(index) }.to_a
    decoded_paths.should eq(["b", "zx"])
    decoded.json_row.value_for("b").not_nil!.byte_at(0).should eq(5_u8)
    decoded.json_row.value_for("zx").not_nil!.byte_at(0).should eq(4_u8)
  end

  it "fully validates and consumes malformed payloads even when their path is skipped" do
    type = CrystalClick::BinaryDataType.json(skip_paths: ["a"])
    expect_raises(CrystalClick::CorruptPartError) do
      # One row path a, UInt8 descriptor, but its value byte is truncated.
      CrystalClick::BinaryValueCodec.decode_value(type, Bytes[0x01_u8, 0x01, 0x61, 0x01])
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      # Top-level Nullable is unsupported as a JSON runtime value; SKIP must
      # not turn that invalid value into an unvalidated omission.
      CrystalClick::BinaryValueCodec.decode_value(type, Bytes[0x01_u8, 0x01, 0x61, 0x23, 0x01])
    end
  end

  it "keeps SKIP REGEXP, empty names, and noncanonical spellings outside this boundary" do
    regexp_wire = Bytes[
      0x30_u8, 0x00, 0x80, 0x08, 0x20, 0x00, 0x00,
      0x01, 0x03, 0x5e, 0x6b, 0x24,
    ]
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.decode(regexp_wire)
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.json(skip_paths: [""])
    end
    CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical("JSON(SKIP ``)").should be_nil
    CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical("JSON(SKIP REGEXP '.*')").should be_nil
  end
end
