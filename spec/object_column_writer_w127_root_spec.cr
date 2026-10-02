require "./spec_helper"

private def w127_root_plan : CrystalClick::ObjectDocumentPlan
  old_object = CrystalClick::StructureStatistics.new([99_u64], [CrystalClick::StructureStatistic.new("wrong", 99_u64)])
  old_dynamic = CrystalClick::StructureStatistics.new([99_u64, 99_u64], [CrystalClick::StructureStatistic.new("wrong", 99_u64)])
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new(["d"], statistics: old_object),
    {"d" => CrystalClick::DynamicStructure.new([CrystalClick::BinaryDataType.primitive("String")], statistics: old_dynamic)}
  )
  CrystalClick::ObjectDocumentPlan.new(structures, {"t" => CrystalClick::BinaryDataType.primitive("UInt64")})
end

private def w127_root_documents : Array(Array(CrystalClick::ObjectDocument))
  [
    [CrystalClick::ObjectDocument.new({"t" => CrystalClick::BinaryValue.uint64(1_u64), "d" => CrystalClick::BinaryValue.string("s"), "raw.dot" => CrystalClick::BinaryValue.bool(true)})],
    [CrystalClick::ObjectDocument.new({"t" => CrystalClick::BinaryValue.uint64(2_u64), "d" => CrystalClick::BinaryValue.null, "raw.dot" => CrystalClick::BinaryValue.null})],
    [CrystalClick::ObjectDocument.new({"t" => CrystalClick::BinaryValue.uint64(3_u64), "d" => CrystalClick::BinaryValue.int64(-7_i64), "raw.dot" => CrystalClick::BinaryValue.bool(false)})],
    [CrystalClick::ObjectDocument.new({"t" => CrystalClick::BinaryValue.uint64(4_u64)})],
  ]
end

private def w127_root_empty_plan : CrystalClick::ObjectDocumentPlan
  set = CrystalClick::ObjectDynamicStructureSet.new(CrystalClick::ObjectStructure.new([] of String), {} of String => CrystalClick::DynamicStructure)
  CrystalClick::ObjectDocumentPlan.new(set, {} of String => CrystalClick::BinaryDataType)
end

private def w127_root_large_limits : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(max_depth: 64, max_nodes: 500_000, max_elements: 1_000_000, max_bytes: 16 * 1024 * 1024)
end

