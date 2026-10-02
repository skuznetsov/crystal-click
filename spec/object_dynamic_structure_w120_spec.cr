require "./spec_helper"

private def w120_limits(
  max_depth : Int = 64,
  max_nodes : Int = 4_096,
  max_elements : Int = 1_000_000,
  max_bytes : Int = 64 * 1024 * 1024,
) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: max_depth,
    max_nodes: max_nodes,
    max_elements: max_elements,
    max_bytes: max_bytes
  )
end

private def w120_var_uint(value : UInt64) : Bytes
  bytes = [] of UInt8
  remaining = value
  loop do
    payload = (remaining & 0x7f_u64).to_u8
    remaining >>= 7
    bytes << (remaining == 0_u64 ? payload : payload | 0x80_u8)
    break if remaining == 0_u64
  end
  Bytes.new(bytes.size) { |index| bytes[index] }
end

private def w120_u64_le(value : UInt64) : Bytes
  Bytes.new(8) { |index| ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w120_string(value : String) : Bytes
  w120_concat(w120_var_uint(value.bytesize.to_u64), value.to_slice)
end

private def w120_concat(first : Bytes, *rest : Bytes) : Bytes
  parts = [first] of Bytes
  rest.each { |part| parts << part }
  size = parts.sum(&.size)
  flattened = [] of UInt8
  parts.each { |part| part.each { |byte| flattened << byte } }
  Bytes.new(size) { |index| flattened[index] }
end

private def w120_object_nodes(bytes : Bytes) : Int32
  0.upto(32) do |nodes|
    begin
      CrystalClick::ObjectStructureCodec.decode(
        bytes,
        w120_limits(max_nodes: nodes, max_elements: 10_000, max_bytes: bytes.size)
      )
      return nodes
    rescue ex : CrystalClick::CorruptPartError
    end
  end
  raise "W120 Object node threshold exceeded test search bound"
end

private def w120_dynamic_nodes(bytes : Bytes) : Int32
  0.upto(32) do |nodes|
    begin
      CrystalClick::DynamicStructureCodec.decode(
        bytes,
        w120_limits(max_nodes: nodes, max_elements: 10_000, max_bytes: bytes.size)
      )
      return nodes
    rescue ex : CrystalClick::CorruptPartError
    end
  end
  raise "W120 Dynamic node threshold exceeded test search bound"
end

private def w120_object_elements(bytes : Bytes) : Int32
  0.upto(32) do |elements|
    begin
      CrystalClick::ObjectStructureCodec.decode(
        bytes,
        w120_limits(max_nodes: 10_000, max_elements: elements, max_bytes: bytes.size)
      )
      return elements
    rescue ex : CrystalClick::CorruptPartError
    end
  end
  raise "W120 Object element threshold exceeded test search bound"
end

private def w120_dynamic_elements(bytes : Bytes) : Int32
  0.upto(32) do |elements|
    begin
      CrystalClick::DynamicStructureCodec.decode(
        bytes,
        w120_limits(max_nodes: 10_000, max_elements: elements, max_bytes: bytes.size)
      )
      return elements
    rescue ex : CrystalClick::CorruptPartError
    end
  end
  raise "W120 Dynamic element threshold exceeded test search bound"
end

describe "W120 paired Object and Dynamic structure metadata" do
  it "decodes unsorted Object V1 paths with their positional counts, then canonicalizes zipped pairs" do
    # V1: UInt64LE(0), legacy field 7, paths [z, a], path counts [20, 10],
    # shared statistics [(z, 30), (a, 40)]. All values are authored literals.
    unsorted = Bytes[
      0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x07_u8, 0x02_u8, 0x01_u8, 0x7a_u8, 0x01_u8, 0x61_u8,
      0x14_u8, 0x0a_u8, 0x02_u8, 0x01_u8, 0x7a_u8, 0x1e_u8,
      0x01_u8, 0x61_u8, 0x28_u8,
    ]
    decoded = CrystalClick::ObjectStructureCodec.decode(unsorted)
    decoded.dynamic_paths.should eq(["z", "a"] of String)
    decoded.legacy_max_dynamic_paths.should eq(7_u64)
    decoded.statistics.not_nil!.counts.should eq([20_u64, 10_u64])
    decoded.statistics.not_nil!.shared.map { |entry| {entry.name, entry.count} }.should eq([
      {"z", 30_u64}, {"a", 40_u64},
    ])

    # The encoder sorts path/count pairs together and sorts shared map entries.
    canonical = Bytes[
      0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x07_u8, 0x02_u8, 0x01_u8, 0x61_u8, 0x01_u8, 0x7a_u8,
      0x0a_u8, 0x14_u8, 0x02_u8, 0x01_u8, 0x61_u8, 0x28_u8,
      0x01_u8, 0x7a_u8, 0x1e_u8,
    ]
    CrystalClick::ObjectStructureCodec.encode(decoded).should eq(canonical)
    CrystalClick::ObjectStructureCodec.decode(canonical).dynamic_paths.should eq(["a", "z"] of String)
  end

  it "requires legacy Object statistics in V1 and V2 but distinguishes optional V3 statistics" do
    empty_stats = CrystalClick::StructureStatistics.new(
      [] of UInt64,
      [] of CrystalClick::StructureStatistic
    )

    v1_absent = Bytes[
      0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x00_u8, 0x00_u8,
    ]
    v1_present_zero = Bytes[
      0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x00_u8, 0x00_u8, 0x00_u8,
    ]
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectStructureCodec.decode(v1_absent)
    end
    v1_zero = CrystalClick::ObjectStructureCodec.decode(v1_present_zero)
    v1_zero.statistics.not_nil!.counts.should be_empty
    v1_zero.statistics.not_nil!.shared.should be_empty

    # V2 has no presence flag. For the complete-blob profile, its count vector
    # and shared map are mandatory, so EOF after the roster is truncation.
    v2_absent = Bytes[
      0x02_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x01_u8, 0x01_u8, 0x70_u8,
    ]
    v2_present_zero = Bytes[
      0x02_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x01_u8, 0x01_u8, 0x70_u8, 0x00_u8, 0x00_u8,
    ]
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectStructureCodec.decode(v2_absent)
    end
    v2_zero = CrystalClick::ObjectStructureCodec.decode(v2_present_zero)
    v2_zero.statistics.not_nil!.counts.should eq([0_u64])
    v2_zero.statistics.not_nil!.shared.should be_empty

    v3_absent = Bytes[
      0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x00_u8, 0x00_u8, 0x00_u8,
    ]
    v3_present_zero = Bytes[
      0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x00_u8, 0x00_u8, 0x01_u8, 0x00_u8,
    ]
    decoded_v3_absent = CrystalClick::ObjectStructureCodec.decode(v3_absent)
    decoded_v3_zero = CrystalClick::ObjectStructureCodec.decode(v3_present_zero)
    decoded_v3_absent.statistics.should be_nil
    decoded_v3_zero.statistics.not_nil!.counts.should be_empty
    decoded_v3_zero.statistics.not_nil!.shared.should be_empty

    object_v1 = CrystalClick::ObjectStructure.new(
      [] of String,
      version: 0_u64,
      legacy_max_dynamic_paths: 0_u64,
      statistics: empty_stats
    )
    object_v2_zero = CrystalClick::ObjectStructure.new(
      ["p"] of String,
      version: 2_u64,
      statistics: CrystalClick::StructureStatistics.new([0_u64], [] of CrystalClick::StructureStatistic)
    )
    object_v3_absent = CrystalClick::ObjectStructure.new([] of String)
    object_v3_zero = CrystalClick::ObjectStructure.new([] of String, statistics: empty_stats)

    CrystalClick::ObjectStructureCodec.encode(object_v1).should eq(v1_present_zero)
    expect_raises(ArgumentError) do
      CrystalClick::ObjectStructure.new(
        [] of String,
        version: 0_u64,
        legacy_max_dynamic_paths: 0_u64
      )
    end
    expect_raises(ArgumentError) do
      CrystalClick::ObjectStructure.new(
        [] of String,
        version: 2_u64
      )
    end
    CrystalClick::ObjectStructureCodec.encode(object_v2_zero).should eq(v2_present_zero)
    CrystalClick::ObjectStructureCodec.encode(object_v3_absent).should eq(v3_absent)
    CrystalClick::ObjectStructureCodec.encode(object_v3_zero).should eq(v3_present_zero)
  end

  it "round-trips Object V3 mode and bucket metadata without admitting bucket layouts" do
    cases = [
      {0_u64, 1_u64, Bytes[0x00_u8]},
      {1_u64, 1_u64, Bytes[0x01_u8, 0x01_u8]},
      {2_u64, 256_u64, Bytes[0x02_u8, 0x80_u8, 0x02_u8]},
      {3_u64, 7_u64, Bytes[0x03_u8, 0x07_u8]},
    ] of Tuple(UInt64, UInt64, Bytes)

    cases.each do |mode, buckets, mode_wire|
      model = CrystalClick::ObjectStructure.new(
        [] of String,
        shared_data_version: mode,
        bucket_count: buckets
      )
      # The independent header has an empty roster and statistics flag=0.
      expected = w120_concat(
        Bytes[0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8],
        Bytes[0x00_u8],
        mode_wire,
        Bytes[0x00_u8]
      )
      CrystalClick::ObjectStructureCodec.encode(model).should eq(expected)
      CrystalClick::ObjectStructureCodec.decode(expected).should eq(model)
    end

    expect_raises(ArgumentError) do
      CrystalClick::ObjectStructure.new([] of String, shared_data_version: 4_u64)
    end
    expect_raises(ArgumentError) do
      CrystalClick::ObjectStructure.new([] of String, shared_data_version: 1_u64, bucket_count: 0_u64)
    end
    expect_raises(ArgumentError) do
      CrystalClick::ObjectStructure.new([] of String, shared_data_version: 3_u64, bucket_count: 257_u64)
    end

    [0_u8, 0x80_u8, 0x81_u8].each do |invalid_buckets|
      malformed = w120_concat(
        Bytes[0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8],
        Bytes[0x00_u8, 0x01_u8, invalid_buckets, 0x00_u8]
      )
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::ObjectStructureCodec.decode(malformed)
      end
    end
  end

  it "preserves Dynamic V3 descriptors while indexing counts by canonical SQL names" do
    # Wire descriptor order is UInt8 then String. Statistics are instead in
    # canonical SQL-name order: SharedVariant, String, UInt8.
    wire = Bytes[
      0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x02_u8, 0x01_u8, 0x15_u8, 0x01_u8,
      0x1e_u8, 0x0a_u8, 0x14_u8,
      0x02_u8, 0x01_u8, 0x61_u8, 0x05_u8,
      0x01_u8, 0x7a_u8, 0x03_u8,
    ]
    decoded = CrystalClick::DynamicStructureCodec.decode(wire)
    decoded.types.should eq([
      CrystalClick::BinaryDataType.primitive("UInt8"),
      CrystalClick::BinaryDataType.primitive("String"),
    ] of CrystalClick::BinaryDataType)
    decoded.canonical_variant_names.should eq(["SharedVariant", "String", "UInt8"] of String)
    decoded.shared_index.should eq(0)
    decoded.statistics.not_nil!.counts.should eq([30_u64, 10_u64, 20_u64])
    decoded.statistics.not_nil!.shared.map { |entry| {entry.name, entry.count} }.should eq([
      {"a", 5_u64}, {"z", 3_u64},
    ])
    CrystalClick::DynamicStructureCodec.encode(decoded).should eq(wire)

    absent = Bytes[
      0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x00_u8, 0x00_u8,
    ]
    present_zero = Bytes[
      0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x00_u8, 0x01_u8, 0x00_u8, 0x00_u8,
    ]
    CrystalClick::DynamicStructureCodec.decode(absent).statistics.should be_nil
    zero_stats = CrystalClick::DynamicStructureCodec.decode(present_zero).statistics.not_nil!
    zero_stats.counts.should eq([0_u64]) # implicit SharedVariant is still present
    zero_stats.shared.should be_empty
  end

  it "keeps recursive nominal descriptors and rejects profile aliases" do
    enum_type = CrystalClick::BinaryDataType.enum8([
      {"ok", 1_i16},
    ] of CrystalClick::BinaryEnumDefinition::Entry)
    recursive = CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.nullable(enum_type))
    recursive_wire = Bytes[
      0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x01_u8, 0x1e_u8, 0x23_u8, 0x17_u8, 0x01_u8, 0x02_u8, 0x6f_u8, 0x6b_u8, 0x01_u8,
      0x00_u8,
    ]
    model = CrystalClick::DynamicStructure.new([recursive] of CrystalClick::BinaryDataType)
    CrystalClick::DynamicStructureCodec.encode(model).should eq(recursive_wire)
    CrystalClick::DynamicStructureCodec.decode(recursive_wire).types.should eq([recursive])

    decimal32 = CrystalClick::BinaryDataType.decimal(32, 5, 2)
    decimal64 = CrystalClick::BinaryDataType.decimal(64, 5, 2)
    decimal32.name.should eq(decimal64.name)
    expect_raises(ArgumentError) do
      CrystalClick::DynamicStructure.new([decimal32, decimal64] of CrystalClick::BinaryDataType)
    end

    # The tags preserve width on the wire, but this strict roster profile
    # rejects the display-name collision instead of silently collapsing it.
    collision_wire = Bytes[
      0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x02_u8, 0x19_u8, 0x05_u8, 0x02_u8, 0x1a_u8, 0x05_u8, 0x02_u8, 0x00_u8,
    ]
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicStructureCodec.decode(collision_wire)
    end

    expect_raises(ArgumentError) do
      CrystalClick::DynamicStructure.new([CrystalClick::BinaryDataType.primitive("Nothing")] of CrystalClick::BinaryDataType)
    end
    expect_raises(ArgumentError) do
      CrystalClick::DynamicStructure.new([
        CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.primitive("UInt8")),
      ] of CrystalClick::BinaryDataType)
    end
    [
      Bytes[0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x01_u8, 0x00_u8],
      Bytes[0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x01_u8, 0x23_u8, 0x01_u8, 0x00_u8],
    ].each do |unadmitted|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::DynamicStructureCodec.decode(unadmitted)
      end
    end
  end

  it "bounds the Dynamic type domain and validates exact trailers and versions" do
    too_many_types = Bytes.new(8 + 1 + 255 + 1, 0_u8)
    too_many_types[0] = 0x04_u8
    too_many_types[8] = 0xff_u8
    255.times { |index| too_many_types[9 + index] = 0x01_u8 }
    too_many_types[264] = 0x00_u8
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicStructureCodec.decode(too_many_types)
    end
    expect_raises(ArgumentError) do
      CrystalClick::DynamicStructure.new(Array.new(255) { CrystalClick::BinaryDataType.primitive("UInt8") })
    end

    valid_dynamic = Bytes[
      0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x00_u8, 0x00_u8,
    ]
    (0...valid_dynamic.size).each do |length|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::DynamicStructureCodec.decode(valid_dynamic[0, length])
      end
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicStructureCodec.decode(w120_concat(valid_dynamic, Bytes[0x00_u8]))
    end

    {1_u64, 2_u64}.each do |old_part_version|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::DynamicStructureCodec.decode(w120_u64_le(old_part_version))
      end
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicStructureCodec.decode(w120_u64_le(3_u64)) # Native-only FLATTENED
    end

    {1_u64, 3_u64}.each do |native_object_version|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::ObjectStructureCodec.decode(w120_u64_le(native_object_version))
      end
    end

    invalid_flag = Bytes[
      0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x00_u8, 0x02_u8,
    ]
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicStructureCodec.decode(invalid_flag)
    end
  end

  it "rejects duplicate, truncated, and trailing Object metadata as corruption" do
    duplicate_paths = Bytes[
      0x02_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x02_u8, 0x01_u8, 0x70_u8, 0x01_u8, 0x70_u8,
    ]
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectStructureCodec.decode(duplicate_paths)
    end

    partial_v2_statistics = Bytes[
      0x02_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x01_u8, 0x01_u8, 0x70_u8, 0x05_u8,
    ] # path count exists, but the shared map size is missing
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectStructureCodec.decode(partial_v2_statistics)
    end

    v3_flag_zero_with_trailer = Bytes[
      0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    ]
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectStructureCodec.decode(v3_flag_zero_with_trailer)
    end

    v3_missing_flag = Bytes[
      0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x00_u8, 0x00_u8,
    ]
    # The final byte of a valid V3 no-stat stream is its explicit zero flag.
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectStructureCodec.decode(v3_missing_flag)
    end

    trailing_v1 = Bytes[
      0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x00_u8, 0x00_u8, 0x00_u8, 0xff_u8,
    ]
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectStructureCodec.decode(trailing_v1)
    end
  end

  it "preserves opaque raw statistic names and owns every mutable boundary" do
    raw_names = [
      String.new(Bytes[0xff_u8]),
      String.new(Bytes[0x00_u8]),
      String.new(Bytes.empty),
    ] of String
    shared = [
      CrystalClick::StructureStatistic.new(raw_names[0], 9_u64),
      CrystalClick::StructureStatistic.new(raw_names[1], 7_u64),
      CrystalClick::StructureStatistic.new(raw_names[2], 5_u64),
    ] of CrystalClick::StructureStatistic
    stats = CrystalClick::StructureStatistics.new([] of UInt64, shared)
    object = CrystalClick::ObjectStructure.new([] of String, statistics: stats)
    encoded = CrystalClick::ObjectStructureCodec.encode(object)
    # V3: empty roster, MAP, statistics-present, zero type counts, then
    # byte-sorted shared names: empty, NUL, and 0xff (all opaque raw bytes).
    expected = Bytes[
      0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x00_u8, 0x00_u8, 0x01_u8, 0x03_u8,
      0x00_u8, 0x05_u8,
      0x01_u8, 0x00_u8, 0x07_u8,
      0x01_u8, 0xff_u8, 0x09_u8,
    ]
    encoded.should eq(expected)
    decoded_names = CrystalClick::ObjectStructureCodec.decode(expected).statistics.not_nil!.shared
    decoded_names.map { |entry| entry.name.to_slice }.should eq([
      Bytes.empty, Bytes[0x00_u8], Bytes[0xff_u8],
    ])

    mutable_path = String.new(Bytes[0x70_u8])
    paths = [mutable_path] of String
    source_key = String.new(Bytes[0x70_u8])
    dynamic = CrystalClick::DynamicStructure.new([
      CrystalClick::BinaryDataType.primitive("UInt8"),
    ] of CrystalClick::BinaryDataType)
    dynamics = {source_key => dynamic}
    set_object = CrystalClick::ObjectStructure.new(paths)
    set = CrystalClick::ObjectDynamicStructureSet.new(set_object, dynamics)

    mutable_path.to_unsafe[0] = 0x78_u8
    source_key.to_unsafe[0] = 0x78_u8
    paths.clear
    dynamics.clear
    set.object.dynamic_paths.should eq(["p"] of String)
    returned_set_dynamics = set.dynamics
    returned_set_key = returned_set_dynamics.keys.first
    returned_set_key.to_unsafe[0] = 0x78_u8
    returned_set_dynamics.clear
    set.dynamics.keys.should eq(["p"] of String)

    fetched_paths = set.object.dynamic_paths
    fetched_paths[0].to_unsafe[0] = 0x78_u8
    set.object.dynamic_paths.should eq(["p"] of String)

    # Dynamic type and display-name accessors return detached arrays/strings.
    caller_types = [CrystalClick::BinaryDataType.primitive("UInt8")] of CrystalClick::BinaryDataType
    dynamic_owner = CrystalClick::DynamicStructure.new(caller_types)
    caller_types.clear
    dynamic_owner.type_count.should eq(1)
    returned_types = dynamic_owner.types
    returned_types.clear
    dynamic_owner.type_count.should eq(1)
    returned_variant_names = dynamic_owner.canonical_variant_names
    returned_variant_names[0].to_unsafe[0] = 0x78_u8
    returned_variant_names.clear
    dynamic_owner.canonical_variant_names.should eq(["SharedVariant", "UInt8"] of String)

    source_object_bytes = Bytes[0x01_u8, 0x02_u8]
    source_dynamic_bytes = Bytes[0x03_u8]
    source_stream_key = String.new(Bytes[0x70_u8])
    source_stream_map = {source_stream_key => source_dynamic_bytes}
    streams = CrystalClick::ObjectDynamicStructureStreams.new(source_object_bytes, source_stream_map)
    source_object_bytes[0] = 0xff_u8
    source_dynamic_bytes[0] = 0xff_u8
    source_stream_key.to_unsafe[0] = 0x78_u8
    source_stream_map.clear
    streams.object.should eq(Bytes[0x01_u8, 0x02_u8])
    streams.dynamics["p"].should eq(Bytes[0x03_u8])

    returned_object = streams.object
    returned_dynamic = streams.dynamics
    returned_object[0] = 0xee_u8
    returned_dynamic["p"][0] = 0xee_u8
    streams.object.should eq(Bytes[0x01_u8, 0x02_u8])
    streams.dynamics["p"].should eq(Bytes[0x03_u8])
    returned_streams = streams.dynamics
    returned_stream_key = returned_streams.keys.first
    returned_stream_key.to_unsafe[0] = 0x78_u8
    returned_streams.clear
    streams.dynamics.keys.should eq(["p"] of String)

    # Shared statistics owners copy caller arrays and nested String bytes.
    mutable_stat_name = String.new(Bytes[0x61_u8])
    mutable_shared = [CrystalClick::StructureStatistic.new(mutable_stat_name, 4_u64)] of CrystalClick::StructureStatistic
    mutable_counts = [12_u64]
    detached_stats = CrystalClick::StructureStatistics.new(mutable_counts, mutable_shared)
    mutable_stat_name.to_unsafe[0] = 0x78_u8
    mutable_shared.clear
    mutable_counts[0] = 99_u64
    detached_stats.shared[0].name.should eq("a")
    detached_stats.counts.should eq([12_u64])

    returned_counts = detached_stats.counts
    returned_counts[0] = 88_u64
    returned_counts.clear
    detached_stats.counts.should eq([12_u64])

    returned_shared = detached_stats.shared
    returned_name = detached_stats.shared[0].name
    returned_name.to_unsafe[0] = 0x78_u8
    returned_shared.clear
    detached_stats.shared[0].name.should eq("a")

    duplicate_shared = [
      CrystalClick::StructureStatistic.new("same", 1_u64),
      CrystalClick::StructureStatistic.new("same", 2_u64),
    ] of CrystalClick::StructureStatistic
    expect_raises(ArgumentError) do
      CrystalClick::StructureStatistics.new([] of UInt64, duplicate_shared)
    end
  end

  it "rejects declared collection counts before allocation using domain, budgets, and minimum wire" do
    # The Object roster advertises 65,536 paths but carries none of their
    # required length bytes. Generous node/element limits isolate min-wire.
    path_count = w120_var_uint(65_536_u64)
    no_paths = w120_concat(
      Bytes[0x02_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8],
      path_count
    )
    path_limits = w120_limits(max_nodes: 100_000, max_elements: 100_000, max_bytes: no_paths.size)
    GC.stats
    before_paths = GC.stats.total_bytes
    path_wire_error = expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectStructureCodec.decode(no_paths, path_limits)
    end
    path_wire_error.message.not_nil!.should contain("declared metadata count")
    (GC.stats.total_bytes - before_paths).should be < 128_u64 * 1024_u64

    # Dynamic V3 has at most 254 ordinary types; no descriptor allocation is
    # allowed for a count outside that fixed domain.
    invalid_type_domain = w120_concat(w120_u64_le(4_u64), Bytes[0xff_u8, 0x01_u8])
    domain_error = expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicStructureCodec.decode(
        invalid_type_domain,
        w120_limits(max_nodes: 10_000, max_elements: 10_000, max_bytes: invalid_type_domain.size)
      )
    end
    domain_error.message.not_nil!.should contain("supported")

    # A shared-statistics map count needs at least an empty-name length and a
    # count VarUInt per item. The minimum body must be proven before allocation.
    shared_count = w120_var_uint(65_536_u64)
    no_shared_entries = w120_concat(
      Bytes[
        0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
        0x00_u8, 0x00_u8, 0x01_u8,
      ],
      shared_count
    )
    GC.stats
    before_stats = GC.stats.total_bytes
    shared_wire_error = expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectStructureCodec.decode(
        no_shared_entries,
        w120_limits(max_nodes: 100_000, max_elements: 100_000, max_bytes: no_shared_entries.size)
      )
    end
    shared_wire_error.message.not_nil!.should contain("declared metadata count")
    (GC.stats.total_bytes - before_stats).should be < 128_u64 * 1024_u64
  end

  it "uses one aggregate byte/node/element budget across Object and every Dynamic child" do
    object = CrystalClick::ObjectStructure.new(["p"] of String)
    dynamic = CrystalClick::DynamicStructure.new([
      CrystalClick::BinaryDataType.primitive("UInt8"),
    ] of CrystalClick::BinaryDataType)
    set = CrystalClick::ObjectDynamicStructureSet.new(object, {"p" => dynamic})

    expected_object = Bytes[
      0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x01_u8, 0x01_u8, 0x70_u8, 0x00_u8, 0x00_u8,
    ]
    expected_dynamic = Bytes[
      0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x01_u8, 0x01_u8, 0x00_u8,
    ]
    streams = CrystalClick::ObjectDynamicStructureCodec.encode(set)
    streams.object.should eq(expected_object)
    streams.dynamics["p"].should eq(expected_dynamic)

    input_bytes = expected_object.size + expected_dynamic.size
    object_nodes = w120_object_nodes(expected_object)
    dynamic_nodes = w120_dynamic_nodes(expected_dynamic)
    object_elements = w120_object_elements(expected_object)
    dynamic_elements = w120_dynamic_elements(expected_dynamic)
    exact_nodes = object_nodes + dynamic_nodes
    exact_elements = object_elements + dynamic_elements
    exact_bytes = input_bytes
    exact = w120_limits(
      max_nodes: exact_nodes,
      max_elements: exact_elements,
      max_bytes: exact_bytes
    )

    # Each child fits by itself at the same total limit; only the paired batch
    # proves that counts and bytes are accumulated instead of reset per child.
    CrystalClick::ObjectStructureCodec.decode(expected_object, exact).should eq(object)
    CrystalClick::DynamicStructureCodec.decode(expected_dynamic, exact).should eq(dynamic)
    decoded = CrystalClick::ObjectDynamicStructureCodec.decode(streams, exact)
    decoded.object.should eq(object)
    decoded.dynamics["p"].should eq(dynamic)

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectDynamicStructureCodec.decode(
        streams,
        w120_limits(max_nodes: exact_nodes - 1, max_elements: exact_elements, max_bytes: exact_bytes)
      )
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectDynamicStructureCodec.decode(
        streams,
        w120_limits(max_nodes: exact_nodes, max_elements: exact_elements - 1, max_bytes: exact_bytes)
      )
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectDynamicStructureCodec.decode(
        streams,
        w120_limits(max_nodes: exact_nodes, max_elements: exact_elements, max_bytes: exact_bytes - 1)
      )
    end

    # A Hash may not silently omit a child or carry an extra path.
    expect_raises(ArgumentError) do
      CrystalClick::ObjectDynamicStructureSet.new(object, {"other" => dynamic})
    end
    mismatched_streams = CrystalClick::ObjectDynamicStructureStreams.new(
      expected_object,
      {"other" => expected_dynamic}
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectDynamicStructureCodec.decode(mismatched_streams)
    end
  end
end
