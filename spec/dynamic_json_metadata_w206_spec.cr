require "./spec_helper"

private def w206_json_metadata_type : CrystalClick::BinaryDataType
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  CrystalClick::BinaryDataType.json(
    max_dynamic_paths: 19,
    max_dynamic_types: 4,
    typed_paths: {"k" => uint8} of String => CrystalClick::BinaryDataType,
  )
end

private def w206_metadata_limits(max_bytes : Int) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: 2,
    max_nodes: 64,
    max_elements: 64,
    max_bytes: max_bytes,
  )
end

describe "W206 direct JSON Dynamic metadata checkpoint" do
  it "round-trips direct JSON through full, prefix, and paired metadata with exact identity and canonical statistics" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    json = w206_json_metadata_type
    statistics = CrystalClick::StructureStatistics.new(
      [5_u64, 7_u64, 11_u64],
      [] of CrystalClick::StructureStatistic,
    )
    # Deliberately unsorted actual roster. The independently authored wire
    # keeps UInt8 first, while canonical statistics order is JSON, shared,
    # UInt8.
    structure = CrystalClick::DynamicStructure.new(
      [uint8, json] of CrystalClick::BinaryDataType,
      statistics,
    )

    json_descriptor = Bytes[
      0x30_u8, 0x00_u8, 0x13_u8, 0x04_u8, 0x01_u8,
      0x01_u8, 0x6b_u8, 0x01_u8, 0x00_u8, 0x00_u8,
    ]
    prefix_wire = Bytes[
      0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x02_u8, 0x01_u8,
      0x30_u8, 0x00_u8, 0x13_u8, 0x04_u8, 0x01_u8,
      0x01_u8, 0x6b_u8, 0x01_u8, 0x00_u8, 0x00_u8,
    ]
    full_wire = Bytes[
      0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x02_u8, 0x01_u8,
      0x30_u8, 0x00_u8, 0x13_u8, 0x04_u8, 0x01_u8,
      0x01_u8, 0x6b_u8, 0x01_u8, 0x00_u8, 0x00_u8,
      0x01_u8, 0x05_u8, 0x07_u8, 0x0b_u8, 0x00_u8,
    ]

    CrystalClick::BinaryDataTypeCodec.encode(json).should eq(json_descriptor)
    structure.canonical_variant_names.should eq([
      "JSON(max_dynamic_types=4, max_dynamic_paths=19, k UInt8)",
      "SharedVariant",
      "UInt8",
    ] of String)
    structure.canonical_index_for(json).should eq(0)
    structure.shared_index.should eq(1)
    structure.canonical_index_for(uint8).should eq(2)
    structure.statistics.not_nil!.counts.should eq([5_u64, 7_u64, 11_u64])

    # Full metadata bytes include the canonical positional counts, not counts
    # in the caller's unsorted actual-roster order.
    CrystalClick::DynamicStructureCodec.encode(
      structure,
      w206_metadata_limits(full_wire.size),
    ).should eq(full_wire)
    decoded = CrystalClick::DynamicStructureCodec.decode(
      full_wire,
      w206_metadata_limits(full_wire.size),
    )
    decoded.types.should eq([uint8, json] of CrystalClick::BinaryDataType)
    decoded.type_at(1).should eq(json) # caps and typed-path descriptor are exact
    decoded.statistics.should eq(statistics)
    decoded.canonical_variant_names.should eq(structure.canonical_variant_names)

    # Prefix codecs omit the statistics flag and payload, while retaining the
    # same descriptor bytes and roster identity.
    CrystalClick::DynamicStructureCodec.encode_prefix_without_statistics(
      structure,
      w206_metadata_limits(prefix_wire.size),
    ).should eq(prefix_wire)
    prefix_decoded = CrystalClick::DynamicStructureCodec.decode_prefix_without_statistics(
      prefix_wire,
      w206_metadata_limits(prefix_wire.size),
    )
    prefix_decoded.types.should eq([uint8, json] of CrystalClick::BinaryDataType)
    prefix_decoded.statistics.should be_nil

    # The paired Object/Dynamic metadata owner carries the same JSON descriptor
    # and reports the independently known first-statistics-byte offset.
    set = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["p"] of String),
      {"p" => structure},
    )
    paired = CrystalClick::ObjectDynamicStructureCodec.encode(set)
    paired.borrowed_dynamic("p").should eq(full_wire)
    paired.dynamic_statistics_offset("p").should eq(prefix_wire.size)
    paired_decoded = CrystalClick::ObjectDynamicStructureCodec.decode(paired)
    paired_decoded.dynamic_for("p").should eq(structure)
    paired_decoded.dynamic_for("p").type_at(1).should eq(json)
  end

  it "keeps exact and one-short descriptor-byte boundaries for full and prefix metadata" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    json = w206_json_metadata_type
    structure = CrystalClick::DynamicStructure.new(
      [uint8, json] of CrystalClick::BinaryDataType,
      CrystalClick::StructureStatistics.new(
        [5_u64, 7_u64, 11_u64],
        [] of CrystalClick::StructureStatistic,
      ),
    )
    prefix_wire = Bytes[
      0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x02_u8, 0x01_u8,
      0x30_u8, 0x00_u8, 0x13_u8, 0x04_u8, 0x01_u8,
      0x01_u8, 0x6b_u8, 0x01_u8, 0x00_u8, 0x00_u8,
    ]
    full_wire = Bytes[
      0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x02_u8, 0x01_u8,
      0x30_u8, 0x00_u8, 0x13_u8, 0x04_u8, 0x01_u8,
      0x01_u8, 0x6b_u8, 0x01_u8, 0x00_u8, 0x00_u8,
      0x01_u8, 0x05_u8, 0x07_u8, 0x0b_u8, 0x00_u8,
    ]

    CrystalClick::DynamicStructureCodec.encode(structure, w206_metadata_limits(full_wire.size)).should eq(full_wire)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::DynamicStructureCodec.encode(structure, w206_metadata_limits(full_wire.size - 1))
    end
    CrystalClick::DynamicStructureCodec.decode(full_wire, w206_metadata_limits(full_wire.size)).should eq(structure)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicStructureCodec.decode(full_wire, w206_metadata_limits(full_wire.size - 1))
    end

    CrystalClick::DynamicStructureCodec.encode_prefix_without_statistics(
      structure,
      w206_metadata_limits(prefix_wire.size),
    ).should eq(prefix_wire)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::DynamicStructureCodec.encode_prefix_without_statistics(
        structure,
        w206_metadata_limits(prefix_wire.size - 1),
      )
    end
  end

  it "charges bounded display-name work for a JSON descriptor at the exact and one-short budget" do
    json = w206_json_metadata_type
    # Conservative output and temporary bounds for
    # JSON(max_dynamic_types=4, max_dynamic_paths=19, k UInt8). These are
    # preflight bounds, not the rendered name's actual String#bytesize.
    name_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
    CrystalClick::BinaryTypeNameBudget.measure(json, name_budget).should eq({67_u64, 169_u64})

    prefix_wire = Bytes[
      0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x01_u8,
      0x30_u8, 0x00_u8, 0x13_u8, 0x04_u8, 0x01_u8,
      0x01_u8, 0x6b_u8, 0x01_u8, 0x00_u8, 0x00_u8,
    ]
    # One JSON descriptor is name-preflighted twice at the 67 + 169 byte
    # conservative bound per pass, in addition to its 19 input bytes.
    exact_limits = CrystalClick::BinaryCodecLimits.new(
      max_depth: 2,
      max_nodes: 32,
      max_elements: 32,
      max_bytes: prefix_wire.size + 2 * (67 + 169),
    )
    exact_context = CrystalClick::BinaryCodecContext.new(exact_limits, prefix_wire)
    parsed = CrystalClick::DynamicStructureCodec.read_prefix_without_statistics(
      exact_context,
      1,
      1,
      true,
    )
    exact_context.ensure_consumed
    parsed.type_at(0).should eq(json)

    short_limits = CrystalClick::BinaryCodecLimits.new(
      max_depth: 2,
      max_nodes: 32,
      max_elements: 32,
      max_bytes: prefix_wire.size + 2 * (67 + 169) - 1,
    )
    short_context = CrystalClick::BinaryCodecContext.new(short_limits, prefix_wire)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicStructureCodec.read_prefix_without_statistics(
        short_context,
        1,
        1,
        true,
      )
    end
  end

  it "continues to reject JSON hidden under Array and Tuple actual descriptors" do
    json = w206_json_metadata_type
    wrapped_types = [
      CrystalClick::BinaryDataType.array(json),
      CrystalClick::BinaryDataType.tuple([json] of CrystalClick::BinaryDataType),
    ] of CrystalClick::BinaryDataType

    wrapped_types.each do |wrapped|
      error = expect_raises(ArgumentError) do
        CrystalClick::DynamicStructure.new([wrapped] of CrystalClick::BinaryDataType)
      end
      error.message.to_s.should contain("JSON")
    end

    # Raw Dynamic prefixes: version 4, one actual, then Array(JSON) or a
    # one-field Tuple(JSON). These fixtures do not use the descriptor writer.
    wrapped_prefixes = [
      Bytes[
        0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
        0x01_u8, 0x1e_u8,
        0x30_u8, 0x00_u8, 0x13_u8, 0x04_u8, 0x01_u8,
        0x01_u8, 0x6b_u8, 0x01_u8, 0x00_u8, 0x00_u8,
      ],
      Bytes[
        0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
        0x01_u8, 0x1f_u8, 0x01_u8,
        0x30_u8, 0x00_u8, 0x13_u8, 0x04_u8, 0x01_u8,
        0x01_u8, 0x6b_u8, 0x01_u8, 0x00_u8, 0x00_u8,
      ],
    ] of Bytes
    wrapped_prefixes.each do |wire|
      error = expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::DynamicStructureCodec.decode_prefix_without_statistics(wire)
      end
      error.message.to_s.should contain("JSON")
    end
  end

  it "counts the typed JSON child against the descriptor depth limit" do
    json = w206_json_metadata_type
    shallow_limits = CrystalClick::BinaryCodecLimits.new(
      max_depth: 1,
      max_nodes: 64,
      max_elements: 64,
      max_bytes: 1_024,
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.encode(json, shallow_limits)
    end
    json_wire = Bytes[
      0x30_u8, 0x00_u8, 0x13_u8, 0x04_u8, 0x01_u8,
      0x01_u8, 0x6b_u8, 0x01_u8, 0x00_u8, 0x00_u8,
    ]
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(json_wire, shallow_limits)
    end
  end
end