private def w127_root_grid(bytes : Bytes) : Array(Tuple(UInt64, UInt64, UInt64))
  raise "misaligned root grid" unless bytes.size % 24 == 0
  Array(Tuple(UInt64, UInt64, UInt64)).new(bytes.size // 24) do |index|
    words = StaticArray(UInt64, 3).new(0_u64)
    3.times do |word|
      8.times { |byte| words[word] |= bytes[index * 24 + word * 8 + byte].to_u64 << (8 * byte) }
    end
    {words[0], words[1], words[2]}
  end
end

# Independent decoder of the literal-only frames promised by the writer.
# It deliberately does not use production transport or metadata codecs.
private def w127_root_raw(data : Bytes) : Bytes
  output = IO::Memory.new
  cursor = 0
  while cursor < data.size
    data[cursor + 16].should eq(0x82_u8)
    compressed = 0_u32
    raw = 0_u32
    4.times do |index|
      compressed |= data[cursor + 17 + index].to_u32 << (8 * index)
      raw |= data[cursor + 21 + index].to_u32 << (8 * index)
    end
    payload = cursor + 25
    token = data[payload]
    (token & 15_u8).should eq(0_u8)
    length = (token >> 4).to_i
    payload += 1
    if length == 15
      loop do
        extension = data[payload]
        payload += 1
        length += extension.to_i
        break if extension < 255
      end
    end
    length.to_u32.should eq(raw)
    (payload + length).should eq(cursor + 16 + compressed.to_i)
    output.write(data[payload, length])
    cursor += 16 + compressed.to_i
  end
  output.to_slice
end

describe "W127 root fresh column statistics" do
  it "replaces poisoned statistics using non-NULL counts without mutating the input plan" do
    plan = w127_root_plan
    fresh = CrystalClick::ObjectDocumentStatistics.recompute(plan, w127_root_documents)
    fresh.structures.object.statistics.not_nil!.should eq(CrystalClick::StructureStatistics.new(
      [2_u64], [CrystalClick::StructureStatistic.new("raw.dot", 2_u64)]))
    fresh.structures.dynamic_for("d").canonical_variant_names.should eq(["SharedVariant", "String"])
    fresh.structures.dynamic_for("d").statistics.not_nil!.should eq(CrystalClick::StructureStatistics.new(
      [1_u64, 1_u64], [CrystalClick::StructureStatistic.new("Int64", 1_u64)]))
    plan.structures.object.statistics.not_nil!.count_at(0).should eq(99_u64)
    plan.structures.dynamic_for("d").statistics.not_nil!.count_at(0).should eq(99_u64)
    fresh.typed_paths.should eq(plan.typed_paths)
  end

  it "keeps a same-SQL-name spill separate from its ordinary descriptor" do
    ordinary = CrystalClick::BinaryDataType.decimal(32, 5, 2)
    spill = CrystalClick::BinaryDataType.decimal(64, 5, 2)
    ordinary.name.should eq("Decimal(5, 2)")
    spill.name.should eq(ordinary.name)
    plan = CrystalClick::ObjectDocumentPlan.new(CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["d"]), {"d" => CrystalClick::DynamicStructure.new([ordinary])}), {} of String => CrystalClick::BinaryDataType)
    documents = [[
      CrystalClick::ObjectDocument.new({"d" => CrystalClick::BinaryValue.fixed(ordinary, Bytes[7, 0, 0, 0])}),
      CrystalClick::ObjectDocument.new({"d" => CrystalClick::BinaryValue.fixed(spill, Bytes[7, 0, 0, 0, 0, 0, 0, 0])}),
    ]]
    fresh = CrystalClick::ObjectDocumentStatistics.recompute(plan, documents)
    fresh.structures.dynamic_for("d").statistics.not_nil!.should eq(CrystalClick::StructureStatistics.new(
      [1_u64, 1_u64], [CrystalClick::StructureStatistic.new("Decimal(5, 2)", 1_u64)]))
    fresh.structures.object.statistics.not_nil!.counts.should eq([2_u64])
  end

  it "retains first-seen spilled names rather than promoting a late frequent type" do
    plan = CrystalClick::ObjectDocumentPlan.new(CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["d"]), {"d" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)}), {} of String => CrystalClick::BinaryDataType)
    rows = Array(CrystalClick::ObjectDocument).new(257) do |index|
      type = CrystalClick::BinaryDataType.fixed_string(index + 1)
      CrystalClick::ObjectDocument.new({"d" => CrystalClick::BinaryValue.fixed(type, Bytes.new(index + 1, 0_u8))})
    end
    3.times { rows << rows[256] }
    rows << rows[0]
    stats = CrystalClick::ObjectDocumentStatistics.recompute(plan, [rows], w127_root_large_limits).structures.dynamic_for("d").statistics.not_nil!
    stats.counts.should eq([261_u64])
    stats.shared_count.should eq(256)
    names = stats.shared.to_h { |entry| {entry.name, entry.count} }
    names["FixedString(1)"].should eq(2_u64)
    names.has_key?("FixedString(257)").should be_false
  end

  it "retains 10000 raw shared paths and still counts an early path after saturation" do
    fields = Hash(String, CrystalClick::BinaryValue).new
    10_000.times { |index| fields["p#{index.to_s.rjust(5, '0')}"] = CrystalClick::BinaryValue.bool(true) }
    fields["z.late"] = CrystalClick::BinaryValue.bool(true)
    first = CrystalClick::ObjectDocument.new(fields)
    late = CrystalClick::ObjectDocument.new({"p00000" => CrystalClick::BinaryValue.bool(false), "z.late" => CrystalClick::BinaryValue.bool(false)})
    stats = CrystalClick::ObjectDocumentStatistics.recompute(w127_root_empty_plan, [[first], [late, late, late]], w127_root_large_limits).structures.object.statistics.not_nil!
    stats.counts.should be_empty
    stats.shared_count.should eq(10_000)
    names = stats.shared.to_h { |entry| {entry.name, entry.count} }
    names["p00000"].should eq(4_u64)
    names.has_key?("z.late").should be_false
  end

  it "rejects huge spilled SQL-name metadata before proportional rendering allocations" do
    type = CrystalClick::BinaryDataType.tuple([CrystalClick::BinaryDataType.primitive("UInt8")], ["'" * (4 * 1024 * 1024)])
    value = CrystalClick::BinaryValue.tuple(type, [CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[1])])
    documents = [[CrystalClick::ObjectDocument.new({"x" => value})]]
    plan = w127_root_empty_plan
    limits = CrystalClick::BinaryCodecLimits.new(max_depth: 64, max_nodes: 10_000, max_elements: 10_000, max_bytes: 256)
    GC.stats
    before = GC.stats.total_bytes
    expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::ObjectDocumentStatistics.recompute(plan, documents, limits) }
    (GC.stats.total_bytes - before).should be < 256_u64 * 1024_u64
  end

  it "preflights both unknown document paths and preserved typed paths before copies" do
    path = "x" * (4 * 1024 * 1024)
    row = CrystalClick::ObjectDocument.new({path => CrystalClick::BinaryValue.bool(true)})
    empty_plan = w127_root_empty_plan
    typed_plan = CrystalClick::ObjectDocumentPlan.new(empty_plan.structures, {path => CrystalClick::BinaryDataType.primitive("Bool")})
    documents = [[row]]
    limits = CrystalClick::BinaryCodecLimits.new(max_depth: 64, max_nodes: 10_000, max_elements: 10_000, max_bytes: 256)
    {empty_plan, typed_plan}.each do |plan|
      GC.stats
      before = GC.stats.total_bytes
      expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::ObjectDocumentStatistics.recompute(plan, documents, limits) }
      (GC.stats.total_bytes - before).should be < 256_u64 * 1024_u64
    end
  end

  it "preserves a present zero statistical state and rejects a reading budget" do
    fresh = CrystalClick::ObjectDocumentStatistics.recompute(w127_root_empty_plan, [] of Array(CrystalClick::ObjectDocument))
    fresh.structures.object.statistics.should_not be_nil
    fresh.structures.object.statistics.not_nil!.counts.should be_empty
    fresh.structures.object.statistics.not_nil!.shared.should be_empty
    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentStatistics.recompute_with_budget(w127_root_plan, w127_root_documents,
        CrystalClick::BinaryCodecBudget.new(w127_root_large_limits))
    end
  end
