require "./spec_helper"

private def w155_value_u64(value : UInt64) : Bytes
  Bytes.new(8) do |index|
    ((value >> (index * 8)) & 0xff_u64).to_u8
  end
end

private def w155_value_concat(parts : Array(Bytes)) : Bytes
  bytes = [] of UInt8
  parts.each { |part| part.each { |byte| bytes << byte } }
  Bytes.new(bytes.size) { |index| bytes[index] }
end

private def w155_value_limits(
  max_depth : Int = 64,
  max_nodes : Int = 100_000,
  max_elements : Int = 300_000,
  max_bytes : Int = 64 * 1024 * 1024,
) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: max_depth,
    max_nodes: max_nodes,
    max_elements: max_elements,
    max_bytes: max_bytes,
  )
end

private def w155_value_paired_streams(
  structures : Hash(String, Bytes),
  mark_count : Int,
  lanes : Hash(String, CrystalClick::BinaryBulkStream),
) : CrystalClick::BinaryDynamicBulkStreams
  CrystalClick::BinaryDynamicBulkStreams.new(
    CrystalClick::BinaryDynamicStructureStreams.new(structures),
    CrystalClick::BinaryBulkStreams.new(mark_count, lanes),
  )
end

private def w155_value_empty_structure : Bytes
  # Dynamic V3, zero ordinary arms, no statistics. SharedVariant is implicit.
  Bytes[0x04_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8]
end

private def w155_value_string_structure : Bytes
  # Dynamic V3, one ordinary String arm, no statistics.
  Bytes[0x04_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 1_u8, 0x15_u8, 0_u8]
end

