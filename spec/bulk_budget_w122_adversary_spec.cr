require "./spec_helper"

private def w122_exact_limits(nodes = 1_000_000, edges = 3_000_000, bytes = 64 * 1024 * 1024, depth = 64)
  CrystalClick::BinaryCodecLimits.new(max_depth: depth, max_nodes: nodes,
    max_elements: edges, max_bytes: bytes)
end

describe "W122 independently derived aggregate budget boundaries" do
  it "reserves previous frames before growing a borrowed envelope" do
    value = CrystalClick::BinaryValue.bool(true)
    budget = CrystalClick::BinaryCodecBudget.new(w122_exact_limits(bytes: 5), true)
    CrystalClick::BinaryValueCodec.encode_borrowed(value, budget, reserved_wire_bytes: 3_u64).should eq(Bytes[45, 1])
    budget.wire_byte_count.should eq(0_i64)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode_borrowed(value,
        CrystalClick::BinaryCodecBudget.new(w122_exact_limits(bytes: 5), true), reserved_wire_bytes: 4_u64)
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryValueCodec.encode_borrowed(value,
        CrystalClick::BinaryCodecBudget.new(w122_exact_limits(bytes: 5)), reserved_wire_bytes: 3_u64)
    end
  end

  it "charges descriptor, complete grid metadata and selected String values exactly once" do
    type = CrystalClick::BinaryDataType.primitive("String")
    literal = CrystalClick::BinaryBulkStreams.new(2, {
      "root.data" => CrystalClick::BinaryBulkStream.new(Bytes[1, 97, 1, 98], [0_u64, 2_u64, 4_u64]),
    })
    values = [[CrystalClick::BinaryValue.string("a")], [CrystalClick::BinaryValue.string("b")]]
    # One descriptor, K+1=3 offset records, K=2 row-count records, and
    # two selected value nodes. Metadata contributes five edges. The wire
    # includes only the two independently authored String frames.
    limits = w122_exact_limits(nodes: 8, edges: 5, bytes: 4)
    read = CrystalClick::BinaryCodecBudget.new(limits)
    decoded = CrystalClick::BinaryBulkCodec.decode_with_budget(type, literal, [1_u64, 1_u64], read)
    decoded.map { |mark| mark.map(&.as_string) }.should eq([["a"], ["b"]])
    decoded.each { |mark| mark.first.type.should eq(type) }
    {read.node_count, read.element_count, read.wire_byte_count}.should eq({8_i64, 5_i64, 4_i64})
    write = CrystalClick::BinaryCodecBudget.new(limits, true)
    CrystalClick::BinaryBulkCodec.encode_with_budget(type, values, write).stream("root.data").bytes.should eq(Bytes[1, 97, 1, 98])
    {write.node_count, write.element_count, write.wire_byte_count}.should eq({8_i64, 5_i64, 4_i64})

    [w122_exact_limits(nodes: 7), w122_exact_limits(edges: 4), w122_exact_limits(bytes: 3)].each do |too_small|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryBulkCodec.decode(type, literal, [1_u64, 1_u64], limits: too_small)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryBulkCodec.encode(type, values, limits: too_small)
      end
    end
  end

  it "still charges terminal-grid metadata when there are no real marks" do
    type = CrystalClick::BinaryDataType.primitive("UInt8")
    literal = CrystalClick::BinaryBulkStreams.new(0, {
      "root.data" => CrystalClick::BinaryBulkStream.new(Bytes.empty, [0_u64]),
    })
    # The descriptor and one terminal offset exist even without values.
    limits = w122_exact_limits(nodes: 2, edges: 1, bytes: 0)
    read = CrystalClick::BinaryCodecBudget.new(limits)
    CrystalClick::BinaryBulkCodec.decode_with_budget(type, literal, [] of UInt64, read).should be_empty
    {read.node_count, read.element_count, read.wire_byte_count}.should eq({2_i64, 1_i64, 0_i64})
    write = CrystalClick::BinaryCodecBudget.new(limits, true)
    encoded = CrystalClick::BinaryBulkCodec.encode_with_budget(type, [] of Array(CrystalClick::BinaryValue), write)
    encoded.stream("root.data").offsets.should eq([0_u64])
    {write.node_count, write.element_count, write.wire_byte_count}.should eq({2_i64, 1_i64, 0_i64})
  end

  it "does not charge an eight MiB unselected body to a two-byte window" do
    type = CrystalClick::BinaryDataType.primitive("String")
    unselected_size = 8 * 1024 * 1024
    raw = Bytes.new(unselected_size + 2, 128_u8)
    raw[unselected_size] = 1_u8
    raw[unselected_size + 1] = 120_u8
    literal = CrystalClick::BinaryBulkStreams.new(2, {
      "root.data" => CrystalClick::BinaryBulkStream.new(raw, [0_u64, unselected_size.to_u64, (unselected_size + 2).to_u64]),
    })
    read = CrystalClick::BinaryCodecBudget.new(w122_exact_limits(bytes: 2))
    CrystalClick::BinaryBulkCodec.decode_with_budget(type, literal, [1_u64, 1_u64], read, first_mark: 1, mark_count: 1).first.first.as_string.should eq("x")
    read.wire_byte_count.should eq(2_i64)
  end

  it "preflights the aggregate hidden Nullable defaults before visiting values" do
    type = CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.fixed_string(3))
    values = [[CrystalClick::BinaryValue.nullable(type), CrystalClick::BinaryValue.nullable(type), CrystalClick::BinaryValue.nullable(type)]]
    # Three null-map bytes plus three hidden, canonical FixedString(3)
    # payloads require twelve bytes, not one individually legal default.
    budget = CrystalClick::BinaryCodecBudget.new(w122_exact_limits(bytes: 11), true)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkCodec.encode_with_budget(type, values, budget)
    end
    budget.wire_byte_count.should eq(0_i64)
    budget.node_count.should eq(7_i64) # two descriptor + five metadata records
    exact = CrystalClick::BinaryBulkCodec.encode(type, values, limits: w122_exact_limits(bytes: 12))
    exact.stream("root.nulls").bytes.should eq(Bytes[1, 1, 1])
    exact.stream("root.nested.data").bytes.should eq(Bytes.new(9, 0_u8))
  end

  it "uses recursive type depth rather than just outer mark depth" do
    leaf = CrystalClick::BinaryDataType.primitive("UInt8")
    inner = CrystalClick::BinaryDataType.array(leaf)
    middle = CrystalClick::BinaryDataType.array(inner)
    outer = CrystalClick::BinaryDataType.array(middle)
    value = CrystalClick::BinaryValue.array(outer, [CrystalClick::BinaryValue.array(middle, [CrystalClick::BinaryValue.array(inner, [] of CrystalClick::BinaryValue)])])
    exact = CrystalClick::BinaryBulkCodec.encode(outer, [[value]], limits: w122_exact_limits(depth: 4))
    decoded = CrystalClick::BinaryBulkCodec.decode(outer, exact, [1_u64], limits: w122_exact_limits(depth: 4)).first.first
    decoded.type.should eq(outer)
    decoded.element_count.should eq(1)
    decoded.element_at(0).type.should eq(middle)
    decoded.element_at(0).element_count.should eq(1)
    decoded.element_at(0).element_at(0).type.should eq(inner)
    decoded.element_at(0).element_at(0).element_count.should eq(0)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkCodec.encode(outer, [[value]], limits: w122_exact_limits(depth: 3))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(outer, exact, [1_u64], limits: w122_exact_limits(depth: 3))
    end
  end
end
