require "./spec_helper"

private def w143_bulk_u64(value : UInt64) : Bytes
  Bytes.new(8) { |index| ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w143_bulk_concat(parts : Array(Bytes)) : Bytes
  bytes = [] of UInt8
  parts.each { |part| part.each { |byte| bytes << byte } }
  Bytes.new(bytes.size) { |index| bytes[index] }
end

private def w143_bulk_var_uint(value : UInt64) : Bytes
  bytes = [] of UInt8
  remaining = value
  while remaining >= 0x80_u64
    bytes << ((remaining & 0x7f_u64).to_u8 | 0x80_u8)
    remaining >>= 7
  end
  bytes << remaining.to_u8
  Bytes.new(bytes.size) { |index| bytes[index] }
end

private def w143_bulk_string(value : String) : Bytes
  w143_bulk_concat([w143_bulk_var_uint(value.bytesize.to_u64), value.to_slice] of Bytes)
end

private def w143_bulk_index_mark(ids : Array(UInt64), flags : UInt64) : Bytes
  bytes = [] of UInt8
  w143_bulk_u64(flags).each { |byte| bytes << byte }
  w143_bulk_u64(ids.size.to_u64).each { |byte| bytes << byte }
  ids.each { |id| bytes << id.to_u8 }
  Bytes.new(bytes.size) { |index| bytes[index] }
end

private def w143_bulk_streams(mark_count : Int, lanes : Hash(String, Tuple(Bytes, Array(UInt64)))) : CrystalClick::BinaryBulkStreams
  streams = Hash(String, CrystalClick::BinaryBulkStream).new
  lanes.each do |role, lane|
    streams[role] = CrystalClick::BinaryBulkStream.new(lane[0], lane[1])
  end
  CrystalClick::BinaryBulkStreams.new(mark_count, streams)
end

private def w143_bulk_replace_lane(
  source : CrystalClick::BinaryBulkStreams,
  changed_role : String,
  changed_bytes : Bytes,
) : CrystalClick::BinaryBulkStreams
  streams = Hash(String, CrystalClick::BinaryBulkStream).new
  source.roles.each do |role|
    lane = source.stream(role)
    bytes = role == changed_role ? changed_bytes : lane.bytes
    streams[role] = CrystalClick::BinaryBulkStream.new(bytes, lane.offsets)
  end
  CrystalClick::BinaryBulkStreams.new(source.mark_count, streams)
end

private def w143_bulk_low(type : CrystalClick::BinaryDataType, child : CrystalClick::BinaryValue) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.low_cardinality(type, child)
end

private def w143_bulk_tuple_array_type : CrystalClick::BinaryDataType
  string = CrystalClick::BinaryDataType.primitive("String")
  low = CrystalClick::BinaryDataType.low_cardinality(string)
  CrystalClick::BinaryDataType.tuple([string, CrystalClick::BinaryDataType.array(low)] of CrystalClick::BinaryDataType)
end

private def w143_bulk_tuple_array_row(type : CrystalClick::BinaryDataType, label : String, children : Array(String)) : CrystalClick::BinaryValue
  string = type.child_at(0)
  array = type.child_at(1)
  low = array.child_at(0)
  encoded_children = children.map { |item| w143_bulk_low(low, CrystalClick::BinaryValue.string(item)) }
  CrystalClick::BinaryValue.tuple(
    type,
    [CrystalClick::BinaryValue.string(label), CrystalClick::BinaryValue.array(array, encoded_children)] of CrystalClick::BinaryValue
  )
end

private def w143_bulk_tuple_array_fixture(profile : CrystalClick::BinaryBulkProfile) : CrystalClick::BinaryBulkStreams
  type = w143_bulk_tuple_array_type
  rows = [
    [w143_bulk_tuple_array_row(type, "a", ["red"])],
    [w143_bulk_tuple_array_row(type, "b", [] of String), w143_bulk_tuple_array_row(type, "c", ["blue", "red", "blue"])],
    [w143_bulk_tuple_array_row(type, "d", [] of String), w143_bulk_tuple_array_row(type, "e", [] of String)],
  ] of Array(CrystalClick::BinaryValue)
  CrystalClick::BinaryBulkCodec.encode(type, rows, profile: profile)
end

private def w143_bulk_assert_decode_budgets(
  type : CrystalClick::BinaryDataType,
  streams : CrystalClick::BinaryBulkStreams,
  rows_per_mark : Array(UInt64),
  first_mark : Int,
  mark_count : Int,
  profile : CrystalClick::BinaryBulkProfile,
) : Tuple(Int64, Int64, Int64)
  measured = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS)
  CrystalClick::BinaryBulkCodec.decode_with_budget(
    type,
    streams,
    rows_per_mark,
    measured,
    first_mark: first_mark,
    mark_count: mark_count,
    profile: profile
  )
  counts = {measured.node_count, measured.element_count, measured.wire_byte_count}
  counts.each { |count| count.should be > 0_i64 }

  exact_limits = CrystalClick::BinaryCodecLimits.new(
    max_depth: CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS.max_depth,
    max_nodes: counts[0],
    max_elements: counts[1],
    max_bytes: counts[2]
  )
  exact = CrystalClick::BinaryCodecBudget.new(exact_limits)
  CrystalClick::BinaryBulkCodec.decode_with_budget(
    type,
    streams,
    rows_per_mark,
    exact,
    first_mark: first_mark,
    mark_count: mark_count,
    profile: profile
  )
  {exact.node_count, exact.element_count, exact.wire_byte_count}.should eq(counts)

  short_limits = [
    CrystalClick::BinaryCodecLimits.new(
      max_depth: CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS.max_depth,
      max_nodes: counts[0] - 1,
      max_elements: counts[1],
      max_bytes: counts[2]
    ),
    CrystalClick::BinaryCodecLimits.new(
      max_depth: CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS.max_depth,
      max_nodes: counts[0],
      max_elements: counts[1] - 1,
      max_bytes: counts[2]
    ),
    CrystalClick::BinaryCodecLimits.new(
      max_depth: CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS.max_depth,
      max_nodes: counts[0],
      max_elements: counts[1],
      max_bytes: counts[2] - 1
    ),
  ]
  short_limits.each do |limits|
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(
        type,
        streams,
        rows_per_mark,
        first_mark: first_mark,
        mark_count: mark_count,
        limits: limits,
        profile: profile
      )
    end
  end
  counts