end

describe "W127 root physical metadata composition" do
  it "maps the repeated pre-flag coordinate across frames and preserves ordinary prefix rules" do
    raw = Bytes.new(12) { |index| index.to_u8 }
    exact = CrystalClick::CompressedMarkWriter.encode_metadata(raw, 8, [2_u64, 1_u64], frame_bytes: 4)
    exact.data.size.should eq(90)
    w127_root_grid(exact.marks).should eq([{60_u64, 0_u64, 2_u64}, {60_u64, 0_u64, 1_u64}, {90_u64, 0_u64, 0_u64}])
    crossed = CrystalClick::CompressedMarkWriter.encode_metadata(raw, 9, [2_u64, 1_u64], frame_bytes: 4)
    w127_root_grid(crossed.marks).should eq([{60_u64, 1_u64, 2_u64}, {60_u64, 1_u64, 1_u64}, {90_u64, 0_u64, 0_u64}])
    expect_raises(ArgumentError) do
      CrystalClick::CompressedMarkWriter.encode(raw, [8_u64, 12_u64], [1_u64], prefix_size: 8, frame_bytes: 4)
    end
  end

  it "checks the complete metadata mark record budget before allocating repeated offsets" do
    rows = Array(UInt64).new(100_000, 1_u64)
    budget = CrystalClick::CompressedStreamBudget.new(CrystalClick::CompressedStreamLimits.new(max_records: 2), writing: true)
    GC.stats
    before = GC.stats.total_bytes
    error = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::CompressedMarkWriter.encode_metadata(Bytes[0, 1, 2, 3], 2, rows, frame_bytes: 4, budget: budget)
    end
    error.message.should eq("compressed stream header-record limit exceeded")
    (GC.stats.total_bytes - before).should be < 256_u64 * 1024_u64
  end

  it "owns all column lanes, uses outer rows for sparse arms, and detaches returned bytes" do
    files = CrystalClick::ObjectDocumentColumnWriter.encode("payload", w127_root_plan, w127_root_documents, frame_bytes: 16)
    files.plan.structures.object.statistics.not_nil!.counts.should eq([2_u64])
    expected = ["payload.object_structure", "payload.d.dynamic_structure", "payload.d.variant_discr", "payload.t", "payload.d.String", "payload.d.SharedVariant",
                "payload.object_shared_data.size0", "payload.object_shared_data%2Epaths", "payload.object_shared_data%2Evalues"].sort
    files.stream_names.should eq(expected)
    files.file_names.should eq(expected.flat_map { |name| [name + ".bin", name + ".mrk2"] }.sort)
    w127_root_raw(files.pair_for("payload.object_structure").data).should eq(
      Bytes[4, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0x64, 0, 1, 2, 1, 7, 0x72, 0x61, 0x77, 0x2e, 0x64, 0x6f, 0x74, 2])
    w127_root_raw(files.pair_for("payload.d.dynamic_structure").data).should eq(
      Bytes[4, 0, 0, 0, 0, 0, 0, 0, 1, 0x15, 1, 1, 1, 1, 5, 0x49, 0x6e, 0x74, 0x36, 0x34, 1])
    object_grid = w127_root_grid(files.pair_for("payload.object_structure").marks)
    object_grid[0, 4].should eq(Array.new(4, {0_u64, 12_u64, 1_u64}))
    # Literal frames: 16 bytes require token + one extension + 25 header
    # bytes (43); the remaining eight require token + 25 header bytes (34).
    object_grid.last.should eq({77_u64, 0_u64, 0_u64})
    grid = w127_root_grid(files.pair_for("payload.d.String").marks)
    grid.map(&.[2]).should eq([1_u64, 1_u64, 1_u64, 1_u64, 0_u64])
    {grid[1][0], grid[1][1]}.should eq({grid[2][0], grid[2][1]})
    {grid[2][0], grid[2][1]}.should eq({grid[3][0], grid[3][1]})
    original = files.file_bytes("payload.d.String.bin")
    changed = files.file_bytes("payload.d.String.bin")
    changed[0] ^= 0xff_u8
    files.file_bytes("payload.d.String.bin").should eq(original)
    hashed = CrystalClick::ObjectDocumentColumnWriter.encode("payload", w127_root_plan, w127_root_documents, hashed: true, frame_bytes: 16)
    hashed.file_names.should eq(expected.flat_map { |name| [CrystalClick::StreamName.hash(name) + ".bin", CrystalClick::StreamName.hash(name) + ".mrk2"] }.sort)
    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentColumnWriter.encode("payload", w127_root_plan, [] of Array(CrystalClick::ObjectDocument))
    end
  end

  it "does not reset the codec budget between recomputation and logical encoding" do
    limits = w127_root_large_limits
    stats_budget = CrystalClick::BinaryCodecBudget.new(limits, true)
    fresh = CrystalClick::ObjectDocumentStatistics.recompute_with_budget(w127_root_plan, w127_root_documents, stats_budget)
    encoder_budget = CrystalClick::BinaryCodecBudget.new(limits, true)
    CrystalClick::ObjectDocumentCodec.encode_with_budget(fresh, w127_root_documents, encoder_budget)
    # Either sub-operation fits alone. Their sum must not fit this budget.
    bound = Math.max(stats_budget.node_count, encoder_budget.node_count)
    narrow = CrystalClick::BinaryCodecLimits.new(max_depth: 64, max_nodes: bound,
      max_elements: 1_000_000, max_bytes: 16 * 1024 * 1024)
    error = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentColumnWriter.encode("payload", w127_root_plan, w127_root_documents, frame_bytes: 16, limits: narrow)
    end
    error.message.should eq("binary codec node limit exceeded")
  end

  it "does not reset transport records for each column lane" do
    # One pair fits. Nine lanes each require at least five mark records,
    # regardless of sparse bytes. A reset per lane would incorrectly pass.
    limits = CrystalClick::CompressedStreamLimits.new(max_records: 32)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentColumnWriter.encode("payload", w127_root_plan, w127_root_documents,
        frame_bytes: 4096, transport_limits: limits)
    end
  end

  it "rejects overlong unhashed names while allowing explicit hashed basenames" do
    column_name = "." * CrystalClick::PartChecksums::MAX_NAME_BYTES
    plan = w127_root_empty_plan
    documents = [[CrystalClick::ObjectDocument.new({} of String => CrystalClick::BinaryValue)]]
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentColumnWriter.encode(column_name, plan, documents)
    end
    hashed = CrystalClick::ObjectDocumentColumnWriter.encode(column_name, plan, documents, hashed: true)
    hashed.file_names.each { |name| name.bytesize.should be <= CrystalClick::PartChecksums::MAX_NAME_BYTES }
  end
end
