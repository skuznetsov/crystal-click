require "./spec_helper"

private def w123_literal_u64(value : UInt64) : Bytes
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

private def w123_literal_concat(parts : Array(Bytes)) : Bytes
  count = 0
  parts.each { |part| count += part.size }
  result = Bytes.new(count)
  offset = 0
  parts.each do |part|
    part.each do |byte|
      result[offset] = byte
      offset += 1
    end
  end
  result
end

private def w123_literal_structure : CrystalClick::ObjectDynamicStructureSet
  CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new([] of String),
    {} of String => CrystalClick::DynamicStructure
  )
end

private def w123_literal_shared_lanes : CrystalClick::BinaryBulkStreams
  # Independent Array(Tuple(paths String, values String)) lanes for mark row
  # entry counts 2, 1, 0. Child String lanes contain length-prefixed payloads;
  # values are W117 nominal envelopes, not JSON text.
  CrystalClick::BinaryBulkStreams.new(
    3,
    {
      "root.sizes" => CrystalClick::BinaryBulkStream.new(
        w123_literal_concat([
          w123_literal_u64(2_u64), w123_literal_u64(1_u64), w123_literal_u64(0_u64),
        ] of Bytes),
        [0_u64, 8_u64, 16_u64, 24_u64]
      ),
      "root.elements.field.0.data" => CrystalClick::BinaryBulkStream.new(
        Bytes[0x01_u8, 0x61_u8, 0x03_u8, 0x61_u8, 0x2e_u8, 0x62_u8, 0x01_u8, 0x7a_u8],
        [0_u64, 6_u64, 8_u64, 8_u64]
      ),
      "root.elements.field.1.data" => CrystalClick::BinaryBulkStream.new(
        Bytes[
          0x09_u8, 0x0a_u8, 0x2a_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
          0x03_u8, 0x15_u8, 0x01_u8, 0x78_u8,
          0x02_u8, 0x2d_u8, 0x01_u8,
        ],
        [0_u64, 14_u64, 17_u64, 17_u64]
      ),
    } of String => CrystalClick::BinaryBulkStream
  )
end

private def w123_rewrap_streams(
  source : CrystalClick::ObjectDocumentStreams,
  shared : CrystalClick::BinaryBulkStreams,
) : CrystalClick::ObjectDocumentStreams
  w123_rewrap_streams(source, shared, source.rows_per_mark)
end

private def w123_rewrap_streams(
  source : CrystalClick::ObjectDocumentStreams,
  shared : CrystalClick::BinaryBulkStreams,
  rows_per_mark : Array(UInt64),
) : CrystalClick::ObjectDocumentStreams
  typed = Hash(String, CrystalClick::BinaryBulkStreams).new
  source.typed_path_count.times do |index|
    path = source.typed_path_at(index)
    typed[path] = source.typed_for(path)
  end
  dynamic = Hash(String, CrystalClick::DynamicValueStreams).new
  source.dynamic_path_count.times do |index|
    path = source.dynamic_path_at(index)
    dynamic[path] = source.dynamic_for(path)
  end
  CrystalClick::ObjectDocumentStreams.new(source.structures, rows_per_mark, typed, dynamic, shared)
end

