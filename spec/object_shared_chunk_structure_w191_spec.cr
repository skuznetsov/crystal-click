require "./spec_helper"

private def w191_var_uint(value : UInt64) : Bytes
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

private def w191_u64_le(value : UInt64) : Bytes
  Bytes.new(8) { |index| ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w191_concat(*parts : Bytes) : Bytes
  flattened = [] of UInt8
  parts.each { |part| part.each { |byte| flattened << byte } }
  Bytes.new(flattened.size) { |index| flattened[index] }
end

private def w191_raw_record(
  row_count : UInt64,
  paths : Array(String),
  data_marks : Tuple(UInt64, UInt64) = {0_u64, 0_u64},
  paths_marks : Tuple(UInt64, UInt64) = {0_u64, 0_u64},
  paths_substreams_metadata_marks : Tuple(UInt64, UInt64) = {0_u64, 0_u64},
) : Bytes
  bytes = [] of UInt8
  append = ->(part : Bytes) { part.each { |byte| bytes << byte } }
  append.call(w191_var_uint(row_count))
  append.call(w191_var_uint(paths.size.to_u64))
  paths.each do |path|
    raw = path.to_slice
    append.call(w191_var_uint(raw.size.to_u64))
    raw.each { |byte| bytes << byte }
  end
  {data_marks, paths_marks, paths_substreams_metadata_marks}.each do |pair|
    append.call(w191_u64_le(pair[0]))
    append.call(w191_u64_le(pair[1]))
  end
  Bytes.new(bytes.size) { |index| bytes[index] }
end

describe "W191 shared Object chunk structure record" do
  it "round-trips the exact empty zero-row record" do
    record = CrystalClick::ObjectSharedChunkStructure.new(
      0_u64,
      [] of String,
      {0_u64, 0_u64},
      {0_u64, 0_u64},
      {0_u64, 0_u64},
    )

    expected = Bytes.new(50) { 0_u8 }
    CrystalClick::ObjectSharedChunkStructureCodec.encode(record).should eq(expected)
    decoded = CrystalClick::ObjectSharedChunkStructureCodec.decode(expected)
    decoded.row_count.should eq(0_u64)
    decoded.paths.should be_empty
    decoded.data_marks.should eq({0_u64, 0_u64})
    decoded.paths_marks.should eq({0_u64, 0_u64})
    decoded.paths_substreams_metadata_marks.should eq({0_u64, 0_u64})
  end

  it "round-trips an authored nonzero VarUInt/path and six LE UInt64 marks" do
    record = CrystalClick::ObjectSharedChunkStructure.new(
      2_u64,
      ["a"] of String,
      {1_u64, 2_u64},
      {3_u64, 4_u64},
      {5_u64, 6_u64},
    )
    expected = Bytes[
      0x02_u8, 0x01_u8, 0x01_u8, 0x61_u8,
      0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x02_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x03_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x05_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x06_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    ]

    CrystalClick::ObjectSharedChunkStructureCodec.encode(record).should eq(expected)
    decoded = CrystalClick::ObjectSharedChunkStructureCodec.decode(expected)
    decoded.row_count.should eq(2_u64)
    decoded.paths.should eq(["a"] of String)
    decoded.data_marks.should eq({1_u64, 2_u64})
    decoded.paths_marks.should eq({3_u64, 4_u64})
    decoded.paths_substreams_metadata_marks.should eq({5_u64, 6_u64})
  end

  it "keeps row counts and mark coordinates in the full UInt64 domain without charging rows as edges" do
    max = UInt64::MAX
    record = CrystalClick::ObjectSharedChunkStructure.new(
      max,
      [] of String,
      {max, max},
      {max, 0_u64},
      {0_u64, max},
    )
    wire = w191_raw_record(max, [] of String, {max, max}, {max, 0_u64}, {0_u64, max})
    limits = CrystalClick::BinaryCodecLimits.new(1, 1, 0, wire.size)

    CrystalClick::ObjectSharedChunkStructureCodec.encode(record, limits).should eq(wire)
    decoded = CrystalClick::ObjectSharedChunkStructureCodec.decode(wire, limits)
    decoded.row_count.should eq(max)
    decoded.data_marks.should eq({max, max})
    decoded.paths_marks.should eq({max, 0_u64})
    decoded.paths_substreams_metadata_marks.should eq({0_u64, max})

    zero_rows_with_paths = CrystalClick::ObjectSharedChunkStructure.new(
      0_u64,
      ["a"] of String,
      {0_u64, 0_u64},
      {0_u64, 0_u64},
      {0_u64, 0_u64},
    )
    CrystalClick::ObjectSharedChunkStructureCodec.decode(
      CrystalClick::ObjectSharedChunkStructureCodec.encode(zero_rows_with_paths)
    ).paths.should eq(["a"] of String)
  end

  it "owns opaque path bytes and returns detached path collections" do
    first = String.new(Bytes[0x80_u8])
    second = String.new(Bytes[0xff_u8])
    record = CrystalClick::ObjectSharedChunkStructure.new(
      1_u64,
      [first, second],
      {0_u64, 0_u64},
      {0_u64, 0_u64},
      {0_u64, 0_u64},
    )
    first.to_unsafe[0] = 0x01_u8
    exposed = record.paths
    exposed[0].to_unsafe[0] = 0x02_u8
    exposed[0] = "changed"
    record.paths.map { |path| path.to_slice.to_a }.should eq([
      [0x80_u8], [0xff_u8],
    ])

    wire = CrystalClick::ObjectSharedChunkStructureCodec.encode(record)
    decoded = CrystalClick::ObjectSharedChunkStructureCodec.decode(wire)
    wire[3] = 0x03_u8
    decoded.paths.map { |path| path.to_slice.to_a }.should eq([
      [0x80_u8], [0xff_u8],
    ])
  end

  it "rejects duplicate or non-byte-sorted paths in values and on the wire" do
    marks = {0_u64, 0_u64}
    expect_raises(ArgumentError) do
      CrystalClick::ObjectSharedChunkStructure.new(1_u64, ["b", "a"], marks, marks, marks)
    end
    expect_raises(ArgumentError) do
      CrystalClick::ObjectSharedChunkStructure.new(1_u64, ["a", "a"], marks, marks, marks)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedChunkStructureCodec.decode(w191_raw_record(1_u64, ["b", "a"]))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedChunkStructureCodec.decode(w191_raw_record(1_u64, ["a", "a"]))
    end
  end

  it "rejects truncated, trailing, and noncanonical VarUInt input" do
    empty = Bytes.new(50) { 0_u8 }
    truncated = Bytes.new(empty.size - 1) { |index| empty[index] }
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedChunkStructureCodec.decode(truncated)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedChunkStructureCodec.decode(w191_concat(empty, Bytes[0_u8]))
    end

    nonminimal_row_count = w191_concat(Bytes[0x80_u8, 0x00_u8], Bytes.new(49) { 0_u8 })
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedChunkStructureCodec.decode(nonminimal_row_count)
    end
    overflow_row_count = w191_concat(Bytes.new(9) { 0x80_u8 }, Bytes[0x02_u8])
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedChunkStructureCodec.decode(overflow_row_count)
    end
    truncated_path = w191_concat(Bytes[0_u8, 1_u8, 2_u8, 0x61_u8], Bytes.new(48) { 0_u8 })
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedChunkStructureCodec.decode(truncated_path)
    end

    # The coarse count lower bound (one length byte + 48 suffix bytes) passes,
    # and the path itself is complete; the actual suffix is still one byte
    # short. The decoder must detect this before materializing path Strings.
    short_suffix = w191_concat(Bytes[0_u8, 1_u8, 1_u8, 0x61_u8], Bytes.new(47) { 0_u8 })
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedChunkStructureCodec.decode(short_suffix)
    end
  end

  it "preflights depth, nodes, path edges, bytes, and count-derived input before allocation" do
    empty = Bytes.new(50) { 0_u8 }
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedChunkStructureCodec.decode(
        empty, CrystalClick::BinaryCodecLimits.new(0, 10, 10, 100))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedChunkStructureCodec.decode(
        empty, CrystalClick::BinaryCodecLimits.new(1, 0, 10, 100))
    end
    one_path = w191_raw_record(1_u64, ["a"] of String)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedChunkStructureCodec.decode(
        one_path, CrystalClick::BinaryCodecLimits.new(1, 10, 0, 100))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedChunkStructureCodec.decode(
        one_path, CrystalClick::BinaryCodecLimits.new(1, 1, 10, 100))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedChunkStructureCodec.decode(
        empty, CrystalClick::BinaryCodecLimits.new(1, 10, 0, 49))
    end

    huge_count = w191_concat(
      Bytes[0_u8],
      w191_var_uint(Int32::MAX.to_u64),
      Bytes.new(48) { 0_u8 }
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedChunkStructureCodec.decode(
        huge_count,
        CrystalClick::BinaryCodecLimits.new(1, 2_147_483_648, Int32::MAX, 64)
      )
    end
  end

  it "composes records through one context and does not reset a borrowed budget" do
    record = CrystalClick::ObjectSharedChunkStructure.new(
      0_u64,
      [] of String,
      {0_u64, 0_u64},
      {0_u64, 0_u64},
      {0_u64, 0_u64},
    )
    limits = CrystalClick::BinaryCodecLimits.new(1, 2, 0, 150)
    write_budget = CrystalClick::BinaryCodecBudget.new(limits, true)
    writer = CrystalClick::BinaryCodecContext.new(limits, nil, true, write_budget)
    2.times { CrystalClick::ObjectSharedChunkStructureCodec.write_to(record, writer) }
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectSharedChunkStructureCodec.write_to(record, writer)
    end
    writer.finish_bytes.should eq(Bytes.new(100) { 0_u8 })
    write_budget.node_count.should eq(2_i64)

    three_records = Bytes.new(150) { 0_u8 }
    read_budget = CrystalClick::BinaryCodecBudget.new(limits)
    reader = CrystalClick::BinaryCodecContext.new(limits, three_records, false, read_budget)
    2.times do
      CrystalClick::ObjectSharedChunkStructureCodec.read_from(reader).row_count.should eq(0_u64)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedChunkStructureCodec.read_from(reader)
    end
    read_budget.node_count.should eq(2_i64)
    read_budget.wire_byte_count.should eq(150_i64)
  end

  it "accumulates shared path-node and edge budgets across composed records" do
    record = CrystalClick::ObjectSharedChunkStructure.new(
      1_u64,
      ["a"] of String,
      {1_u64, 2_u64},
      {3_u64, 4_u64},
      {5_u64, 6_u64},
    )
    wire = CrystalClick::ObjectSharedChunkStructureCodec.encode(record)
    two_records = w191_concat(wire, wire)

    node_limits = CrystalClick::BinaryCodecLimits.new(1, 3, 10, 512)
    node_writer = CrystalClick::BinaryCodecContext.new(node_limits, nil, true)
    CrystalClick::ObjectSharedChunkStructureCodec.write_to(record, node_writer)
    node_writer.node_count.should eq(2_i64)
    node_writer.element_count.should eq(1_i64)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectSharedChunkStructureCodec.write_to(record, node_writer)
    end

    node_reader = CrystalClick::BinaryCodecContext.new(node_limits, two_records)
    CrystalClick::ObjectSharedChunkStructureCodec.read_from(node_reader).paths.should eq(["a"] of String)
    node_reader.node_count.should eq(2_i64)
    node_reader.element_count.should eq(1_i64)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedChunkStructureCodec.read_from(node_reader)
    end

    edge_limits = CrystalClick::BinaryCodecLimits.new(1, 10, 1, 512)
    edge_writer = CrystalClick::BinaryCodecContext.new(edge_limits, nil, true)
    CrystalClick::ObjectSharedChunkStructureCodec.write_to(record, edge_writer)
    edge_writer.element_count.should eq(1_i64)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectSharedChunkStructureCodec.write_to(record, edge_writer)
    end

    edge_reader = CrystalClick::BinaryCodecContext.new(edge_limits, two_records)
    CrystalClick::ObjectSharedChunkStructureCodec.read_from(edge_reader).paths.should eq(["a"] of String)
    edge_reader.element_count.should eq(1_i64)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedChunkStructureCodec.read_from(edge_reader)
    end
  end

  it "rejects a borrowed context with the wrong direction" do
    record = CrystalClick::ObjectSharedChunkStructure.new(
      0_u64,
      [] of String,
      {0_u64, 0_u64},
      {0_u64, 0_u64},
      {0_u64, 0_u64},
    )
    limits = CrystalClick::BinaryCodecLimits.default
    reader = CrystalClick::BinaryCodecContext.new(limits, Bytes.new(50) { 0_u8 })
    writer = CrystalClick::BinaryCodecContext.new(limits, nil, true)

    expect_raises(ArgumentError) do
      CrystalClick::ObjectSharedChunkStructureCodec.write_to(record, reader)
    end
    expect_raises(ArgumentError) do
      CrystalClick::ObjectSharedChunkStructureCodec.read_from(writer)
    end
  end
end