end

describe "W143 recursive BinaryBulk LowCardinality integration" do
  it "uses independent literal lanes and flattened LC counts through Tuple(Array(LC(String)))" do
    string = CrystalClick::BinaryDataType.primitive("String")
    type = w143_bulk_tuple_array_type
    single = w143_bulk_tuple_array_fixture(CrystalClick::BinaryBulkProfile.single_stream)

    # The Array size lane describes five outer rows, but the LC index lanes
    # contain only one, three, and zero flattened element occurrences.
    single.roles.should eq([
      "root.field.0.data",
      "root.field.1.elements.dictionary",
      "root.field.1.elements.indexes",
      "root.field.1.sizes",
    ])
    single.stream("root.field.0.data").bytes.should eq(Bytes[
      0x01_u8, 0x61_u8, 0x01_u8, 0x62_u8, 0x01_u8, 0x63_u8,
      0x01_u8, 0x64_u8, 0x01_u8, 0x65_u8,
    ])
    single.stream("root.field.0.data").offsets.should eq([0_u64, 2_u64, 6_u64, 10_u64])
    single.stream("root.field.1.sizes").bytes.should eq(w143_bulk_concat([
      w143_bulk_u64(1_u64), w143_bulk_u64(0_u64), w143_bulk_u64(3_u64),
      w143_bulk_u64(0_u64), w143_bulk_u64(0_u64),
    ] of Bytes))
    single.stream("root.field.1.sizes").offsets.should eq([0_u64, 8_u64, 24_u64, 40_u64])
    single.stream("root.field.1.elements.dictionary").bytes.should eq(w143_bulk_concat([
      w143_bulk_u64(1_u64), w143_bulk_u64(3_u64), w143_bulk_string(""),
      w143_bulk_string("red"), w143_bulk_string("blue"),
    ] of Bytes))
    single.stream("root.field.1.elements.dictionary").offsets.should eq([8_u64, 8_u64, 8_u64, 26_u64])
    single.stream("root.field.1.elements.indexes").bytes.should eq(w143_bulk_concat([
      w143_bulk_index_mark([1_u64], 0x500_u64),
      w143_bulk_index_mark([2_u64, 1_u64, 2_u64], 0x100_u64),
    ] of Bytes))
    single.stream("root.field.1.elements.indexes").offsets.should eq([0_u64, 17_u64, 36_u64, 36_u64])

    # Selection replays the global dictionary/index history but returns only
    # the requested middle mark; its two outer rows flatten to three LC IDs.
    middle = CrystalClick::BinaryBulkCodec.decode(
      type,
      single,
      [1_u64, 2_u64, 2_u64],
      first_mark: 1,
      mark_count: 1
    )
    middle.size.should eq(1)
    middle[0].size.should eq(2)
    middle[0][0].child_at(1).element_count.should eq(0)
    middle[0][1].child_at(1).elements.map { |item| item.child_at(0).as_string }.should eq(["blue", "red", "blue"])

    with_size = CrystalClick::BinaryBulkCodec.encode(
      type,
      [
        [w143_bulk_tuple_array_row(type, "a", ["red"])],
        [w143_bulk_tuple_array_row(type, "b", [] of String), w143_bulk_tuple_array_row(type, "c", ["blue", "red", "blue"])],
        [w143_bulk_tuple_array_row(type, "d", [] of String), w143_bulk_tuple_array_row(type, "e", [] of String)],
      ] of Array(CrystalClick::BinaryValue),
      profile: CrystalClick::BinaryBulkProfile.with_size_stream
    )
    with_size.roles.should contain("root.field.0.string_sizes")
    with_size.stream("root.field.0.data").bytes.should eq(Bytes[0x61_u8, 0x62_u8, 0x63_u8, 0x64_u8, 0x65_u8])
    with_size.stream("root.field.0.string_sizes").bytes.should eq(w143_bulk_concat(Array(Bytes).new(5) { w143_bulk_u64(1_u64) }))
    with_size.stream("root.field.0.string_sizes").offsets.should eq([0_u64, 8_u64, 24_u64, 40_u64])
    with_size.stream("root.field.1.elements.dictionary").bytes.should eq(single.stream("root.field.1.elements.dictionary").bytes)
    with_size.stream("root.field.1.elements.indexes").bytes.should eq(single.stream("root.field.1.elements.indexes").bytes)

    # Returned byte/offset snapshots and decoded selections are detached from
    # the retained lanes and from later caller mutation.
    dictionary = single.stream("root.field.1.elements.dictionary")
    byte_snapshot = dictionary.bytes
    byte_snapshot[0] = 0_u8
    offset_snapshot = dictionary.offsets
    offset_snapshot[0] = 99_u64
    dictionary.bytes.should_not eq(byte_snapshot)
    dictionary.offsets.should_not eq(offset_snapshot)
    middle.clear
    CrystalClick::BinaryBulkCodec.decode(type, single, [1_u64, 2_u64, 2_u64], first_mark: 1, mark_count: 1)[0].size.should eq(2)
  end

  it "keeps two Map LC sites independent while sizes, NULLs, and selected marks use their own coordinates" do
    string = CrystalClick::BinaryDataType.primitive("String")
    nullable_string = CrystalClick::BinaryDataType.nullable(string)
    low_key = CrystalClick::BinaryDataType.low_cardinality(string)
    low_value = CrystalClick::BinaryDataType.low_cardinality(nullable_string)
    type = CrystalClick::BinaryDataType.map(low_key, low_value)
    key = ->(value : String) { w143_bulk_low(low_key, CrystalClick::BinaryValue.string(value)) }
    nullable = ->(value : String?) do
      child = value ? CrystalClick::BinaryValue.nullable(nullable_string, CrystalClick::BinaryValue.string(value)) : CrystalClick::BinaryValue.nullable(nullable_string)
      w143_bulk_low(low_value, child)
    end
    rows = [
      [CrystalClick::BinaryValue.map(type, [key.call("left"), nullable.call(nil)])],
      [CrystalClick::BinaryValue.map(type, [] of CrystalClick::BinaryValue), CrystalClick::BinaryValue.map(type, [key.call("right"), nullable.call("x")])],
    ] of Array(CrystalClick::BinaryValue)
    encoded = CrystalClick::BinaryBulkCodec.encode(type, rows)
    encoded.stream("root.sizes").bytes.should eq(w143_bulk_concat([
      w143_bulk_u64(1_u64), w143_bulk_u64(0_u64), w143_bulk_u64(1_u64),
    ] of Bytes))
    encoded.stream("root.elements.field.0.dictionary").bytes.should eq(w143_bulk_concat([
      w143_bulk_u64(1_u64), w143_bulk_u64(3_u64), w143_bulk_string(""),
      w143_bulk_string("left"), w143_bulk_string("right"),
    ] of Bytes))
    encoded.stream("root.elements.field.1.dictionary").bytes.should eq(w143_bulk_concat([
      w143_bulk_u64(1_u64), w143_bulk_u64(3_u64), w143_bulk_string(""),
      w143_bulk_string(""), w143_bulk_string("x"),
    ] of Bytes))
    encoded.stream("root.elements.field.0.indexes").offsets.should eq([0_u64, 17_u64, 34_u64])
    encoded.stream("root.elements.field.1.indexes").offsets.should eq([0_u64, 17_u64, 34_u64])
    selected = CrystalClick::BinaryBulkCodec.decode(type, encoded, [1_u64, 2_u64], first_mark: 1, mark_count: 1)
    selected[0].size.should eq(2)
    selected[0][0].element_count.should eq(0)
    pair = selected[0][1].elements
    pair[0].child_at(0).as_string.should eq("right")
    pair[1].child_at(0).child_at(0).as_string.should eq("x")
  end

  it "emits a version-only dictionary for all-empty nested LC marks" do
    string = CrystalClick::BinaryDataType.primitive("String")
    low = CrystalClick::BinaryDataType.low_cardinality(string)
    type = CrystalClick::BinaryDataType.array(low)
    empty = CrystalClick::BinaryValue.array(type, [] of CrystalClick::BinaryValue)
    encoded = CrystalClick::BinaryBulkCodec.encode(type, [[empty], [empty]] of Array(CrystalClick::BinaryValue))
    encoded.stream("root.elements.dictionary").bytes.should eq(w143_bulk_u64(1_u64))
    encoded.stream("root.elements.dictionary").offsets.should eq([8_u64, 8_u64, 8_u64])
    encoded.stream("root.elements.indexes").bytes.should be_empty
    encoded.stream("root.elements.indexes").offsets.should eq([0_u64, 0_u64, 0_u64])
    decoded = CrystalClick::BinaryBulkCodec.decode(type, encoded, [1_u64, 1_u64])
    decoded.size.should eq(2)
    decoded.each { |mark| mark[0].element_count.should eq(0) }
  end

  it "derives LC occurrence counts through a nested Array chain instead of either ancestor row count" do
    string = CrystalClick::BinaryDataType.primitive("String")
    low = CrystalClick::BinaryDataType.low_cardinality(string)
    inner = CrystalClick::BinaryDataType.array(low)
    outer = CrystalClick::BinaryDataType.array(inner)
    inner_values = ->(values : Array(String)) do
      children = values.map { |value| w143_bulk_low(low, CrystalClick::BinaryValue.string(value)) }
      CrystalClick::BinaryValue.array(inner, children)
    end
    outer_value = ->(values : Array(Array(String))) do
      children = values.map { |items| inner_values.call(items) }
      CrystalClick::BinaryValue.array(outer, children)
    end
    rows = [
      [outer_value.call([["x"], [] of String, ["y", "z"]])],
      [outer_value.call([] of Array(String)), outer_value.call([[] of String, ["w"]])],
    ] of Array(CrystalClick::BinaryValue)
    encoded = CrystalClick::BinaryBulkCodec.encode(outer, rows)
    encoded.stream("root.sizes").bytes.should eq(w143_bulk_concat([
      w143_bulk_u64(3_u64), w143_bulk_u64(0_u64), w143_bulk_u64(2_u64),
    ] of Bytes))
    encoded.stream("root.elements.sizes").bytes.should eq(w143_bulk_concat([
      w143_bulk_u64(1_u64), w143_bulk_u64(0_u64), w143_bulk_u64(2_u64),
      w143_bulk_u64(0_u64), w143_bulk_u64(1_u64),
    ] of Bytes))
    encoded.stream("root.elements.elements.dictionary").bytes.should eq(w143_bulk_concat([
      w143_bulk_u64(1_u64), w143_bulk_u64(5_u64), w143_bulk_string(""),
      w143_bulk_string("x"), w143_bulk_string("y"), w143_bulk_string("z"), w143_bulk_string("w"),
    ] of Bytes))
    encoded.stream("root.elements.elements.indexes").bytes.should eq(w143_bulk_concat([
      w143_bulk_index_mark([1_u64, 2_u64, 3_u64], 0x500_u64),
      w143_bulk_index_mark([4_u64], 0x100_u64),
    ] of Bytes))
    encoded.stream("root.elements.elements.indexes").offsets.should eq([0_u64, 19_u64, 36_u64])
    selected = CrystalClick::BinaryBulkCodec.decode(outer, encoded, [1_u64, 2_u64], first_mark: 1, mark_count: 1)
    selected[0][0].element_count.should eq(0)
    selected[0][1].element_at(0).element_count.should eq(0)
    selected[0][1].element_at(1).elements.map { |value| value.child_at(0).as_string }.should eq(["w"])
  end

  it "uses independent dictionaries for repeated references to the same Tuple child descriptor" do
    string = CrystalClick::BinaryDataType.primitive("String")
    low = CrystalClick::BinaryDataType.low_cardinality(string)
    type = CrystalClick::BinaryDataType.tuple([low, low] of CrystalClick::BinaryDataType)
    first = w143_bulk_low(low, CrystalClick::BinaryValue.string("east"))
    second = w143_bulk_low(low, CrystalClick::BinaryValue.string("west"))
    encoded = CrystalClick::BinaryBulkCodec.encode(
      type,
      [[CrystalClick::BinaryValue.tuple(type, [first, second] of CrystalClick::BinaryValue)]] of Array(CrystalClick::BinaryValue)
    )
    encoded.stream("root.field.0.dictionary").bytes.should eq(w143_bulk_concat([
      w143_bulk_u64(1_u64), w143_bulk_u64(2_u64), w143_bulk_string(""), w143_bulk_string("east"),
    ] of Bytes))
    encoded.stream("root.field.1.dictionary").bytes.should eq(w143_bulk_concat([
      w143_bulk_u64(1_u64), w143_bulk_u64(2_u64), w143_bulk_string(""), w143_bulk_string("west"),
    ] of Bytes))
    decoded = CrystalClick::BinaryBulkCodec.decode(type, encoded, [1_u64])
    decoded[0][0].child_at(0).child_at(0).as_string.should eq("east")
    decoded[0][0].child_at(1).child_at(0).as_string.should eq("west")
  end

  it "aliases root LC accounting to the standalone storage owner without charging it twice" do
    string = CrystalClick::BinaryDataType.primitive("String")
    low = CrystalClick::BinaryDataType.low_cardinality(string)
    a = w143_bulk_low(low, CrystalClick::BinaryValue.string("a"))
    b = w143_bulk_low(low, CrystalClick::BinaryValue.string("b"))
    rows = [[a, a], [b]] of Array(CrystalClick::BinaryValue)

    storage_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true)
    storage = CrystalClick::BinaryLowCardinalityStorageCodec.encode_with_budget(low, rows, storage_budget)
    bulk_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true)
    bulk = CrystalClick::BinaryBulkCodec.encode_with_budget(low, rows, bulk_budget)

    # The LC and String descriptors contribute two nodes/one edge; the shared
    # storage owner contributes its eight metadata records, three logical
    # values plus their three edges/IDs, one reserved default, and two new keys.
    {storage_budget.node_count, storage_budget.element_count, storage_budget.wire_byte_count}.should eq({19_i64, 18_i64, 56_i64})
    {bulk_budget.node_count, bulk_budget.element_count, bulk_budget.wire_byte_count}.should eq({19_i64, 18_i64, 56_i64})
    bulk.roles.should eq(storage.roles)
    bulk.stream("root.dictionary").bytes.should eq(w143_bulk_concat([
      w143_bulk_u64(1_u64), w143_bulk_u64(3_u64), w143_bulk_string(""),
      w143_bulk_string("a"), w143_bulk_string("b"),
    ] of Bytes))
    bulk.stream("root.indexes").bytes.should eq(w143_bulk_concat([
      w143_bulk_index_mark([1_u64, 1_u64], 0x500_u64),
      w143_bulk_index_mark([2_u64], 0x100_u64),
    ] of Bytes))
    bulk.stream("root.dictionary").bytes.should eq(storage.stream("root.dictionary").bytes)
    bulk.stream("root.indexes").bytes.should eq(storage.stream("root.indexes").bytes)
  end

  it "charges nested LC subtrees once while retaining parent edges and distinct staging" do
    string = CrystalClick::BinaryDataType.primitive("String")
    low = CrystalClick::BinaryDataType.low_cardinality(string)
    array = CrystalClick::BinaryDataType.array(low)
    a = w143_bulk_low(low, CrystalClick::BinaryValue.string("a"))
    b = w143_bulk_low(low, CrystalClick::BinaryValue.string("b"))
    rows = [
      [CrystalClick::BinaryValue.array(array, [a, a] of CrystalClick::BinaryValue)],
      [CrystalClick::BinaryValue.array(array, [b] of CrystalClick::BinaryValue)],
    ] of Array(CrystalClick::BinaryValue)
    flattened = [[a, a], [b]] of Array(CrystalClick::BinaryValue)

    storage_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true)
    storage = CrystalClick::BinaryLowCardinalityStorageCodec.encode_with_budget(low, flattened, storage_budget)
    bulk_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true)
    bulk = CrystalClick::BinaryBulkCodec.encode_with_budget(array, rows, bulk_budget)

    # Relative to standalone W142's 19 nodes/18 edges, add one Array descriptor
    # (1/1), two Array value nodes (2 nodes/3 child edges), five ordinary
    # grid records (5/5), three borrowed handles (0/3), two mark buckets (2/2),
    # and two census counts (2/2). LC's own eight metadata records, subtree
    # values, dictionary keys, and IDs remain owned only by W142.
    {storage_budget.node_count, storage_budget.element_count, storage_budget.wire_byte_count}.should eq({19_i64, 18_i64, 56_i64})
    {bulk_budget.node_count, bulk_budget.element_count, bulk_budget.wire_byte_count}.should eq({31_i64, 34_i64, 72_i64})

    # Physical bytes are independently enumerated: dictionary 21, index marks
    # 18+17, and ordinary Array sizes 2+1 (16 bytes).
    bulk.stream("root.elements.dictionary").bytes.should eq(w143_bulk_concat([
      w143_bulk_u64(1_u64), w143_bulk_u64(3_u64), w143_bulk_string(""),
      w143_bulk_string("a"), w143_bulk_string("b"),
    ] of Bytes))
    bulk.stream("root.elements.indexes").bytes.should eq(w143_bulk_concat([
      w143_bulk_index_mark([1_u64, 1_u64], 0x500_u64),
      w143_bulk_index_mark([2_u64], 0x100_u64),
    ] of Bytes))
    bulk.stream("root.sizes").bytes.should eq(w143_bulk_concat([w143_bulk_u64(2_u64), w143_bulk_u64(1_u64)] of Bytes))
    bulk.stream("root.elements.dictionary").bytes.should eq(storage.stream("root.dictionary").bytes)
    bulk.stream("root.elements.indexes").bytes.should eq(storage.stream("root.indexes").bytes)
    bulk.total_input_byte_size.should eq(72_u64)
  end

  it "matches standalone W142 decode accounting at root and accepts only exact root/nested decode budgets" do
    string = CrystalClick::BinaryDataType.primitive("String")
    low = CrystalClick::BinaryDataType.low_cardinality(string)
    a = w143_bulk_low(low, CrystalClick::BinaryValue.string("a"))
    b = w143_bulk_low(low, CrystalClick::BinaryValue.string("b"))
    root_values = [[a, a], [b]] of Array(CrystalClick::BinaryValue)
    root_streams = CrystalClick::BinaryLowCardinalityStorageCodec.encode(low, root_values)
    storage_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS)
    storage_decoded = CrystalClick::BinaryLowCardinalityStorageCodec.decode_with_budget(
      low,
      root_streams,
      [2_u64, 1_u64],
      storage_budget,
      1,
      1
    )
    bulk_root_counts = w143_bulk_assert_decode_budgets(
      low,
      root_streams,
      [2_u64, 1_u64],
      1,
      1,
      CrystalClick::BinaryBulkProfile.single_stream
    )
    storage_counts = {storage_budget.node_count, storage_budget.element_count, storage_budget.wire_byte_count}
    bulk_root_counts.should eq(storage_counts)
    storage_decoded.map { |mark| mark.map { |value| value.child_at(0).as_string } }.should eq([["b"]])

    array = CrystalClick::BinaryDataType.array(low)
    nested_rows = [
      [CrystalClick::BinaryValue.array(array, [a, a] of CrystalClick::BinaryValue)],
      [CrystalClick::BinaryValue.array(array, [b] of CrystalClick::BinaryValue)],
    ] of Array(CrystalClick::BinaryValue)
    nested_streams = CrystalClick::BinaryBulkCodec.encode(array, nested_rows)
    nested_counts = w143_bulk_assert_decode_budgets(
      array,
      nested_streams,
      [1_u64, 1_u64],
      1,
      1,
      CrystalClick::BinaryBulkProfile.single_stream
    )
    nested_counts[0].should be > bulk_root_counts[0]
    selected = CrystalClick::BinaryBulkCodec.decode(
      array,
      nested_streams,
      [1_u64, 1_u64],
      first_mark: 1,
      mark_count: 1
    )
    selected.size.should eq(1)
    selected[0][0].elements.map { |value| value.child_at(0).as_string }.should eq(["b"])
  end

  it "writes the recursive typed default beneath a small Nullable Tuple LC null" do
    string = CrystalClick::BinaryDataType.primitive("String")
    fixed = CrystalClick::BinaryDataType.fixed_string(3)
    low = CrystalClick::BinaryDataType.low_cardinality(fixed)
    tuple = CrystalClick::BinaryDataType.tuple([low, string] of CrystalClick::BinaryDataType)
    nullable = CrystalClick::BinaryDataType.nullable(tuple)
    null_value = CrystalClick::BinaryValue.nullable(nullable)
    encoded = CrystalClick::BinaryBulkCodec.encode(nullable, [[null_value]] of Array(CrystalClick::BinaryValue))

    encoded.roles.should eq([
      "root.nested.field.0.dictionary",
      "root.nested.field.0.indexes",
      "root.nested.field.1.data",
      "root.nulls",
    ])
    encoded.stream("root.nulls").bytes.should eq(Bytes[1_u8])
    encoded.stream("root.nested.field.0.dictionary").bytes.should eq(w143_bulk_concat([
      w143_bulk_u64(1_u64), w143_bulk_u64(1_u64), Bytes[0_u8, 0_u8, 0_u8],
    ] of Bytes))
    encoded.stream("root.nested.field.0.dictionary").offsets.should eq([8_u64, 19_u64])
    encoded.stream("root.nested.field.0.indexes").bytes.should eq(w143_bulk_index_mark([0_u64], 0x500_u64))
    encoded.stream("root.nested.field.1.data").bytes.should eq(Bytes[0_u8])
    encoded.total_input_byte_size.should eq(38_u64)
    decoded = CrystalClick::BinaryBulkCodec.decode(nullable, encoded, [1_u64])
    decoded[0][0].is_null?.should be_true
  end

  it "validates unselected ancestor sizes and LC IDs without parsing unrelated unselected payload" do
    type = w143_bulk_tuple_array_type
    valid = w143_bulk_tuple_array_fixture(CrystalClick::BinaryBulkProfile.single_stream)

    huge_sizes = valid.stream("root.field.1.sizes").bytes
    w143_bulk_u64(UInt64::MAX).each_with_index { |byte, index| huge_sizes[index] = byte }
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(
        type,
        w143_bulk_replace_lane(valid, "root.field.1.sizes", huge_sizes),
        [1_u64, 2_u64, 2_u64],
        first_mark: 1,
        mark_count: 1
      )
    end

    bad_id = valid.stream("root.field.1.elements.indexes").bytes
    bad_id[16] = 0xff_u8 # First, unselected mark's one-byte ID is outside its dictionary.
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(
        type,
        w143_bulk_replace_lane(valid, "root.field.1.elements.indexes", bad_id),
        [1_u64, 2_u64, 2_u64],
        first_mark: 1,
        mark_count: 1
      )
    end

    bad_after_selected = valid.stream("root.field.1.elements.indexes").bytes
    bad_after_selected[33] = 0xff_u8 # Second mark is corrupt although only the first is selected.
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(
        type,
        w143_bulk_replace_lane(valid, "root.field.1.elements.indexes", bad_after_selected),
        [1_u64, 2_u64, 2_u64],
        first_mark: 0,
        mark_count: 1
      )
    end

    malformed_other_string = valid.stream("root.field.0.data").bytes
    malformed_other_string[0] = 0xff_u8 # VarUInt is oversized, but this lane range is outside selection.
    selected = CrystalClick::BinaryBulkCodec.decode(
      type,
      w143_bulk_replace_lane(valid, "root.field.0.data", malformed_other_string),
      [1_u64, 2_u64, 2_u64],
      first_mark: 1,
      mark_count: 1
    )
    selected[0].map { |row| row.child_at(0).as_string }.should eq(["b", "c"])
  end

  it "charges shared nested output bytes once at the measured bound and rejects one byte less" do
    type = w143_bulk_tuple_array_type
    rows = [
      [w143_bulk_tuple_array_row(type, "a", ["red"])],
      [w143_bulk_tuple_array_row(type, "b", [] of String), w143_bulk_tuple_array_row(type, "c", ["blue", "red", "blue"])],
      [w143_bulk_tuple_array_row(type, "d", [] of String), w143_bulk_tuple_array_row(type, "e", [] of String)],
    ] of Array(CrystalClick::BinaryValue)
    measured = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true)
    encoded = CrystalClick::BinaryBulkCodec.encode_with_budget(type, rows, measured)
    measured.wire_byte_count.should eq(encoded.total_input_byte_size.to_i64)
    exact_limits = CrystalClick::BinaryCodecLimits.new(
      max_depth: 64,
      max_nodes: measured.node_count,
      max_elements: measured.element_count,
      max_bytes: measured.wire_byte_count
    )
    exact = CrystalClick::BinaryCodecBudget.new(exact_limits, true)
    CrystalClick::BinaryBulkCodec.encode_with_budget(type, rows, exact).total_input_byte_size.should eq(encoded.total_input_byte_size)
    short_limits = CrystalClick::BinaryCodecLimits.new(
      max_depth: 64,
      max_nodes: measured.node_count,
      max_elements: measured.element_count,
      max_bytes: measured.wire_byte_count - 1
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkCodec.encode_with_budget(type, rows, CrystalClick::BinaryCodecBudget.new(short_limits, true))
    end
  end

  it "preflights a hidden Nullable(Tuple(LC(FixedString))) default before allocating its key" do
    fixed = CrystalClick::BinaryDataType.fixed_string(CrystalClick::BinaryDataType::MAX_FIXED_STRING)
    low = CrystalClick::BinaryDataType.low_cardinality(fixed)
    tuple = CrystalClick::BinaryDataType.tuple([low] of CrystalClick::BinaryDataType)
    type = CrystalClick::BinaryDataType.nullable(tuple)
    null_value = CrystalClick::BinaryValue.nullable(type)
    tight = CrystalClick::BinaryCodecLimits.new(max_depth: 64, max_nodes: 100, max_elements: 100, max_bytes: 8)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkCodec.encode(type, [[null_value]] of Array(CrystalClick::BinaryValue), limits: tight)
    end
  end

  it "admits LC Float32, Float64, and BFloat16 on zero and empty grids" do
    ["Float32", "Float64", "BFloat16"].each do |name|
      low = CrystalClick::BinaryDataType.low_cardinality(CrystalClick::BinaryDataType.primitive(name))
      zero_grid = CrystalClick::BinaryBulkCodec.encode(low, [] of Array(CrystalClick::BinaryValue))
      zero_grid.roles.should eq(["root.dictionary", "root.indexes"])
      zero_grid.stream("root.dictionary").bytes.should eq(w143_bulk_u64(1_u64))
      zero_grid.stream("root.dictionary").offsets.should eq([8_u64])
      zero_grid.stream("root.indexes").bytes.should be_empty
      zero_grid.stream("root.indexes").offsets.should eq([0_u64])
      CrystalClick::BinaryBulkCodec.decode(low, zero_grid, [] of UInt64).should be_empty

      empty_marks = [
        [] of CrystalClick::BinaryValue,
        [] of CrystalClick::BinaryValue,
      ] of Array(CrystalClick::BinaryValue)
      all_empty = CrystalClick::BinaryBulkCodec.encode(low, empty_marks)
      all_empty.stream("root.dictionary").bytes.should eq(w143_bulk_u64(1_u64))
      all_empty.stream("root.dictionary").offsets.should eq([8_u64, 8_u64, 8_u64])
      all_empty.stream("root.indexes").bytes.should be_empty
      all_empty.stream("root.indexes").offsets.should eq([0_u64, 0_u64, 0_u64])
      decoded_empty_marks = CrystalClick::BinaryBulkCodec.decode(low, all_empty, [0_u64, 0_u64])
      decoded_empty_marks.size.should eq(2)
      decoded_empty_marks.each { |mark| mark.should be_empty }

      nested = CrystalClick::BinaryDataType.array(low)
      empty_array = CrystalClick::BinaryValue.array(nested, [] of CrystalClick::BinaryValue)
      nested_streams = CrystalClick::BinaryBulkCodec.encode(nested, [[empty_array]] of Array(CrystalClick::BinaryValue))
      nested_streams.stream("root.sizes").bytes.should eq(w143_bulk_u64(0_u64))
      nested_streams.stream("root.sizes").offsets.should eq([0_u64, 8_u64])
      nested_streams.stream("root.elements.dictionary").bytes.should eq(w143_bulk_u64(1_u64))
      nested_streams.stream("root.elements.dictionary").offsets.should eq([8_u64, 8_u64])
      nested_streams.stream("root.elements.indexes").bytes.should be_empty
      nested_streams.stream("root.elements.indexes").offsets.should eq([0_u64, 0_u64])
      decoded_nested = CrystalClick::BinaryBulkCodec.decode(nested, nested_streams, [1_u64])
      decoded_nested.size.should eq(1)
      decoded_nested[0].size.should eq(1)
      decoded_nested[0][0].element_count.should eq(0)
    end
  end

  it "caches structural LC membership while keeping Dynamic and Object admission guards closed" do
    string = CrystalClick::BinaryDataType.primitive("String")
    low = CrystalClick::BinaryDataType.low_cardinality(string)
    deep = CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.tuple([string, low] of CrystalClick::BinaryDataType))
    string.contains_low_cardinality?.should be_false
    low.contains_low_cardinality?.should be_true
    deep.contains_low_cardinality?.should be_true
    deep = low
    512.times { deep = CrystalClick::BinaryDataType.array(deep) }
    deep.contains_low_cardinality?.should be_true
    shallow = CrystalClick::BinaryCodecLimits.new(max_depth: 8, max_nodes: 100, max_elements: 100, max_bytes: 100)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkPhysicalPlan.new(deep, "column", limits: shallow)
    end

    [CrystalClick::BinaryBulkProfile.single_stream, CrystalClick::BinaryBulkProfile.with_size_stream].each do |profile|
      physical = CrystalClick::BinaryBulkPhysicalPlan.new(low, "column", profile: profile)
      physical.stream_names.should eq({
        "root.dictionary" => "column.dict",
        "root.indexes"    => "column",
      })
    end

    dynamic = CrystalClick::DynamicStructure.new([low] of CrystalClick::BinaryDataType)
    value = w143_bulk_low(low, CrystalClick::BinaryValue.string("x"))
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::DynamicValueCodec.encode(dynamic, [[value]] of Array(CrystalClick::BinaryValue))
    end
    empty_discriminator = CrystalClick::DynamicDiscriminatorCodec.encode(dynamic, [] of Array(UInt8))
    empty_lc = w143_bulk_streams(0, {
      "root.dictionary" => {w143_bulk_u64(1_u64), [8_u64]},
      "root.indexes"    => {Bytes.empty, [0_u64]},
    } of String => Tuple(Bytes, Array(UInt64)))
    empty_string = w143_bulk_streams(0, {
      "root.data" => {Bytes.empty, [0_u64]},
    } of String => Tuple(Bytes, Array(UInt64)))
    dynamic_streams = CrystalClick::DynamicValueStreams.new(
      empty_discriminator,
      {"SharedVariant" => empty_string, low.name => empty_lc} of String => CrystalClick::BinaryBulkStreams
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::DynamicValueCodec.decode(dynamic, dynamic_streams, first_mark: 0, mark_count: 0)
    end

    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure
    )
    plan = CrystalClick::ObjectDocumentPlan.new(structures, {"typed" => low})
    document = CrystalClick::ObjectDocument.new({"typed" => value} of String => CrystalClick::BinaryValue)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentCodec.encode(plan, [[document]] of Array(CrystalClick::ObjectDocument))
    end
    typed_streams = w143_bulk_streams(1, {
      "root.dictionary" => {w143_bulk_concat([w143_bulk_u64(1_u64), w143_bulk_u64(2_u64), w143_bulk_string(""), w143_bulk_string("x")] of Bytes), [8_u64, 19_u64]},
      "root.indexes"    => {w143_bulk_index_mark([1_u64], 0x500_u64), [0_u64, 17_u64]},
    } of String => Tuple(Bytes, Array(UInt64)))
    metadata = CrystalClick::ObjectDynamicStructureCodec.encode(structures)
    object_streams = CrystalClick::ObjectDocumentStreams.new(
      metadata,
      [1_u64],
      {"typed" => typed_streams} of String => CrystalClick::BinaryBulkStreams,
      {} of String => CrystalClick::DynamicValueStreams,
      w143_bulk_streams(1, {} of String => Tuple(Bytes, Array(UInt64)))
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentCodec.decode({"typed" => low} of String => CrystalClick::BinaryDataType, object_streams)
    end
  end
end
