require "./spec_helper"

# Root-owned independent physical literals. These do not use the production
# encoder to construct decoder expectations.
private def w122_root_stream(bytes : Bytes, offsets : Array(UInt64))
  CrystalClick::BinaryBulkStream.new(bytes, offsets)
end

private def w122_root_set(marks : Int, lanes : Hash(String, CrystalClick::BinaryBulkStream))
  CrystalClick::BinaryBulkStreams.new(marks, lanes)
end

private def w122_root_limits(nodes = 1_000_000, edges = 3_000_000, bytes = 64 * 1024 * 1024, depth = 64)
  CrystalClick::BinaryCodecLimits.new(max_depth: depth, max_nodes: nodes,
    max_elements: edges, max_bytes: bytes)
end

describe "W122 independent bulk cardinality and ownership attack" do
  it "validates hidden Nullable float payload while preserving active raw bits" do
    float = CrystalClick::BinaryDataType.primitive("Float64")
    type = CrystalClick::BinaryDataType.nullable(float)
    # Mark0: a logically NULL value hides an arbitrary NaN payload. Mark1:
    # negative zero is active. No conversion through host Float is allowed.
    nested = Bytes[1, 0, 0, 0, 0, 0, 248, 127, 0, 0, 0, 0, 0, 0, 0, 128]
    lanes = w122_root_set(2, {
      "root.nulls"       => w122_root_stream(Bytes[1, 0], [0_u64, 1_u64, 2_u64]),
      "root.nested.data" => w122_root_stream(nested, [0_u64, 8_u64, 16_u64]),
    })
    rows = CrystalClick::BinaryBulkCodec.decode(type, lanes, [1_u64, 1_u64])
    rows[0][0].type.should eq(type)
    rows[0][0].is_null?.should be_true
    rows[0][0].element_count.should eq(0)
    rows[1][0].element_at(0).as_float64_bits.should eq(0x8000000000000000_u64)
    canonical = CrystalClick::BinaryBulkCodec.encode(type, rows)
    canonical.stream("root.nested.data").bytes.should eq(Bytes[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 128])

    truncated = w122_root_set(1, {
      "root.nulls"       => w122_root_stream(Bytes[1], [0_u64, 1_u64]),
      "root.nested.data" => w122_root_stream(Bytes[0], [0_u64, 1_u64]),
    })
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(type, truncated, [1_u64])
    end
  end

  it "has independent root occurrences and flattened Array element counts" do
    type = CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.primitive("String"))
    # Three arrays: [], ['a', 'bc'], []. Only two String children.
    lanes = w122_root_set(1, {
      "root.sizes"         => w122_root_stream(Bytes[0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], [0_u64, 24_u64]),
      "root.elements.data" => w122_root_stream(Bytes[1, 97, 2, 98, 99], [0_u64, 5_u64]),
    })
    rows = CrystalClick::BinaryBulkCodec.decode(type, lanes, [3_u64]).first
    rows.map(&.element_count).should eq([0, 2, 0])
    rows[1].elements.map(&.as_string).should eq(["a", "bc"])
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(type, lanes, [2_u64])
    end
    # A count that cannot fit a host collection must fail before child allocation.
    impossible = w122_root_set(1, {
      "root.sizes"         => w122_root_stream(Bytes[255, 255, 255, 255, 255, 255, 255, 255], [0_u64, 8_u64]),
      "root.elements.data" => w122_root_stream(Bytes.empty, [0_u64, 0_u64]),
    })
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(type, impossible, [1_u64])
    end
  end

  it "keeps Map duplicates and order in independent columnar key/value lanes" do
    type = CrystalClick::BinaryDataType.map(CrystalClick::BinaryDataType.primitive("String"), CrystalClick::BinaryDataType.primitive("UInt8"))
    lanes = w122_root_set(1, {
      "root.sizes"                 => w122_root_stream(Bytes[2, 0, 0, 0, 0, 0, 0, 0], [0_u64, 8_u64]),
      "root.elements.field.0.data" => w122_root_stream(Bytes[1, 107, 1, 107], [0_u64, 4_u64]),
      "root.elements.field.1.data" => w122_root_stream(Bytes[7, 9], [0_u64, 2_u64]),
    })
    result = CrystalClick::BinaryBulkCodec.decode(type, lanes, [1_u64]).first.first
    result.element_count.should eq(4)
    result.element_at(0).as_string.should eq("k")
    result.element_at(1).bytes.should eq(Bytes[7])
    result.element_at(2).as_string.should eq("k")
    result.element_at(3).bytes.should eq(Bytes[9])
    encoded = CrystalClick::BinaryBulkCodec.encode(type, [[result]])
    lanes.roles.sort.each do |role|
      encoded.stream(role).bytes.should eq(lanes.stream(role).bytes)
      encoded.stream(role).offsets.should eq(lanes.stream(role).offsets)
    end
  end

  it "parses no unselected body and allows repeated offsets for empty children" do
    type = CrystalClick::BinaryDataType.primitive("String")
    # The first body is a truncated VarUInt and must be ignored for mark1.
    lanes = w122_root_set(3, {
      "root.data" => w122_root_stream(Bytes[128, 1, 120], [0_u64, 1_u64, 3_u64, 3_u64]),
    })
    selected = CrystalClick::BinaryBulkCodec.decode(type, lanes, [1_u64, 1_u64, 0_u64], first_mark: 1, mark_count: 2)
    selected.map { |mark| mark.map(&.as_string) }.should eq([["x"], [] of String])
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(type, lanes, [1_u64, 1_u64, 0_u64])
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(type, lanes, [1_u64, 0_u64, 0_u64], first_mark: 1, mark_count: 1)
    end
    CrystalClick::BinaryBulkCodec.decode(type, lanes, [1_u64, 1_u64, 0_u64], first_mark: 1, mark_count: 0).should be_empty
  end

  it "rejects an invalid selected final mark before returning any values" do
    type = CrystalClick::BinaryDataType.primitive("String")
    lanes = w122_root_set(2, {
      "root.data" => w122_root_stream(Bytes[1, 120, 2, 121], [0_u64, 2_u64, 4_u64]),
    })
    returned = false
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(type, lanes, [1_u64, 1_u64])
      returned = true
    end
    returned.should be_false
  end

  it "requires placeholders even for Nothing and empty Tuple occurrences" do
    nothing = CrystalClick::BinaryDataType.primitive("Nothing")
    empty_tuple = CrystalClick::BinaryDataType.tuple([] of CrystalClick::BinaryDataType)
    literal = w122_root_set(1, {"root.data" => w122_root_stream(Bytes[48, 48], [0_u64, 2_u64])})
    CrystalClick::BinaryBulkCodec.decode(nothing, literal, [2_u64]).first.each { |value| value.is_null?.should be_true }
    CrystalClick::BinaryBulkCodec.decode(empty_tuple, literal, [2_u64]).first.map(&.element_count).should eq([0, 0])
    nullable = CrystalClick::BinaryDataType.nullable(nothing)
    lanes = w122_root_set(1, {
      "root.nulls"       => w122_root_stream(Bytes[1, 1], [0_u64, 2_u64]),
      "root.nested.data" => w122_root_stream(Bytes[48, 48], [0_u64, 2_u64]),
    })
    CrystalClick::BinaryBulkCodec.decode(nullable, lanes, [2_u64]).first.each do |value|
      value.type.should eq(nullable)
      value.is_null?.should be_true
    end
    invalid = w122_root_set(1, {
      "root.nulls"       => w122_root_stream(Bytes[0], [0_u64, 1_u64]),
      "root.nested.data" => w122_root_stream(Bytes[48], [0_u64, 1_u64]),
    })
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(nullable, invalid, [1_u64])
    end
  end

  it "detaches owners but rejects foreign roles and malformed whole grids" do
    source = Bytes[1, 120]
    offsets = [0_u64, 2_u64]
    stream = w122_root_stream(source, offsets)
    source[1] = 121_u8
    offsets[1] = 1_u64
    stream.bytes.should eq(Bytes[1, 120])
    stream.offsets.should eq([0_u64, 2_u64])
    copy = stream.bytes
    copy[1] = 122_u8
    grid_copy = stream.offsets
    grid_copy[1] = 0_u64
    stream.bytes.should eq(Bytes[1, 120])
    stream.offsets.should eq([0_u64, 2_u64])
    role = String.new("root.data".to_slice)
    collection = {role => stream}
    owner = w122_root_set(1, collection)
    collection.clear
    # Crystal String slices are read-only. Deliberate unsafe mutation attacks
    # the detached owner without mistaking Slice's guard for owner isolation.
    role.to_unsafe[0] = 'X'.ord.to_u8
    snapshot = owner.roles
    snapshot.first.to_unsafe[0] = 'Y'.ord.to_u8
    owner.roles.should eq(["root.data"])
    owner.stream("root.data").bytes.should eq(Bytes[1, 120])
    type = CrystalClick::BinaryDataType.primitive("String")
    [{"foreign" => stream}, {"root.data" => stream, "foreign" => stream},
     {"root.data" => w122_root_stream(Bytes[1, 120], [1_u64, 2_u64])},
     {"root.data" => w122_root_stream(Bytes[1, 120], [0_u64, 1_u64])}].each do |lanes|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryBulkCodec.decode(type, w122_root_set(1, lanes), [1_u64], mark_count: 0)
      end
    end
  end

  it "keeps directional, cross-call budgets and selected-wire charging" do
    type = CrystalClick::BinaryDataType.primitive("String")
    lanes = w122_root_set(2, {"root.data" => w122_root_stream(Bytes[128, 1, 120], [0_u64, 1_u64, 3_u64])})
    budget = CrystalClick::BinaryCodecBudget.new(w122_root_limits(bytes: 2))
    CrystalClick::BinaryBulkCodec.decode_with_budget(type, lanes, [1_u64, 1_u64], budget, first_mark: 1, mark_count: 1).first.first.as_string.should eq("x")
    budget.wire_byte_count.should eq(2_i64)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode_with_budget(type, lanes, [1_u64, 1_u64], budget, first_mark: 1, mark_count: 1)
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryBulkCodec.decode_with_budget(type, lanes, [1_u64, 1_u64], CrystalClick::BinaryCodecBudget.new(w122_root_limits, true))
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryBulkCodec.encode_with_budget(type, [[CrystalClick::BinaryValue.string("x")]], CrystalClick::BinaryCodecBudget.new(w122_root_limits))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(type, lanes, [1_u64, 1_u64], first_mark: Int128::MAX, mark_count: 0)
    end
  end

  it "supports an ordinary 8192-row granule without inheriting the scalar node limit" do
    type = CrystalClick::BinaryDataType.primitive("String")
    values = Array(CrystalClick::BinaryValue).new(8192) { CrystalClick::BinaryValue.string("x") }
    encoded = CrystalClick::BinaryBulkCodec.encode(type, [values])
    encoded.stream("root.data").offsets.should eq([0_u64, 16384_u64])
    decoded = CrystalClick::BinaryBulkCodec.decode(type, encoded, [8192_u64]).first
    decoded.size.should eq(8192)
    decoded.each { |value| value.as_string.should eq("x") }
  end
end