describe "W155 paired normalized Dynamic bulk values" do
  it "keeps SharedVariant and ordinary String lanes distinct under both String profiles" do
    # This is a stored-roster fixture: W154 intentionally keeps nominal cap
    # independent from occurrence metadata; it is not an insertion fixture.
    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    string_type = CrystalClick::BinaryDataType.primitive("String")
    structure = CrystalClick::DynamicStructure.new([string_type] of CrystalClick::BinaryDataType)
    structures = {"root" => structure}

    granules = [
      [CrystalClick::BinaryValue.dynamic(dynamic_type, CrystalClick::BinaryValue.bool(true))] of CrystalClick::BinaryValue,
      [CrystalClick::BinaryValue.dynamic(dynamic_type, CrystalClick::BinaryValue.string("x"))] of CrystalClick::BinaryValue,
      [CrystalClick::BinaryValue.dynamic(dynamic_type)] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)

    encoded = CrystalClick::BinaryDynamicBulkCodec.encode(dynamic_type, structures, granules)
    encoded.structures.site_paths.should eq(["root"] of String)
    encoded.structures.structure_bytes_for("root").should eq(Bytes[
      0x04_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 1_u8, 0x15_u8, 0_u8,
    ])
    encoded.data.roles.should eq([
      "root.arm.0.data",
      "root.arm.1.data",
      "root.discriminators",
    ] of String)
    encoded.data.stream("root.discriminators").bytes.should eq(Bytes[0x00_u8, 0x01_u8, 0xff_u8])
    encoded.data.stream("root.discriminators").offsets.should eq([0_u64, 1_u64, 2_u64, 3_u64])
    # Bool's complete typed envelope is [Bool-tag, true], framed as String.
    encoded.data.stream("root.arm.0.data").bytes.should eq(Bytes[0x02_u8, 0x2d_u8, 0x01_u8])
    encoded.data.stream("root.arm.0.data").offsets.should eq([0_u64, 3_u64, 3_u64, 3_u64])
    encoded.data.stream("root.arm.1.data").bytes.should eq(Bytes[0x01_u8, 0x78_u8])
    encoded.data.stream("root.arm.1.data").offsets.should eq([0_u64, 0_u64, 2_u64, 2_u64])

    # These input lanes and the structure prefix are independently authored;
    # decoding does not use the encoder result above.
    literal_lanes = Hash(String, CrystalClick::BinaryBulkStream).new
    literal_lanes["root.arm.0.data"] = CrystalClick::BinaryBulkStream.new(
      Bytes[0x02_u8, 0x2d_u8, 0x01_u8], [0_u64, 3_u64, 3_u64, 3_u64],
    )
    literal_lanes["root.arm.1.data"] = CrystalClick::BinaryBulkStream.new(
      Bytes[0x01_u8, 0x78_u8], [0_u64, 0_u64, 2_u64, 2_u64],
    )
    literal_lanes["root.discriminators"] = CrystalClick::BinaryBulkStream.new(
      Bytes[0x00_u8, 0x01_u8, 0xff_u8], [0_u64, 1_u64, 2_u64, 3_u64],
    )
    literal = w155_value_paired_streams(
      {"root" => w155_value_string_structure},
      3,
      literal_lanes,
    )
    decoded = CrystalClick::BinaryDynamicBulkCodec.decode(dynamic_type, literal, [1_u64, 1_u64, 1_u64])
    decoded.size.should eq(3)
    selected_bool = decoded[0][0]
    selected_bool.type.should eq(dynamic_type)
    selected_bool.is_null?.should be_false
    selected_bool.child_at(0).type.should eq(CrystalClick::BinaryDataType.primitive("Bool"))
    selected_bool.child_at(0).as_bool.should be_true
    selected_string = decoded[1][0]
    selected_string.type.should eq(dynamic_type)
    selected_string.child_at(0).as_string.should eq("x")
    decoded[2][0].type.should eq(dynamic_type)
    decoded[2][0].is_null?.should be_true
    decoded[2][0].child_count.should eq(0)

    sized = CrystalClick::BinaryDynamicBulkCodec.encode(
      dynamic_type,
      structures,
      granules,
      profile: CrystalClick::BinaryBulkProfile.with_size_stream,
    )
    sized.data.roles.should eq([
      "root.arm.0.data",
      "root.arm.0.string_sizes",
      "root.arm.1.data",
      "root.arm.1.string_sizes",
      "root.discriminators",
    ] of String)
    sized.data.stream("root.arm.0.data").bytes.should eq(Bytes[0x2d_u8, 0x01_u8])
    sized.data.stream("root.arm.0.data").offsets.should eq([0_u64, 2_u64, 2_u64, 2_u64])
    sized.data.stream("root.arm.0.string_sizes").bytes.should eq(
      w155_value_u64(2_u64)
    )
    sized.data.stream("root.arm.0.string_sizes").offsets.should eq([0_u64, 8_u64, 8_u64, 8_u64])
    sized.data.stream("root.arm.1.data").bytes.should eq(Bytes[0x78_u8])
    sized.data.stream("root.arm.1.data").offsets.should eq([0_u64, 0_u64, 1_u64, 1_u64])
    sized.data.stream("root.arm.1.string_sizes").bytes.should eq(
      w155_value_u64(1_u64)
    )
    sized.data.stream("root.arm.1.string_sizes").offsets.should eq([0_u64, 0_u64, 8_u64, 8_u64])

    sized_decoded = CrystalClick::BinaryDynamicBulkCodec.decode(
      dynamic_type,
      sized,
      [1_u64, 1_u64, 1_u64],
      profile: CrystalClick::BinaryBulkProfile.with_size_stream,
    )
    sized_decoded[0][0].child_at(0).as_bool.should be_true
    sized_decoded[1][0].child_at(0).as_string.should eq("x")
    sized_decoded[2][0].is_null?.should be_true
  end

  it "accepts a valid SharedVariant String already present in the roster and normalizes it on re-encode" do
    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    literal_lanes = Hash(String, CrystalClick::BinaryBulkStream).new
    # Shared String contains the complete typed String value [0x15, len=1, 'x'].
    literal_lanes["root.arm.0.data"] = CrystalClick::BinaryBulkStream.new(
      Bytes[0x03_u8, 0x15_u8, 0x01_u8, 0x78_u8], [0_u64, 4_u64],
    )
    literal_lanes["root.arm.1.data"] = CrystalClick::BinaryBulkStream.new(Bytes.empty, [0_u64, 0_u64])
    literal_lanes["root.discriminators"] = CrystalClick::BinaryBulkStream.new(Bytes[0x00_u8], [0_u64, 1_u64])
    source = w155_value_paired_streams(
      {"root" => w155_value_string_structure},
      1,
      literal_lanes,
    )

    decoded = CrystalClick::BinaryDynamicBulkCodec.decode(dynamic_type, source, [1_u64])
    decoded[0][0].is_null?.should be_false
    decoded[0][0].child_at(0).type.should eq(CrystalClick::BinaryDataType.primitive("String"))
    decoded[0][0].child_at(0).as_string.should eq("x")

    normalized = CrystalClick::BinaryDynamicBulkCodec.encode(
      dynamic_type,
      {"root" => CrystalClick::DynamicStructure.new([CrystalClick::BinaryDataType.primitive("String")] of CrystalClick::BinaryDataType)},
      decoded,
    )
    normalized.data.stream("root.discriminators").bytes.should eq(Bytes[0x01_u8])
    normalized.data.stream("root.arm.0.data").bytes.should eq(Bytes.empty)
    normalized.data.stream("root.arm.1.data").bytes.should eq(Bytes[0x01_u8, 0x78_u8])
  end

  it "normalizes a descriptor-only Shared Nothing envelope to Dynamic NULL" do
    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    literal_lanes = Hash(String, CrystalClick::BinaryBulkStream).new
    literal_lanes["root.arm.0.data"] = CrystalClick::BinaryBulkStream.new(
      Bytes[0x01_u8, 0x00_u8], [0_u64, 2_u64],
    )
    literal_lanes["root.discriminators"] = CrystalClick::BinaryBulkStream.new(Bytes[0x00_u8], [0_u64, 1_u64])
    source = w155_value_paired_streams(
      {"root" => w155_value_empty_structure},
      1,
      literal_lanes,
    )

    decoded = CrystalClick::BinaryDynamicBulkCodec.decode(dynamic_type, source, [1_u64])
    decoded[0][0].type.should eq(dynamic_type)
    decoded[0][0].is_null?.should be_true
    decoded[0][0].child_count.should eq(0)

    normalized = CrystalClick::BinaryDynamicBulkCodec.encode(
      dynamic_type,
      {"root" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)},
      decoded,
    )
    normalized.data.stream("root.discriminators").bytes.should eq(Bytes[0xff_u8])
    normalized.data.stream("root.arm.0.data").bytes.should eq(Bytes.empty)
  end

  it "preserves nested actual Array(Dynamic) prefixes when a child mark is empty" do
    inner_dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    array_type = CrystalClick::BinaryDataType.array(inner_dynamic)
    uint64_type = CrystalClick::BinaryDataType.primitive("UInt64")
    inner_structure = CrystalClick::DynamicStructure.new([uint64_type] of CrystalClick::BinaryDataType)
    structures = {
      "root"                => CrystalClick::DynamicStructure.new([array_type] of CrystalClick::BinaryDataType),
      "root.arm.0.elements" => inner_structure,
    }
    first = CrystalClick::BinaryValue.dynamic(
      dynamic_type,
      CrystalClick::BinaryValue.array(array_type, [
        CrystalClick::BinaryValue.dynamic(inner_dynamic, CrystalClick::BinaryValue.uint64(9_u64)),
      ] of CrystalClick::BinaryValue),
    )
    second = CrystalClick::BinaryValue.dynamic(
      dynamic_type,
      CrystalClick::BinaryValue.array(array_type, [] of CrystalClick::BinaryValue),
    )
    granules = [[first] of CrystalClick::BinaryValue, [second] of CrystalClick::BinaryValue] of Array(CrystalClick::BinaryValue)

    encoded = CrystalClick::BinaryDynamicBulkCodec.encode(dynamic_type, structures, granules)
    encoded.structures.site_paths.should eq(["root", "root.arm.0.elements"] of String)
    encoded.structures.structure_bytes_for("root.arm.0.elements").should eq(Bytes[
      0x04_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 1_u8, 0x04_u8, 0_u8,
    ])
    encoded.data.stream("root.discriminators").bytes.should eq(Bytes[0x00_u8, 0x00_u8])
    encoded.data.stream("root.arm.0.sizes").bytes.should eq(
      w155_value_concat([w155_value_u64(1_u64), w155_value_u64(0_u64)] of Bytes)
    )
    encoded.data.stream("root.arm.0.sizes").offsets.should eq([0_u64, 8_u64, 16_u64])
    encoded.data.stream("root.arm.0.elements.discriminators").bytes.should eq(Bytes[0x01_u8])
    encoded.data.stream("root.arm.0.elements.discriminators").offsets.should eq([0_u64, 1_u64, 1_u64])
    encoded.data.stream("root.arm.0.elements.arm.1.data").bytes.should eq(Bytes[
      0x09_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8,
    ])
    encoded.data.stream("root.arm.0.elements.arm.1.data").offsets.should eq([0_u64, 8_u64, 8_u64])

    decoded = CrystalClick::BinaryDynamicBulkCodec.decode(dynamic_type, encoded, [1_u64, 1_u64])
    decoded[0][0].child_at(0).element_count.should eq(1)
    decoded[0][0].child_at(0).element_at(0).child_at(0).as_uint64.should eq(9_u64)
    decoded[1][0].child_at(0).element_count.should eq(0)

    empty_middle = CrystalClick::BinaryDynamicBulkCodec.decode(
      dynamic_type,
      encoded,
      [1_u64, 1_u64],
      first_mark: 1,
      mark_count: 1,
    )
    empty_middle[0][0].child_at(0).element_count.should eq(0)
  end

  it "plans Map and static Variant sites independently, including an unused nested site" do
    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    string_type = CrystalClick::BinaryDataType.primitive("String")
    uint64_type = CrystalClick::BinaryDataType.primitive("UInt64")
    map_type = CrystalClick::BinaryDataType.map(string_type, dynamic_type)
    array_dynamic_type = CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.dynamic(max_types: 0))
    variant_type = CrystalClick::BinaryDataType.variant([string_type, array_dynamic_type] of CrystalClick::BinaryDataType)
    root_type = CrystalClick::BinaryDataType.tuple([map_type, variant_type] of CrystalClick::BinaryDataType)
    structures = {
      "root.field.0.elements.field.1" => CrystalClick::DynamicStructure.new([uint64_type] of CrystalClick::BinaryDataType),
      "root.field.1.arm.0.elements"   => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType),
    }
    map_value = CrystalClick::BinaryValue.map(map_type, [
      CrystalClick::BinaryValue.string("k"),
      CrystalClick::BinaryValue.dynamic(dynamic_type, CrystalClick::BinaryValue.uint64(42_u64)),
    ] of CrystalClick::BinaryValue)
    selected_variant_index = variant_type.children.index(array_dynamic_type).not_nil!
    string_variant_index = variant_type.children.index(string_type).not_nil!
    string_variant_index.should eq(1)
    variant_value = CrystalClick::BinaryValue.variant(variant_type, string_variant_index, CrystalClick::BinaryValue.string("v"))
    row = CrystalClick::BinaryValue.tuple(root_type, [map_value, variant_value] of CrystalClick::BinaryValue)

    encoded = CrystalClick::BinaryDynamicBulkCodec.encode(root_type, structures, [[row] of CrystalClick::BinaryValue])
    encoded.structures.site_paths.should eq([
      "root.field.0.elements.field.1",
      "root.field.1.arm.0.elements",
    ] of String)
    encoded.structures.structure_bytes_for("root.field.1.arm.0.elements").should eq(w155_value_empty_structure)
    encoded.data.roles.should eq([
      "root.field.0.elements.field.0.data",
      "root.field.0.elements.field.1.arm.0.data",
      "root.field.0.elements.field.1.arm.1.data",
      "root.field.0.elements.field.1.discriminators",
      "root.field.0.sizes",
      "root.field.1.arm.0.elements.arm.0.data",
      "root.field.1.arm.0.elements.discriminators",
      "root.field.1.arm.0.sizes",
      "root.field.1.arm.1.data",
      "root.field.1.discriminators",
    ] of String)
    encoded.data.stream("root.field.0.elements.field.1.discriminators").bytes.should eq(Bytes[0x01_u8])
    encoded.data.stream("root.field.0.elements.field.1.arm.1.data").bytes.should eq(Bytes[
      0x2a_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8,
    ])
    encoded.data.stream("root.field.1.discriminators").bytes.should eq(Bytes[string_variant_index.to_u8])
    encoded.data.stream("root.field.1.arm.1.data").bytes.should eq(Bytes[0x01_u8, 0x76_u8])
    # The Dynamic below unselected Variant(Array(Dynamic)) still owns a full
    # zero-occurrence grid and its independently supplied empty prefix.
    encoded.data.stream("root.field.1.arm.0.elements.discriminators").bytes.should be_empty
    encoded.data.stream("root.field.1.arm.0.elements.discriminators").offsets.should eq([0_u64, 0_u64])
    encoded.data.stream("root.field.1.arm.0.elements.arm.0.data").offsets.should eq([0_u64, 0_u64])
    encoded.data.stream("root.field.1.arm.0.sizes").bytes.should be_empty
    encoded.data.stream("root.field.1.arm.0.sizes").offsets.should eq([0_u64, 0_u64])

    decoded = CrystalClick::BinaryDynamicBulkCodec.decode(root_type, encoded, [1_u64])
    decoded_map = decoded[0][0].child_at(0)
    decoded_map.element_at(0).as_string.should eq("k")
    decoded_map.element_at(1).child_at(0).as_uint64.should eq(42_u64)
    decoded_variant = decoded[0][0].child_at(1)
    decoded_variant.variant_index?.should eq(string_variant_index.to_u8)
    decoded_variant.variant_child?.not_nil!.as_string.should eq("v")
  end

  it "keeps the Dynamic prefix and K+1 role grids for zero-row and zero-mark inputs" do
    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    declared = CrystalClick::BinaryDataType.array(dynamic_type)
    structures = {
      "root.elements" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType),
    }
    one_empty_mark = CrystalClick::BinaryDynamicBulkCodec.encode(
      declared,
      structures,
      [[] of CrystalClick::BinaryValue],
    )
    one_empty_mark.structures.site_paths.should eq(["root.elements"] of String)
    one_empty_mark.structures.structure_bytes_for("root.elements").should eq(w155_value_empty_structure)
    one_empty_mark.data.mark_count.should eq(1)
    one_empty_mark.data.stream("root.elements.discriminators").bytes.should be_empty
    one_empty_mark.data.stream("root.elements.discriminators").offsets.should eq([0_u64, 0_u64])
    one_empty_mark.data.stream("root.elements.arm.0.data").offsets.should eq([0_u64, 0_u64])
    decoded = CrystalClick::BinaryDynamicBulkCodec.decode(declared, one_empty_mark, [0_u64])
    decoded.size.should eq(1)
    decoded[0].should be_empty

    no_marks = CrystalClick::BinaryDynamicBulkCodec.encode(
      declared,
      structures,
      [] of Array(CrystalClick::BinaryValue),
    )
    no_marks.structures.site_paths.should eq(["root.elements"] of String)
    no_marks.data.mark_count.should eq(0)
    no_marks.data.stream("root.elements.discriminators").offsets.should eq([0_u64])
    CrystalClick::BinaryDynamicBulkCodec.decode(declared, no_marks, [] of UInt64).should be_empty
  end

  it "replays a sparse nested LowCardinality schedule when selecting a later Dynamic Array mark" do
    uint8_type = CrystalClick::BinaryDataType.primitive("UInt8")
    low_type = CrystalClick::BinaryDataType.low_cardinality(uint8_type)
    array_type = CrystalClick::BinaryDataType.array(low_type)
    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    structures = {
      "root" => CrystalClick::DynamicStructure.new([array_type] of CrystalClick::BinaryDataType),
    }
    lc = ->(value : UInt8) do
      CrystalClick::BinaryValue.low_cardinality(low_type, CrystalClick::BinaryValue.fixed(uint8_type, Bytes[value]))
    end
    first = CrystalClick::BinaryValue.dynamic(dynamic_type, CrystalClick::BinaryValue.array(array_type, [lc.call(7_u8)] of CrystalClick::BinaryValue))
    absent = CrystalClick::BinaryValue.dynamic(dynamic_type)
    last = CrystalClick::BinaryValue.dynamic(dynamic_type, CrystalClick::BinaryValue.array(array_type, [lc.call(8_u8)] of CrystalClick::BinaryValue))
    granules = [[first] of CrystalClick::BinaryValue, [absent] of CrystalClick::BinaryValue, [last] of CrystalClick::BinaryValue] of Array(CrystalClick::BinaryValue)

    encoded = CrystalClick::BinaryDynamicBulkCodec.encode(dynamic_type, structures, granules)
    encoded.data.stream("root.discriminators").bytes.should eq(Bytes[0x00_u8, 0xff_u8, 0x00_u8])
    encoded.data.stream("root.arm.0.sizes").bytes.should eq(
      w155_value_concat([w155_value_u64(1_u64), w155_value_u64(1_u64)] of Bytes)
    )
    encoded.data.stream("root.arm.0.sizes").offsets.should eq([0_u64, 8_u64, 8_u64, 16_u64])
    encoded.data.stream("root.arm.0.elements.dictionary").bytes.should eq(Bytes[
      0x01_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8,
      0x03_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8,
      0x00_u8, 0x07_u8, 0x08_u8,
    ])
    encoded.data.stream("root.arm.0.elements.dictionary").offsets.should eq([8_u64, 8_u64, 8_u64, 19_u64])
    encoded.data.stream("root.arm.0.elements.indexes").bytes.should eq(Bytes[
      0x00_u8, 0x05_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8,
      0x01_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0x01_u8,
      0x00_u8, 0x01_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8,
      0x01_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0x02_u8,
    ])
    encoded.data.stream("root.arm.0.elements.indexes").offsets.should eq([0_u64, 17_u64, 17_u64, 34_u64])

    selected = CrystalClick::BinaryDynamicBulkCodec.decode(
      dynamic_type,
      encoded,
      [1_u64, 1_u64, 1_u64],
      first_mark: 2,
      mark_count: 1,
    )
    selected.size.should eq(1)
    selected[0][0].child_at(0).element_at(0).child_at(0).bytes.should eq(Bytes[0x08_u8])
    selected_empty = CrystalClick::BinaryDynamicBulkCodec.decode(
      dynamic_type,
      encoded,
      [1_u64, 1_u64, 1_u64],
      first_mark: 1,
      mark_count: 1,
    )
    selected_empty[0][0].is_null?.should be_true
  end

  it "discovers both LC-bearing actual sites and preserves both full schedules" do
    uint8_type = CrystalClick::BinaryDataType.primitive("UInt8")
    low_type = CrystalClick::BinaryDataType.low_cardinality(uint8_type)
    array_type = CrystalClick::BinaryDataType.array(low_type)
    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    tuple_type = CrystalClick::BinaryDataType.tuple([dynamic_type, dynamic_type] of CrystalClick::BinaryDataType)
    actual_structure = CrystalClick::DynamicStructure.new([array_type] of CrystalClick::BinaryDataType)
    structures = {
      "root.field.0" => actual_structure,
      "root.field.1" => actual_structure,
    }
    lc = ->(value : UInt8) do
      CrystalClick::BinaryValue.low_cardinality(
        low_type,
        CrystalClick::BinaryValue.fixed(uint8_type, Bytes[value]),
      )
    end
    first = CrystalClick::BinaryValue.tuple(tuple_type, [
      CrystalClick::BinaryValue.dynamic(dynamic_type, CrystalClick::BinaryValue.array(array_type, [lc.call(7_u8)] of CrystalClick::BinaryValue)),
      CrystalClick::BinaryValue.dynamic(dynamic_type, CrystalClick::BinaryValue.array(array_type, [lc.call(8_u8)] of CrystalClick::BinaryValue)),
    ] of CrystalClick::BinaryValue)
    second = CrystalClick::BinaryValue.tuple(tuple_type, [
      CrystalClick::BinaryValue.dynamic(dynamic_type),
      CrystalClick::BinaryValue.dynamic(dynamic_type, CrystalClick::BinaryValue.array(array_type, [lc.call(9_u8)] of CrystalClick::BinaryValue)),
    ] of CrystalClick::BinaryValue)
    granules = [[first] of CrystalClick::BinaryValue, [second] of CrystalClick::BinaryValue] of Array(CrystalClick::BinaryValue)

    encoded = CrystalClick::BinaryDynamicBulkCodec.encode(tuple_type, structures, granules)
    encoded.data.roles.should eq([
      "root.field.0.arm.0.elements.dictionary",
      "root.field.0.arm.0.elements.indexes",
      "root.field.0.arm.0.sizes",
      "root.field.0.arm.1.data",
      "root.field.0.discriminators",
      "root.field.1.arm.0.elements.dictionary",
      "root.field.1.arm.0.elements.indexes",
      "root.field.1.arm.0.sizes",
      "root.field.1.arm.1.data",
      "root.field.1.discriminators",
    ] of String)
    encoded.data.mark_count.should eq(2)
    encoded.data.stream("root.field.0.arm.0.sizes").bytes.should eq(
      w155_value_u64(1_u64)
    )
    encoded.data.stream("root.field.0.arm.0.sizes").offsets.should eq([0_u64, 8_u64, 8_u64])
    encoded.data.stream("root.field.1.arm.0.sizes").bytes.should eq(
      w155_value_concat([w155_value_u64(1_u64), w155_value_u64(1_u64)] of Bytes)
    )
    encoded.data.stream("root.field.1.arm.0.sizes").offsets.should eq([0_u64, 8_u64, 16_u64])

    encoded.data.stream("root.field.0.discriminators").bytes.should eq(Bytes[0x00_u8, 0xff_u8])
    encoded.data.stream("root.field.0.discriminators").offsets.should eq([0_u64, 1_u64, 2_u64])
    encoded.data.stream("root.field.1.discriminators").bytes.should eq(Bytes[0x00_u8, 0x00_u8])
    encoded.data.stream("root.field.1.discriminators").offsets.should eq([0_u64, 1_u64, 2_u64])

    encoded.data.stream("root.field.0.arm.0.elements.dictionary").bytes.should eq(Bytes[
      0x01_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8,
      0x02_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8,
      0x00_u8, 0x07_u8,
    ])
    encoded.data.stream("root.field.0.arm.0.elements.dictionary").offsets.should eq([8_u64, 8_u64, 18_u64])
    encoded.data.stream("root.field.0.arm.0.elements.indexes").bytes.should eq(Bytes[
      0x00_u8, 0x05_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8,
      0x01_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0x01_u8,
    ])
    encoded.data.stream("root.field.0.arm.0.elements.indexes").offsets.should eq([0_u64, 17_u64, 17_u64])
    encoded.data.stream("root.field.1.arm.0.elements.dictionary").bytes.should eq(Bytes[
      0x01_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8,
      0x03_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8,
      0x00_u8, 0x08_u8, 0x09_u8,
    ])
    encoded.data.stream("root.field.1.arm.0.elements.dictionary").offsets.should eq([8_u64, 8_u64, 19_u64])
    encoded.data.stream("root.field.1.arm.0.elements.indexes").bytes.should eq(Bytes[
      0x00_u8, 0x05_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8,
      0x01_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0x01_u8,
      0x00_u8, 0x01_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8,
      0x01_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0x02_u8,
    ])
    encoded.data.stream("root.field.1.arm.0.elements.indexes").offsets.should eq([0_u64, 17_u64, 34_u64])

    decoded = CrystalClick::BinaryDynamicBulkCodec.decode(tuple_type, encoded, [1_u64, 1_u64])
    decoded[0][0].child_at(0).child_at(0).element_at(0).child_at(0).bytes.should eq(Bytes[0x07_u8])
    decoded[0][0].child_at(1).child_at(0).element_at(0).child_at(0).bytes.should eq(Bytes[0x08_u8])
    decoded[1][0].child_at(0).is_null?.should be_true
    decoded[1][0].child_at(1).child_at(0).element_at(0).child_at(0).bytes.should eq(Bytes[0x09_u8])

    later_mark = CrystalClick::BinaryDynamicBulkCodec.decode(
      tuple_type,
      encoded,
      [1_u64, 1_u64],
      first_mark: 1,
      mark_count: 1,
    )
    later_mark.size.should eq(1)
    later_mark[0][0].child_at(0).is_null?.should be_true
    later_mark[0][0].child_at(1).child_at(0).element_at(0).child_at(0).bytes.should eq(Bytes[0x09_u8])
  end

  it "discovers a LowCardinality lane below Array and Tuple shape wrappers" do
    uint8_type = CrystalClick::BinaryDataType.primitive("UInt8")
    uint16_type = CrystalClick::BinaryDataType.primitive("UInt16")
    low_type = CrystalClick::BinaryDataType.low_cardinality(uint8_type)
    tuple_type = CrystalClick::BinaryDataType.tuple([low_type, uint16_type] of CrystalClick::BinaryDataType)
    array_type = CrystalClick::BinaryDataType.array(tuple_type)
    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    structure = CrystalClick::DynamicStructure.new([array_type] of CrystalClick::BinaryDataType)
    low_value = CrystalClick::BinaryValue.low_cardinality(
      low_type,
      CrystalClick::BinaryValue.fixed(uint8_type, Bytes[0x07_u8]),
    )
    tuple_value = CrystalClick::BinaryValue.tuple(tuple_type, [
      low_value,
      CrystalClick::BinaryValue.fixed(uint16_type, Bytes[0x34_u8, 0x12_u8]),
    ] of CrystalClick::BinaryValue)
    selected = CrystalClick::BinaryValue.dynamic(
      dynamic_type,
      CrystalClick::BinaryValue.array(array_type, [tuple_value] of CrystalClick::BinaryValue),
    )

    encoded = CrystalClick::BinaryDynamicBulkCodec.encode(
      dynamic_type,
      {"root" => structure},
      [[selected] of CrystalClick::BinaryValue],
    )
    encoded.data.roles.should eq([
      "root.arm.0.elements.field.0.dictionary",
      "root.arm.0.elements.field.0.indexes",
      "root.arm.0.elements.field.1.data",
      "root.arm.0.sizes",
      "root.arm.1.data",
      "root.discriminators",
    ] of String)
    encoded.data.stream("root.arm.0.sizes").bytes.should eq(w155_value_u64(1_u64))
    encoded.data.stream("root.arm.0.sizes").offsets.should eq([0_u64, 8_u64])
    encoded.data.stream("root.arm.0.elements.field.0.dictionary").bytes.should eq(Bytes[
      0x01_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8,
      0x02_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8,
      0x00_u8, 0x07_u8,
    ])
    encoded.data.stream("root.arm.0.elements.field.0.indexes").offsets.should eq([0_u64, 17_u64])
    encoded.data.stream("root.arm.0.elements.field.1.data").bytes.should eq(Bytes[0x34_u8, 0x12_u8])
    encoded.data.stream("root.arm.0.elements.field.1.data").offsets.should eq([0_u64, 2_u64])

    decoded = CrystalClick::BinaryDynamicBulkCodec.decode(dynamic_type, encoded, [1_u64])
    decoded[0][0].child_at(0).element_at(0).child_at(0).child_at(0).bytes.should eq(Bytes[0x07_u8])
    decoded[0][0].child_at(0).element_at(0).child_at(1).bytes.should eq(Bytes[0x34_u8, 0x12_u8])
  end

  it "uses one aggregate budget across two sites, shared envelopes, and an LC child" do
    uint8_type = CrystalClick::BinaryDataType.primitive("UInt8")
    low_type = CrystalClick::BinaryDataType.low_cardinality(uint8_type)
    array_type = CrystalClick::BinaryDataType.array(low_type)
    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    tuple_type = CrystalClick::BinaryDataType.tuple([dynamic_type, dynamic_type] of CrystalClick::BinaryDataType)
    structures = {
      "root.field.0" => CrystalClick::DynamicStructure.new([array_type] of CrystalClick::BinaryDataType),
      "root.field.1" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType),
    }
    selected_array = CrystalClick::BinaryValue.dynamic(
      dynamic_type,
      CrystalClick::BinaryValue.array(array_type, [
        CrystalClick::BinaryValue.low_cardinality(low_type, CrystalClick::BinaryValue.fixed(uint8_type, Bytes[0x07_u8])),
      ] of CrystalClick::BinaryValue),
    )
    selected_shared = CrystalClick::BinaryValue.dynamic(dynamic_type, CrystalClick::BinaryValue.fixed(uint8_type, Bytes[0x01_u8]))
    row = CrystalClick::BinaryValue.tuple(tuple_type, [selected_array, selected_shared] of CrystalClick::BinaryValue)
    granules = [[row] of CrystalClick::BinaryValue]

    write_budget = CrystalClick::BinaryCodecBudget.new(w155_value_limits, true)
    encoded = CrystalClick::BinaryDynamicBulkCodec.encode_with_budget(tuple_type, structures, granules, write_budget)
    write_counts = {write_budget.node_count, write_budget.element_count, write_budget.wire_byte_count}
    # Independent lower bounds from the retained logical value tree: Tuple,
    # both Dynamic wrappers, actual Array, LC wrapper, and two UInt8 leaves;
    # plus Tuple, Dynamic, Array, and LC child edges.
    write_counts[0].should be >= 7_i64
    write_counts[1].should be >= 6_i64
    write_counts[2].should be >= (
      encoded.structures.total_input_byte_size + encoded.data.total_input_byte_size
    ).to_i64
    encoded.structures.site_paths.should eq(["root.field.0", "root.field.1"] of String)
    encoded.data.stream("root.field.1.arm.0.data").bytes.should eq(Bytes[0x02_u8, 0x01_u8, 0x01_u8])

    exact_write = CrystalClick::BinaryCodecBudget.new(
      w155_value_limits(max_nodes: write_counts[0], max_elements: write_counts[1], max_bytes: write_counts[2]),
      true,
    )
    CrystalClick::BinaryDynamicBulkCodec.encode_with_budget(tuple_type, structures, granules, exact_write)
    {exact_write.node_count, exact_write.element_count, exact_write.wire_byte_count}.should eq(write_counts)
    [
      w155_value_limits(max_nodes: write_counts[0] - 1, max_elements: write_counts[1], max_bytes: write_counts[2]),
      w155_value_limits(max_nodes: write_counts[0], max_elements: write_counts[1] - 1, max_bytes: write_counts[2]),
      w155_value_limits(max_nodes: write_counts[0], max_elements: write_counts[1], max_bytes: write_counts[2] - 1),
    ].each do |limits|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryDynamicBulkCodec.encode(tuple_type, structures, granules, limits: limits)
      end
    end

    read_budget = CrystalClick::BinaryCodecBudget.new(w155_value_limits)
    CrystalClick::BinaryDynamicBulkCodec.decode_with_budget(tuple_type, encoded, [1_u64], read_budget)
    read_counts = {read_budget.node_count, read_budget.element_count, read_budget.wire_byte_count}
    read_counts[0].should be >= 7_i64
    read_counts[1].should be >= 6_i64
    read_counts[2].should be >= (
      encoded.structures.total_input_byte_size + encoded.data.total_input_byte_size
    ).to_i64
    exact_read = CrystalClick::BinaryCodecBudget.new(
      w155_value_limits(max_nodes: read_counts[0], max_elements: read_counts[1], max_bytes: read_counts[2]),
    )
    CrystalClick::BinaryDynamicBulkCodec.decode_with_budget(tuple_type, encoded, [1_u64], exact_read)
    {exact_read.node_count, exact_read.element_count, exact_read.wire_byte_count}.should eq(read_counts)
    [
      w155_value_limits(max_nodes: read_counts[0] - 1, max_elements: read_counts[1], max_bytes: read_counts[2]),
      w155_value_limits(max_nodes: read_counts[0], max_elements: read_counts[1] - 1, max_bytes: read_counts[2]),
      w155_value_limits(max_nodes: read_counts[0], max_elements: read_counts[1], max_bytes: read_counts[2] - 1),
    ].each do |limits|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryDynamicBulkCodec.decode(tuple_type, encoded, [1_u64], limits: limits)
      end
    end

    # A second independent relation catches per-site counter resets even if a
    # mutant reports a self-consistent but too-small exact threshold above.
    shared_rows = [[
      CrystalClick::BinaryValue.tuple(tuple_type, [
        CrystalClick::BinaryValue.dynamic(dynamic_type, CrystalClick::BinaryValue.fixed(uint8_type, Bytes[0x01_u8])),
        CrystalClick::BinaryValue.dynamic(dynamic_type, CrystalClick::BinaryValue.fixed(uint8_type, Bytes[0x02_u8])),
      ] of CrystalClick::BinaryValue),
    ] of CrystalClick::BinaryValue] of Array(CrystalClick::BinaryValue)
    empty_rosters = {
      "root.field.0" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType),
      "root.field.1" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType),
    }
    shared_combined = CrystalClick::BinaryDynamicBulkCodec.encode(tuple_type, empty_rosters, shared_rows)
    left_streams = CrystalClick::BinaryDynamicBulkCodec.encode(
      dynamic_type,
      {"root" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)},
      [[CrystalClick::BinaryValue.dynamic(dynamic_type, CrystalClick::BinaryValue.fixed(uint8_type, Bytes[0x01_u8]))] of CrystalClick::BinaryValue],
    )
    right_streams = CrystalClick::BinaryDynamicBulkCodec.encode(
      dynamic_type,
      {"root" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)},
      [[CrystalClick::BinaryValue.dynamic(dynamic_type, CrystalClick::BinaryValue.fixed(uint8_type, Bytes[0x02_u8]))] of CrystalClick::BinaryValue],
    )

    left_write = CrystalClick::BinaryCodecBudget.new(w155_value_limits, true)
    CrystalClick::BinaryDynamicBulkCodec.encode_with_budget(
      dynamic_type,
      {"root" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)},
      [[CrystalClick::BinaryValue.dynamic(dynamic_type, CrystalClick::BinaryValue.fixed(uint8_type, Bytes[0x01_u8]))] of CrystalClick::BinaryValue],
      left_write,
    )
    right_write = CrystalClick::BinaryCodecBudget.new(w155_value_limits, true)
    CrystalClick::BinaryDynamicBulkCodec.encode_with_budget(
      dynamic_type,
      {"root" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)},
      [[CrystalClick::BinaryValue.dynamic(dynamic_type, CrystalClick::BinaryValue.fixed(uint8_type, Bytes[0x02_u8]))] of CrystalClick::BinaryValue],
      right_write,
    )
    combined_write = CrystalClick::BinaryCodecBudget.new(w155_value_limits, true)
    CrystalClick::BinaryDynamicBulkCodec.encode_with_budget(tuple_type, empty_rosters, shared_rows, combined_write)
    combined_write.node_count.should be >= left_write.node_count + right_write.node_count
    combined_write.element_count.should be >= left_write.element_count + right_write.element_count

    left_read = CrystalClick::BinaryCodecBudget.new(w155_value_limits)
    CrystalClick::BinaryDynamicBulkCodec.decode_with_budget(dynamic_type, left_streams, [1_u64], left_read)
    right_read = CrystalClick::BinaryCodecBudget.new(w155_value_limits)
    CrystalClick::BinaryDynamicBulkCodec.decode_with_budget(dynamic_type, right_streams, [1_u64], right_read)
    combined_read = CrystalClick::BinaryCodecBudget.new(w155_value_limits)
    CrystalClick::BinaryDynamicBulkCodec.decode_with_budget(tuple_type, shared_combined, [1_u64], combined_read)
    combined_read.node_count.should be >= left_read.node_count + right_read.node_count
    combined_read.element_count.should be >= left_read.element_count + right_read.element_count
  end

  it "keeps Dynamic depth at the selected child instead of counting an opaque shared frame" do
    uint8_type = CrystalClick::BinaryDataType.primitive("UInt8")
    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    empty_roster = {"root" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)}
    shared = [[CrystalClick::BinaryValue.dynamic(dynamic_type, CrystalClick::BinaryValue.fixed(uint8_type, Bytes[0x01_u8]))] of CrystalClick::BinaryValue] of Array(CrystalClick::BinaryValue)
    shared_streams = CrystalClick::BinaryDynamicBulkCodec.encode(
      dynamic_type,
      empty_roster,
      shared,
      limits: w155_value_limits(max_depth: 2),
    )
    CrystalClick::BinaryDynamicBulkCodec.decode(
      dynamic_type,
      shared_streams,
      [1_u64],
      limits: w155_value_limits(max_depth: 2),
    ).size.should eq(1)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDynamicBulkCodec.encode(
        dynamic_type,
        empty_roster,
        shared,
        limits: w155_value_limits(max_depth: 1),
      )
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDynamicBulkCodec.decode(
        dynamic_type,
        shared_streams,
        [1_u64],
        limits: w155_value_limits(max_depth: 1),
      )
    end

    bool_type = CrystalClick::BinaryDataType.primitive("Bool")
    inner_array = CrystalClick::BinaryDataType.array(bool_type)
    outer_array = CrystalClick::BinaryDataType.array(inner_array)
    deep_roster = {"root" => CrystalClick::DynamicStructure.new([outer_array] of CrystalClick::BinaryDataType)}
    deep_value = CrystalClick::BinaryValue.dynamic(
      dynamic_type,
      CrystalClick::BinaryValue.array(outer_array, [
        CrystalClick::BinaryValue.array(inner_array, [CrystalClick::BinaryValue.bool(true)] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue),
    )
    deep_granules = [[deep_value] of CrystalClick::BinaryValue] of Array(CrystalClick::BinaryValue)
    deep_streams = CrystalClick::BinaryDynamicBulkCodec.encode(
      dynamic_type,
      deep_roster,
      deep_granules,
      limits: w155_value_limits(max_depth: 4),
    )
    CrystalClick::BinaryDynamicBulkCodec.decode(
      dynamic_type,
      deep_streams,
      [1_u64],
      limits: w155_value_limits(max_depth: 4),
    ).size.should eq(1)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDynamicBulkCodec.encode(
        dynamic_type,
        deep_roster,
        deep_granules,
        limits: w155_value_limits(max_depth: 3),
      )
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDynamicBulkCodec.decode(
        dynamic_type,
        deep_streams,
        [1_u64],
        limits: w155_value_limits(max_depth: 3),
      )
    end
  end

  it "rejects a byte limit below the independent normalized-output lower bound" do
    uint8_type = CrystalClick::BinaryDataType.primitive("UInt8")
    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    empty = CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)

    tuple_type = CrystalClick::BinaryDataType.tuple([dynamic_type, dynamic_type] of CrystalClick::BinaryDataType)
    both_sites = {
      "root.field.0" => empty,
      "root.field.1" => empty,
    }
    row = CrystalClick::BinaryValue.tuple(tuple_type, [
      CrystalClick::BinaryValue.dynamic(dynamic_type, CrystalClick::BinaryValue.fixed(uint8_type, Bytes[0x01_u8])),
      CrystalClick::BinaryValue.dynamic(dynamic_type, CrystalClick::BinaryValue.fixed(uint8_type, Bytes[0x01_u8])),
    ] of CrystalClick::BinaryValue)
    granules = [[row] of CrystalClick::BinaryValue]

    # Independent literal lower bound: two 10-byte empty Dynamic V3 prefixes,
    # two one-byte discriminators, and two three-byte framed UInt8 envelopes.
    # The normalized stream output alone is 28 bytes, before any work accounting.
    encoded = CrystalClick::BinaryDynamicBulkCodec.encode(tuple_type, both_sites, granules)
    encoded.structures.total_input_byte_size.should eq(20_u64)
    encoded.data.total_input_byte_size.should be >= 8_u64
    expect_raises(CrystalClick::UnsupportedFormatError, /byte/) do
      CrystalClick::BinaryDynamicBulkCodec.encode(
        tuple_type,
        both_sites,
        granules,
        limits: w155_value_limits(max_bytes: 27),
      )
    end
    expect_raises(CrystalClick::CorruptPartError, /byte/) do
      CrystalClick::BinaryDynamicBulkCodec.decode(
        tuple_type,
        encoded,
        [1_u64],
        limits: w155_value_limits(max_bytes: 27),
      )
    end
  end

  it "keeps the legacy no-structure Dynamic API fenced for empty work" do
    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    expect_raises(CrystalClick::UnsupportedFormatError, /Dynamic/) do
      CrystalClick::BinaryBulkCodec.encode(dynamic_type, [] of Array(CrystalClick::BinaryValue))
    end
    empty_lanes = Hash(String, CrystalClick::BinaryBulkStream).new
    empty_legacy_streams = CrystalClick::BinaryBulkStreams.new(0, empty_lanes)
    expect_raises(CrystalClick::UnsupportedFormatError, /Dynamic/) do
      CrystalClick::BinaryBulkCodec.decode(dynamic_type, empty_legacy_streams, [] of UInt64, mark_count: 0)
    end
  end
end