describe "W123 Object document adversarial boundaries" do
  it "decodes an independent shared literal over a nonzero-origin window" do
    structures = w123_literal_structure
    metadata = CrystalClick::ObjectDynamicStructureCodec.encode(structures)
    literal = CrystalClick::ObjectDocumentStreams.new(
      metadata,
      [1_u64, 1_u64, 1_u64],
      {} of String => CrystalClick::BinaryBulkStreams,
      {} of String => CrystalClick::DynamicValueStreams,
      w123_literal_shared_lanes
    )

    all = CrystalClick::ObjectDocumentCodec.decode({} of String => CrystalClick::BinaryDataType, literal)
    all.map(&.size).should eq([1, 1, 1])
    all[0][0].paths.should eq(["a", "a.b"] of String)
    all[0][0].value_for("a").as_int64.should eq(42_i64)
    all[0][0].value_for("a.b").as_string.should eq("x")
    all[1][0].paths.should eq(["z"] of String)
    all[1][0].value_for("z").as_bool.should be_true
    all[2][0].paths.should be_empty

    selected = CrystalClick::ObjectDocumentCodec.decode(
      {} of String => CrystalClick::BinaryDataType,
      literal,
      first_mark: 1,
      mark_count: 2
    )
    selected.map(&.size).should eq([1, 1])
    selected[0][0].paths.should eq(["z"] of String)
    selected[1][0].paths.should be_empty

    plan = CrystalClick::ObjectDocumentPlan.new(structures, {} of String => CrystalClick::BinaryDataType)
    authored = [
      [CrystalClick::ObjectDocument.new({
        "a"   => CrystalClick::BinaryValue.int64(42_i64),
        "a.b" => CrystalClick::BinaryValue.string("x"),
      } of String => CrystalClick::BinaryValue)],
      [CrystalClick::ObjectDocument.new({"z" => CrystalClick::BinaryValue.bool(true)} of String => CrystalClick::BinaryValue)],
      [CrystalClick::ObjectDocument.new({} of String => CrystalClick::BinaryValue)],
    ] of Array(CrystalClick::ObjectDocument)
    encoded = CrystalClick::ObjectDocumentCodec.encode(plan, authored)
    encoded.shared.roles.should eq([
      "root.elements.field.0.data", "root.elements.field.1.data", "root.sizes",
    ] of String)
    encoded.shared.stream("root.sizes").bytes.should eq(w123_literal_concat([
      w123_literal_u64(2_u64), w123_literal_u64(1_u64), w123_literal_u64(0_u64),
    ] of Bytes))
    encoded.shared.stream("root.sizes").offsets.should eq([0_u64, 8_u64, 16_u64, 24_u64])
    encoded.shared.stream("root.elements.field.0.data").bytes.should eq(
      Bytes[0x01_u8, 0x61_u8, 0x03_u8, 0x61_u8, 0x2e_u8, 0x62_u8, 0x01_u8, 0x7a_u8]
    )
    encoded.shared.stream("root.elements.field.0.data").offsets.should eq([0_u64, 6_u64, 8_u64, 8_u64])
    encoded.shared.stream("root.elements.field.1.data").bytes.should eq(w123_literal_shared_lanes.stream("root.elements.field.1.data").bytes)
    encoded.shared.stream("root.elements.field.1.data").offsets.should eq([0_u64, 14_u64, 17_u64, 17_u64])
  end

  it "rejects a corrupt last selected shared envelope without returning earlier documents" do
    structures = w123_literal_structure
    plan = CrystalClick::ObjectDocumentPlan.new(structures, {} of String => CrystalClick::BinaryDataType)
    documents = [
      [CrystalClick::ObjectDocument.new({"a" => CrystalClick::BinaryValue.string("one")} of String => CrystalClick::BinaryValue)],
      [CrystalClick::ObjectDocument.new({"b" => CrystalClick::BinaryValue.string("two")} of String => CrystalClick::BinaryValue)],
      [CrystalClick::ObjectDocument.new({"c" => CrystalClick::BinaryValue.string("x")} of String => CrystalClick::BinaryValue)],
    ] of Array(CrystalClick::ObjectDocument)
    encoded = CrystalClick::ObjectDocumentCodec.encode(plan, documents)

    role = "root.elements.field.1.data"
    original = encoded.shared.stream(role)
    damaged = original.bytes
    damaged[original.offset_at(2).to_i + 2] = 0x02_u8 # String length claims two bytes; one remains.
    damaged_roles = Hash(String, CrystalClick::BinaryBulkStream).new
    encoded.shared.roles.each do |name|
      lane = encoded.shared.stream(name)
      damaged_roles[name] = if name == role
                              CrystalClick::BinaryBulkStream.new(damaged, lane.offsets)
                            else
                              lane
                            end
    end
    malformed = w123_rewrap_streams(
      encoded,
      CrystalClick::BinaryBulkStreams.new(encoded.mark_count, damaged_roles)
    )

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectDocumentCodec.decode(
        {} of String => CrystalClick::BinaryDataType,
        malformed,
        first_mark: 0,
        mark_count: 3
      )
    end
  end

  it "checks all lane grids even when the selected window is empty" do
    structures = w123_literal_structure
    plan = CrystalClick::ObjectDocumentPlan.new(structures, {} of String => CrystalClick::BinaryDataType)
    documents = [
      [CrystalClick::ObjectDocument.new({"a" => CrystalClick::BinaryValue.string("x")} of String => CrystalClick::BinaryValue)],
      [CrystalClick::ObjectDocument.new({} of String => CrystalClick::BinaryValue)],
    ] of Array(CrystalClick::ObjectDocument)
    encoded = CrystalClick::ObjectDocumentCodec.encode(plan, documents)
    mismatched_shared_grid = CrystalClick::BinaryBulkStreams.new(
      encoded.mark_count - 1,
      encoded.shared.roles.to_h { |name| {name, encoded.shared.stream(name)} }
    )
    malformed = w123_rewrap_streams(encoded, mismatched_shared_grid)

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectDocumentCodec.decode(
        {} of String => CrystalClick::BinaryDataType,
        malformed,
        first_mark: 1,
        mark_count: 0
      )
    end
  end

  it "checks every Dynamic mark's outer row count before selecting a later window" do
    string = CrystalClick::BinaryDataType.primitive("String")
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["d"] of String),
      {"d" => CrystalClick::DynamicStructure.new([string] of CrystalClick::BinaryDataType)}
    )
    plan = CrystalClick::ObjectDocumentPlan.new(structures, {} of String => CrystalClick::BinaryDataType)
    documents = [
      [CrystalClick::ObjectDocument.new({"d" => CrystalClick::BinaryValue.string("first")} of String => CrystalClick::BinaryValue)],
      [CrystalClick::ObjectDocument.new({"d" => CrystalClick::BinaryValue.string("selected")} of String => CrystalClick::BinaryValue)],
    ] of Array(CrystalClick::ObjectDocument)
    encoded = CrystalClick::ObjectDocumentCodec.encode(plan, documents)
    # Only the unselected first mark is wrong. The selected second mark and its
    # child body remain exact, so checking selected marks alone would pass.
    malformed = w123_rewrap_streams(
      encoded,
      encoded.shared,
      [2_u64, 1_u64]
    )

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectDocumentCodec.decode(
        {} of String => CrystalClick::BinaryDataType,
        malformed,
        first_mark: 1,
        mark_count: 1
      )
    end
  end

  it "counts metadata path records even when no mark is selected" do
    strings = ["d0", "d1", "d2", "d3"] of String
    dynamics = Hash(String, CrystalClick::DynamicStructure).new
    strings.each do |path|
      dynamics[path] = CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)
    end
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(strings), dynamics
    )
    plan = CrystalClick::ObjectDocumentPlan.new(structures, {} of String => CrystalClick::BinaryDataType)
    encoded = CrystalClick::ObjectDocumentCodec.encode(
      plan,
      [[CrystalClick::ObjectDocument.new({} of String => CrystalClick::BinaryValue)]] of Array(CrystalClick::ObjectDocument)
    )
    tight = CrystalClick::BinaryCodecLimits.new(
      max_depth: 64,
      max_nodes: 3,
      max_elements: 3,
      max_bytes: 64 * 1024
    )

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectDocumentCodec.decode(
        {} of String => CrystalClick::BinaryDataType,
        encoded,
        first_mark: 0,
        mark_count: 0,
        limits: tight
      )
    end
  end

  it "requires every typed value exactly and preserves a typed Nullable NULL" do
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    plan = CrystalClick::ObjectDocumentPlan.new(w123_literal_structure, {"t" => uint64})
    missing = [[CrystalClick::ObjectDocument.new({} of String => CrystalClick::BinaryValue)]] of Array(CrystalClick::ObjectDocument)
    wrong = [[CrystalClick::ObjectDocument.new({"t" => CrystalClick::BinaryValue.string("1")} of String => CrystalClick::BinaryValue)]] of Array(CrystalClick::ObjectDocument)
    expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::ObjectDocumentCodec.encode(plan, missing) }
    expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::ObjectDocumentCodec.encode(plan, wrong) }

    nullable_string = CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.primitive("String"))
    nullable_plan = CrystalClick::ObjectDocumentPlan.new(w123_literal_structure, {"t" => nullable_string})
    present_null = [[CrystalClick::ObjectDocument.new({
      "t" => CrystalClick::BinaryValue.null(nullable_string),
    } of String => CrystalClick::BinaryValue)]] of Array(CrystalClick::ObjectDocument)
    encoded = CrystalClick::ObjectDocumentCodec.encode(nullable_plan, present_null)
    decoded = CrystalClick::ObjectDocumentCodec.decode({"t" => nullable_string}, encoded)
    decoded[0][0].has_path?("t").should be_true
    decoded[0][0].value_for("t").type.should eq(nullable_string)
    decoded[0][0].value_for("t").is_null?.should be_true
  end

  it "keeps shared String streams on their default profile when typed String uses WITH_SIZE" do
    string = CrystalClick::BinaryDataType.primitive("String")
    plan = CrystalClick::ObjectDocumentPlan.new(w123_literal_structure, {"t" => string})
    documents = [[CrystalClick::ObjectDocument.new({
      "t" => CrystalClick::BinaryValue.string("typed"),
      "s" => CrystalClick::BinaryValue.bool(true),
    } of String => CrystalClick::BinaryValue)]] of Array(CrystalClick::ObjectDocument)
    with_size = CrystalClick::BinaryBulkProfile.with_size_stream
    encoded = CrystalClick::ObjectDocumentCodec.encode(plan, documents, profile: with_size)
    encoded.typed_for("t").roles.should eq(["root.data", "root.string_sizes"] of String)
    encoded.shared.roles.should eq([
      "root.elements.field.0.data", "root.elements.field.1.data", "root.sizes",
    ] of String)
    decoded = CrystalClick::ObjectDocumentCodec.decode({"t" => string}, encoded, profile: with_size)
    decoded[0][0].value_for("t").as_string.should eq("typed")
    decoded[0][0].value_for("s").as_bool.should be_true

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectDocumentCodec.decode(
        {"t" => string}, encoded,
        profile: with_size,
        shared_profile: with_size
      )
    end
  end

  it "uses one byte budget across individually small metadata and value lanes" do
    bool = CrystalClick::BinaryDataType.primitive("Bool")
    plan = CrystalClick::ObjectDocumentPlan.new(w123_literal_structure, {"t" => bool})
    documents = [
      [CrystalClick::ObjectDocument.new({
        "t" => CrystalClick::BinaryValue.bool(true),
        "s" => CrystalClick::BinaryValue.bool(false),
      } of String => CrystalClick::BinaryValue)],
      [CrystalClick::ObjectDocument.new({
        "t" => CrystalClick::BinaryValue.bool(false),
        "s" => CrystalClick::BinaryValue.bool(true),
      } of String => CrystalClick::BinaryValue)],
    ] of Array(CrystalClick::ObjectDocument)
    encoded = CrystalClick::ObjectDocumentCodec.encode(plan, documents)

    # Every one physical lane is below 30 bytes, but their aggregate plus the
    # Object metadata is above 30. A per-child budget reset would incorrectly
    # admit this complete operation.
    maximum_lane = 0
    encoded.shared.roles.each do |role|
      maximum_lane = Math.max(maximum_lane, encoded.shared.stream(role).byte_size)
    end
    encoded.typed_for("t").roles.each do |role|
      maximum_lane = Math.max(maximum_lane, encoded.typed_for("t").stream(role).byte_size)
    end
    maximum_lane.should be < 30

    tight = CrystalClick::BinaryCodecLimits.new(
      max_depth: 64,
      max_nodes: 4_096,
      max_elements: 1_000,
      max_bytes: 30
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectDocumentCodec.decode(
        {"t" => bool}, encoded, limits: tight
      )
    end
  end

  it "preflights aggregate pending shared envelope frames, not one envelope at a time" do
    structures = w123_literal_structure
    plan = CrystalClick::ObjectDocumentPlan.new(structures, {} of String => CrystalClick::BinaryDataType)
    values = Hash(String, CrystalClick::BinaryValue).new
    40.times do |index|
      path = "p#{index.to_s.rjust(2, '0')}"
      values[path] = CrystalClick::BinaryValue.string("value")
    end
    documents = [[CrystalClick::ObjectDocument.new(values)]] of Array(CrystalClick::ObjectDocument)
    limits = CrystalClick::BinaryCodecLimits.new(
      max_depth: 64,
      max_nodes: 1_000_000,
      max_elements: 3_000_000,
      max_bytes: 250
    )

    # Each encoded String envelope is only seven bytes and its outer frame is
    # eight; the complete retained frame sum alone exceeds the 250-byte cap.
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentCodec.encode(plan, documents, limits: limits)
    end
  end

  it "bounds Dynamic roster collision-check allocations while building a typed plan" do
    dynamic_paths = Array(String).new(1_000)
    dynamics = Hash(String, CrystalClick::DynamicStructure).new
    empty_dynamic = CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)
    1_000.times do |index|
      path = "d#{index.to_s.rjust(4, '0')}"
      dynamic_paths << path
      dynamics[path] = empty_dynamic
    end
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(dynamic_paths),
      dynamics
    )
    typed_paths = Hash(String, CrystalClick::BinaryDataType).new
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    1_000.times do |index|
      typed_paths["t#{index.to_s.rjust(4, '0')}"] = uint8
    end

    # Fixture construction is deliberately outside the measurement. The old
    # nested scan copied all 1,000 Dynamic names for each typed path.
    GC.stats
    before_bytes = GC.stats.total_bytes
    plan = CrystalClick::ObjectDocumentPlan.new(structures, typed_paths)
    allocated_bytes = GC.stats.total_bytes - before_bytes

    plan.typed_path_count.should eq(1_000)
    allocated_bytes.should be < 2_u64 * 1024_u64 * 1024_u64
  end

  it "matches Dynamic path membership by exact raw bytes and retained identity" do
    source_a = String.new(Bytes[0x61_u8])
    source_nul = String.new(Bytes[0x61_u8, 0x00_u8])
    source_invalid = String.new(Bytes[0xff_u8])
    paths = [source_a, "a.b", "", source_nul, source_invalid] of String
    object = CrystalClick::ObjectStructure.new(paths)

    source_a.to_unsafe[0] = 0x78_u8
    source_nul.to_unsafe[0] = 0x62_u8
    source_invalid.to_unsafe[0] = 0xfe_u8
    paths.clear

    object.has_dynamic_path?("a").should be_true
    object.has_dynamic_path?("a.b").should be_true
    object.has_dynamic_path?("a.b.c").should be_false
    object.has_dynamic_path?("").should be_true
    object.has_dynamic_path?(String.new(Bytes[0x61_u8, 0x00_u8])).should be_true
    object.has_dynamic_path?(String.new(Bytes[0xff_u8])).should be_true
    object.has_dynamic_path?(String.new(Bytes[0xfe_u8])).should be_false

    returned = object.dynamic_paths
    returned.each do |path|
      path.to_unsafe[0] = 0x78_u8 unless path.empty?
    end
    returned.clear

    object.has_dynamic_path?("a").should be_true
    object.has_dynamic_path?("a.b").should be_true
    object.has_dynamic_path?("").should be_true
    object.has_dynamic_path?(String.new(Bytes[0x61_u8, 0x00_u8])).should be_true
    object.has_dynamic_path?(String.new(Bytes[0xff_u8])).should be_true
  end
end
