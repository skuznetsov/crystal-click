require "./spec_helper"

private def w142_storage_u64_le(value : UInt64) : Bytes
  Bytes.new(8) do |index|
    ((value >> (index * 8)) & 0xff_u64).to_u8
  end
end

private def w142_storage_var_uint(value : UInt64) : Bytes
  bytes = [] of UInt8
  remaining = value
  while remaining >= 0x80_u64
    bytes << ((remaining & 0x7f_u64).to_u8 | 0x80_u8)
    remaining >>= 7
  end
  bytes << remaining.to_u8
  Bytes.new(bytes.size) { |index| bytes[index] }
end

private def w142_storage_string(value : String) : Bytes
  w142_storage_concat([
    w142_storage_var_uint(value.bytesize.to_u64),
    value.to_slice,
  ] of Bytes)
end

private def w142_storage_dictionary_update(key : String) : Bytes
  # Each update contains the required empty/default key followed by one new key.
  w142_storage_concat([
    w142_storage_u64_le(2_u64),
    w142_storage_string(""),
    w142_storage_string(key),
  ] of Bytes)
end

private def w142_storage_hex(hex : String) : Bytes
  raise ArgumentError.new("W142 fixture hex must contain complete bytes") unless hex.bytesize.even?

  bytes = [] of UInt8
  cursor = 0
  while cursor < hex.bytesize
    bytes << hex.byte_slice(cursor, 2).to_i(16).to_u8
    cursor += 2
  end
  Bytes.new(bytes.size) { |index| bytes[index] }
end

private def w142_storage_concat(parts : Array(Bytes)) : Bytes
  bytes = [] of UInt8
  parts.each { |part| part.each { |byte| bytes << byte } }
  Bytes.new(bytes.size) { |index| bytes[index] }
end

private def w142_storage_index_mark(
  width_code : UInt64,
  ids : Array(UInt64),
  flags : UInt64 = 0x500_u64,
) : Bytes
  width = 1 << width_code.to_i
  bytes = [] of UInt8
  w142_storage_u64_le(flags | width_code).each { |byte| bytes << byte }
  w142_storage_u64_le(ids.size.to_u64).each { |byte| bytes << byte }
  ids.each do |id|
    width.times do |offset|
      bytes << ((id >> (offset * 8)) & 0xff_u64).to_u8
    end
  end
  Bytes.new(bytes.size) { |index| bytes[index] }
end

private def w142_storage_streams(
  dictionary : Bytes,
  dictionary_offsets : Array(UInt64),
  indexes : Bytes,
  index_offsets : Array(UInt64),
  mark_count : Int,
) : CrystalClick::BinaryBulkStreams
  roles = {
    "root.dictionary" => CrystalClick::BinaryBulkStream.new(dictionary, dictionary_offsets),
    "root.indexes"    => CrystalClick::BinaryBulkStream.new(indexes, index_offsets),
  } of String => CrystalClick::BinaryBulkStream
  CrystalClick::BinaryBulkStreams.new(mark_count: mark_count, streams: roles)
end

private def w142_storage_native_streams(nullable : Bool = false) : CrystalClick::BinaryBulkStreams
  dictionary_hex = if nullable
                     # Native W141 LC(Nullable(String)) .dict lane: version 1,
                     # five keys (implicit NULL/default slot plus four Strings).
                     "010000000000000005000000000000000000016101620163"
                   else
                     # Native W141 LC(String) .dict lane: version 1 and the
                     # empty default, red, blue, green, and UTF-8 snow keys.
                     "01000000000000000500000000000000000372656404626c756505677265656e03e99baa"
                   end
  indexes_hex = if nullable
                  # Three native marks: 4, 4, and 1 flattened occurrences.
                  "000500000000000004000000000000000200020100010000000000000400000000000000000302040001000000000000010000000000000000"
                else
                  "000500000000000004000000000000000102010300010000000000000400000000000000020001040001000000000000010000000000000003"
                end
  dictionary = w142_storage_hex(dictionary_hex)
  indexes = w142_storage_hex(indexes_hex)
  w142_storage_streams(
    dictionary,
    [8_u64, 8_u64, 8_u64, dictionary.size.to_u64],
    indexes,
    [0_u64, 20_u64, 40_u64, indexes.size.to_u64],
    3
  )
end

private def w142_storage_dictionary : Bytes
  w142_storage_hex("01000000000000000500000000000000000372656404626c756505677265656e03e99baa")
end

private def w142_storage_one_mark_streams(
  dictionary : Bytes,
  index_bytes : Bytes,
) : CrystalClick::BinaryBulkStreams
  w142_storage_streams(
    dictionary,
    [8_u64, dictionary.size.to_u64],
    index_bytes,
    [0_u64, index_bytes.size.to_u64],
    1
  )
end

private def w142_storage_low_strings(
  type : CrystalClick::BinaryDataType,
  values : Array(String),
) : Array(CrystalClick::BinaryValue)
  values.map do |value|
    CrystalClick::BinaryValue.low_cardinality(type, CrystalClick::BinaryValue.string(value))
  end
end

private def w142_storage_nullable_value(
  type : CrystalClick::BinaryDataType,
  nullable_type : CrystalClick::BinaryDataType,
  value : String?,
) : CrystalClick::BinaryValue
  child = if value
            CrystalClick::BinaryValue.nullable(nullable_type, CrystalClick::BinaryValue.string(value))
          else
            CrystalClick::BinaryValue.nullable(nullable_type)
          end
  CrystalClick::BinaryValue.low_cardinality(type, child)
end

private def w142_storage_limits(max_bytes : Int = 64 * 1024 * 1024) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: 64,
    max_nodes: 4_096,
    max_elements: 1_000_000,
    max_bytes: max_bytes,
  )
end

private def w142_storage_exact_limits(
  max_nodes : Int,
  max_elements : Int,
  max_bytes : Int,
) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: 64,
    max_nodes: max_nodes,
    max_elements: max_elements,
    max_bytes: max_bytes,
  )
end

describe "W142 shared LowCardinality physical dictionary/index owner" do
  it "decodes the native global String dictionary for a selected middle mark" do
    string_type = CrystalClick::BinaryDataType.primitive("String")
    type = CrystalClick::BinaryDataType.low_cardinality(string_type)
    streams = w142_storage_native_streams

    # Native W141 evidence: .dict is 36 bytes with all three mark coordinates
    # at decompressed offset 8; the index lane has mark starts 0, 20, and 40
    # and EOF 57. In particular the dictionary grid is not a per-row byte grid.
    streams.stream("root.dictionary").offsets.should eq([8_u64, 8_u64, 8_u64, 36_u64])
    streams.stream("root.indexes").offsets.should eq([0_u64, 20_u64, 40_u64, 57_u64])

    selected = CrystalClick::BinaryLowCardinalityStorageCodec.decode(
      type,
      streams,
      [4_u64, 4_u64, 1_u64],
      first_mark: 1,
      mark_count: 1
    )
    selected.size.should eq(1)
    selected[0].map { |value| value.child_at(0).as_string }.should eq(["blue", "", "red", "雪"])
  end

  it "keeps the nullable implicit NULL slot distinct from the empty String key" do
    string_type = CrystalClick::BinaryDataType.primitive("String")
    nullable_type = CrystalClick::BinaryDataType.nullable(string_type)
    type = CrystalClick::BinaryDataType.low_cardinality(nullable_type)
    streams = w142_storage_native_streams(true)

    selected = CrystalClick::BinaryLowCardinalityStorageCodec.decode(
      type,
      streams,
      [4_u64, 4_u64, 1_u64],
      first_mark: 1,
      mark_count: 1
    )
    selected[0][0].child_at(0).is_null?.should be_true
    selected[0][1].child_at(0).is_null?.should be_false
    selected[0][1].child_at(0).child_at(0).as_string.should eq("b")
    selected[0][2].child_at(0).child_at(0).as_string.should eq("a")
    selected[0][3].child_at(0).child_at(0).as_string.should eq("c")

    first = CrystalClick::BinaryLowCardinalityStorageCodec.decode(
      type,
      streams,
      [4_u64, 4_u64, 1_u64],
      first_mark: 0,
      mark_count: 1
    )[0]
    first[0].child_at(0).child_count.should eq(1)
    first[0].child_at(0).child_at(0).as_string.should eq("a")
    first[1].child_at(0).is_null?.should be_true
    first[3].child_at(0).is_null?.should be_false
    first[3].child_at(0).child_at(0).as_string.should eq("")
  end

  it "decodes UInt8/16/32/64 index lanes without changing the shared dictionary contract" do
    string_type = CrystalClick::BinaryDataType.primitive("String")
    type = CrystalClick::BinaryDataType.low_cardinality(string_type)
    dictionary = w142_storage_dictionary

    4.times do |width_code|
      indexes = w142_storage_index_mark(width_code.to_u64, [1_u64])
      streams = w142_storage_one_mark_streams(dictionary, indexes)
      decoded = CrystalClick::BinaryLowCardinalityStorageCodec.decode(
        type,
        streams,
        [1_u64]
      )
      decoded[0][0].child_at(0).as_string.should eq("red")
    end
  end

  it "preserves raw String key bytes including embedded NUL and non-UTF-8 octets" do
    string_type = CrystalClick::BinaryDataType.primitive("String")
    type = CrystalClick::BinaryDataType.low_cardinality(string_type)
    raw = String.new(Bytes[0x61_u8, 0x00_u8, 0xff_u8])
    dictionary = w142_storage_concat([
      w142_storage_u64_le(1_u64),
      w142_storage_u64_le(2_u64),
      w142_storage_string(""),
      w142_storage_string(raw),
    ] of Bytes)
    streams = w142_storage_one_mark_streams(dictionary, w142_storage_index_mark(0_u64, [1_u64]))

    decoded = CrystalClick::BinaryLowCardinalityStorageCodec.decode(type, streams, [1_u64])
    decoded[0][0].child_at(0).as_string.to_slice.should eq(raw.to_slice)
  end

  it "uses Bool's nonzero-is-true physical semantics for noncanonical dictionary bytes" do
    bool_type = CrystalClick::BinaryDataType.primitive("Bool")
    type = CrystalClick::BinaryDataType.low_cardinality(bool_type)
    dictionary = w142_storage_concat([
      w142_storage_u64_le(1_u64),
      w142_storage_u64_le(2_u64),
      Bytes[0x00_u8, 0x7f_u8],
    ] of Bytes)
    streams = w142_storage_one_mark_streams(dictionary, w142_storage_index_mark(0_u64, [1_u64]))

    decoded = CrystalClick::BinaryLowCardinalityStorageCodec.decode(type, streams, [1_u64])
    decoded[0][0].child_at(0).as_bool.should be_true
  end

  it "retains negative-zero and NaN Float32 dictionary payload bits exactly" do
    float_type = CrystalClick::BinaryDataType.primitive("Float32")
    type = CrystalClick::BinaryDataType.low_cardinality(float_type)
    dictionary = w142_storage_concat([
      w142_storage_u64_le(1_u64),
      w142_storage_u64_le(3_u64),
      Bytes[0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8], # +0 default
      Bytes[0x00_u8, 0x00_u8, 0x00_u8, 0x80_u8], # -0
      Bytes[0x34_u8, 0x12_u8, 0xc0_u8, 0x7f_u8], # quiet NaN payload
    ] of Bytes)
    streams = w142_storage_one_mark_streams(dictionary, w142_storage_index_mark(0_u64, [1_u64, 2_u64]))

    decoded = CrystalClick::BinaryLowCardinalityStorageCodec.decode(type, streams, [2_u64])[0]
    decoded[0].child_at(0).bytes.should eq(Bytes[0x00_u8, 0x00_u8, 0x00_u8, 0x80_u8])
    decoded[1].child_at(0).bytes.should eq(Bytes[0x34_u8, 0x12_u8, 0xc0_u8, 0x7f_u8])
  end

  it "rejects reserved or impossible first-mark flags" do
    type = CrystalClick::BinaryDataType.low_cardinality(CrystalClick::BinaryDataType.primitive("String"))
    dictionary = w142_storage_dictionary

    [0x1500_u64, 0x400_u64].each do |flags|
      indexes = w142_storage_index_mark(0_u64, [1_u64], flags)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryLowCardinalityStorageCodec.decode(
          type,
          w142_storage_one_mark_streams(dictionary, indexes),
          [1_u64]
        )
      end
    end
  end

  it "rejects unsupported dictionary versions, malformed/duplicate keys, and out-of-range IDs" do
    type = CrystalClick::BinaryDataType.low_cardinality(CrystalClick::BinaryDataType.primitive("String"))
    index_one = w142_storage_index_mark(0_u64, [1_u64])

    invalid_version = w142_storage_dictionary
    invalid_version[0] = 0x02_u8
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryLowCardinalityStorageCodec.decode(
        type,
        w142_storage_one_mark_streams(invalid_version, index_one),
        [1_u64]
      )
    end

    duplicate_keys = w142_storage_concat([
      w142_storage_u64_le(1_u64),
      w142_storage_u64_le(2_u64),
      Bytes[0x00_u8, 0x00_u8],
    ] of Bytes)
    truncated_key = w142_storage_concat([
      w142_storage_u64_le(1_u64),
      w142_storage_u64_le(2_u64),
      Bytes[0x00_u8, 0x03_u8, 0x72_u8],
    ] of Bytes)
    [duplicate_keys, truncated_key].each do |dictionary|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryLowCardinalityStorageCodec.decode(
          type,
          w142_storage_one_mark_streams(dictionary, index_one),
          [1_u64]
        )
      end
    end

    out_of_range = w142_storage_index_mark(0_u64, [5_u64])
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryLowCardinalityStorageCodec.decode(
        type,
        w142_storage_one_mark_streams(w142_storage_dictionary, out_of_range),
        [1_u64]
      )
    end

    count_mismatch = w142_storage_index_mark(0_u64, [1_u64])
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryLowCardinalityStorageCodec.decode(
        type,
        w142_storage_one_mark_streams(w142_storage_dictionary, count_mismatch),
        [2_u64]
      )
    end
  end

  it "charges dictionary and index state against the shared byte budget before materializing values" do
    type = CrystalClick::BinaryDataType.low_cardinality(CrystalClick::BinaryDataType.primitive("String"))
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryLowCardinalityStorageCodec.decode(
        type,
        w142_storage_native_streams,
        [4_u64, 4_u64, 1_u64],
        first_mark: 1,
        mark_count: 1,
        limits: w142_storage_limits(8)
      )
    end
  end

  it "returns an empty selected window through both the standalone and recursive bulk owners" do
    type = CrystalClick::BinaryDataType.low_cardinality(CrystalClick::BinaryDataType.primitive("String"))
    streams = w142_storage_native_streams
    selected = CrystalClick::BinaryLowCardinalityStorageCodec.decode(
      type,
      streams,
      [4_u64, 4_u64, 1_u64],
      first_mark: 3,
      mark_count: 0
    )
    selected.should be_empty

    bulk_selected = CrystalClick::BinaryBulkCodec.decode(
      type,
      streams,
      [4_u64, 4_u64, 1_u64],
      first_mark: 3,
      mark_count: 0
    )
    bulk_selected.should be_empty
  end

  it "encodes per-mark LC values and decodes them through the same shared state owner" do
    string_type = CrystalClick::BinaryDataType.primitive("String")
    type = CrystalClick::BinaryDataType.low_cardinality(string_type)
    values = [
      w142_storage_low_strings(type, ["red", "blue", "red", "green"]),
      w142_storage_low_strings(type, ["blue", "", "red", "雪"]),
      w142_storage_low_strings(type, ["green"]),
    ] of Array(CrystalClick::BinaryValue)

    encoded = CrystalClick::BinaryLowCardinalityStorageCodec.encode(type, values)
    encoded.roles.sort.should eq(["root.dictionary", "root.indexes"])
    decoded = CrystalClick::BinaryLowCardinalityStorageCodec.decode(
      type,
      encoded,
      [4_u64, 4_u64, 1_u64]
    )
    decoded.map { |mark| mark.map { |value| value.child_at(0).as_string } }.should eq([
      ["red", "blue", "red", "green"],
      ["blue", "", "red", "雪"],
      ["green"],
    ])
  end

  it "encodes an empty wide FixedString LC without allocating an unused default key" do
    fixed_type = CrystalClick::BinaryDataType.fixed_string(CrystalClick::BinaryDataType::MAX_FIXED_STRING)
    type = CrystalClick::BinaryDataType.low_cardinality(fixed_type)

    encoded = CrystalClick::BinaryLowCardinalityStorageCodec.encode(
      type,
      [] of Array(CrystalClick::BinaryValue),
      limits: w142_storage_exact_limits(4, 3, 8)
    )
    encoded.mark_count.should eq(0)
    encoded.stream("root.dictionary").bytes.should eq(w142_storage_u64_le(1_u64))
    encoded.stream("root.indexes").bytes.should be_empty
  end

  it "rejects a nonempty wide Nullable(FixedString) LC before allocating its default keys" do
    fixed_type = CrystalClick::BinaryDataType.fixed_string(CrystalClick::BinaryDataType::MAX_FIXED_STRING)
    nullable_type = CrystalClick::BinaryDataType.nullable(fixed_type)
    type = CrystalClick::BinaryDataType.low_cardinality(nullable_type)
    null_value = CrystalClick::BinaryValue.low_cardinality(
      type,
      CrystalClick::BinaryValue.nullable(nullable_type)
    )

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryLowCardinalityStorageCodec.encode(
        type,
        [[null_value]] of Array(CrystalClick::BinaryValue),
        limits: w142_storage_limits(8)
      )
    end
  end

  it "accepts measured exact and rejects one-short encoder budgets for duplicate, empty, and NULL rows" do
    string_type = CrystalClick::BinaryDataType.primitive("String")
    string_lc = CrystalClick::BinaryDataType.low_cardinality(string_type)
    duplicate_rows = [w142_storage_low_strings(string_lc, ["same", "same", "same"])] of Array(CrystalClick::BinaryValue)
    empty_marks = [
      [] of CrystalClick::BinaryValue,
      [] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)
    nullable_type = CrystalClick::BinaryDataType.nullable(string_type)
    nullable_lc = CrystalClick::BinaryDataType.low_cardinality(nullable_type)
    null_rows = Array(CrystalClick::BinaryValue).new(3) do |_index|
      w142_storage_nullable_value(nullable_lc, nullable_type, nil)
    end
    nullable_null_marks = [null_rows] of Array(CrystalClick::BinaryValue)

    [
      {string_lc, duplicate_rows},
      {string_lc, empty_marks},
      {nullable_lc, nullable_null_marks},
    ].each do |case_data|
      type = case_data[0]
      values = case_data[1]
      measured = CrystalClick::BinaryCodecBudget.new(w142_storage_limits, true)
      CrystalClick::BinaryLowCardinalityStorageCodec.encode_with_budget(type, values, measured)
      nodes = measured.node_count.to_i
      elements = measured.element_count.to_i
      bytes = measured.wire_byte_count.to_i
      nodes.should be > 0
      elements.should be > 0
      bytes.should be > 0

      exact = w142_storage_exact_limits(nodes, elements, bytes)
      CrystalClick::BinaryLowCardinalityStorageCodec.encode(type, values, limits: exact).mark_count.should eq(values.size)

      [
        w142_storage_exact_limits(nodes - 1, elements, bytes),
        w142_storage_exact_limits(nodes, elements - 1, bytes),
        w142_storage_exact_limits(nodes, elements, bytes - 1),
      ].each do |limits|
        expect_raises(CrystalClick::UnsupportedFormatError) do
          CrystalClick::BinaryLowCardinalityStorageCodec.encode(type, values, limits: limits)
        end
      end
    end
  end

  it "resolves additional-only keys and nullable implicit NULL from each segment's dictionary mode" do
    string_type = CrystalClick::BinaryDataType.primitive("String")
    string_lc = CrystalClick::BinaryDataType.low_cardinality(string_type)
    nullable_type = CrystalClick::BinaryDataType.nullable(string_type)
    nullable_lc = CrystalClick::BinaryDataType.low_cardinality(nullable_type)
    version_only = w142_storage_u64_le(1_u64)

    additional_indexes = w142_storage_concat([
      w142_storage_u64_le(0x600_u64), # additional keys + dictionary update, no global dictionary
      w142_storage_u64_le(2_u64),
      w142_storage_string(""),
      w142_storage_string("x"),
      w142_storage_u64_le(2_u64),
      Bytes[0_u8, 1_u8],
    ] of Bytes)
    additional_streams = w142_storage_one_mark_streams(version_only, additional_indexes)

    nonnullable = CrystalClick::BinaryLowCardinalityStorageCodec.decode(
      string_lc,
      additional_streams,
      [2_u64]
    )[0]
    nonnullable.map { |value| value.child_at(0).as_string }.should eq(["", "x"])

    nullable = CrystalClick::BinaryLowCardinalityStorageCodec.decode(
      nullable_lc,
      additional_streams,
      [2_u64]
    )[0]
    nullable[0].child_at(0).is_null?.should be_true
    nullable[1].child_at(0).is_null?.should be_false
    nullable[1].child_at(0).child_at(0).as_string.should eq("x")
  end

  it "preserves both reserved nullable additional-only slots before nondefault keys" do
    string_type = CrystalClick::BinaryDataType.primitive("String")
    nullable_type = CrystalClick::BinaryDataType.nullable(string_type)
    type = CrystalClick::BinaryDataType.low_cardinality(nullable_type)
    indexes = w142_storage_concat([
      w142_storage_u64_le(0x600_u64), # additional dictionary update, no global lane
      w142_storage_u64_le(3_u64),
      w142_storage_string(""), # implicit nullable NULL slot
      w142_storage_string(""), # non-NULL underlying default slot
      w142_storage_string("a"),
      w142_storage_u64_le(3_u64),
      Bytes[0_u8, 1_u8, 2_u8],
    ] of Bytes)
    streams = w142_storage_one_mark_streams(w142_storage_u64_le(1_u64), indexes)

    values = CrystalClick::BinaryLowCardinalityStorageCodec.decode(type, streams, [3_u64])[0]
    values[0].child_at(0).is_null?.should be_true
    values[1].child_at(0).is_null?.should be_false
    values[1].child_at(0).child_at(0).as_string.should eq("")
    values[2].child_at(0).is_null?.should be_false
    values[2].child_at(0).child_at(0).as_string.should eq("a")
  end

  it "places nullable additional keys after a global dictionary without stealing global NULL/default IDs" do
    string_type = CrystalClick::BinaryDataType.primitive("String")
    nullable_type = CrystalClick::BinaryDataType.nullable(string_type)
    type = CrystalClick::BinaryDataType.low_cardinality(nullable_type)
    dictionary = w142_storage_native_streams(true).stream("root.dictionary").bytes
    indexes = w142_storage_concat([
      w142_storage_u64_le(0x700_u64), # global dictionary + additional key + update
      w142_storage_u64_le(1_u64),
      w142_storage_string("x"),
      w142_storage_u64_le(3_u64),
      Bytes[0_u8, 1_u8, 5_u8], # global NULL, global empty String, then additional "x"
    ] of Bytes)
    streams = w142_storage_one_mark_streams(dictionary, indexes)

    values = CrystalClick::BinaryLowCardinalityStorageCodec.decode(type, streams, [3_u64])[0]
    values[0].child_at(0).is_null?.should be_true
    values[1].child_at(0).is_null?.should be_false
    values[1].child_at(0).child_at(0).as_string.should eq("")
    values[2].child_at(0).is_null?.should be_false
    values[2].child_at(0).child_at(0).as_string.should eq("x")
  end

  it "applies updated global dictionaries while retaining the prior dictionary on no-update marks" do
    type = CrystalClick::BinaryDataType.low_cardinality(CrystalClick::BinaryDataType.primitive("String"))
    first_dictionary = w142_storage_dictionary_update("a")
    second_dictionary = w142_storage_dictionary_update("b")
    updated_dictionary = w142_storage_concat([
      w142_storage_u64_le(1_u64),
      first_dictionary,
      second_dictionary,
    ] of Bytes)
    first_indexes = w142_storage_index_mark(0_u64, [1_u64], 0x500_u64)
    second_indexes = w142_storage_index_mark(0_u64, [1_u64], 0x500_u64)
    update_streams = w142_storage_streams(
      updated_dictionary,
      [8_u64, (8 + first_dictionary.size).to_u64, updated_dictionary.size.to_u64],
      w142_storage_concat([first_indexes, second_indexes] of Bytes),
      [0_u64, first_indexes.size.to_u64, (first_indexes.size + second_indexes.size).to_u64],
      2
    )
    updated = CrystalClick::BinaryLowCardinalityStorageCodec.decode(
      type,
      update_streams,
      [1_u64, 1_u64],
      first_mark: 1,
      mark_count: 1
    )
    updated[0][0].child_at(0).as_string.should eq("b")

    inherited_dictionary = w142_storage_concat([
      w142_storage_u64_le(1_u64),
      first_dictionary,
    ] of Bytes)
    no_update_indexes = w142_storage_index_mark(0_u64, [1_u64], 0x100_u64)
    inherited_indexes = w142_storage_concat([first_indexes, no_update_indexes] of Bytes)
    inherited_streams = w142_storage_streams(
      inherited_dictionary,
      [8_u64, 8_u64, inherited_dictionary.size.to_u64],
      inherited_indexes,
      [0_u64, first_indexes.size.to_u64, inherited_indexes.size.to_u64],
      2
    )
    inherited = CrystalClick::BinaryLowCardinalityStorageCodec.decode(
      type,
      inherited_streams,
      [1_u64, 1_u64],
      first_mark: 1,
      mark_count: 1
    )
    inherited[0][0].child_at(0).as_string.should eq("a")
  end

  it "bootstraps the initial global dictionary when the first index record omits update" do
    type = CrystalClick::BinaryDataType.low_cardinality(CrystalClick::BinaryDataType.primitive("String"))
    dictionary = w142_storage_dictionary
    first_indexes = w142_storage_index_mark(0_u64, [1_u64], 0x100_u64)
    second_indexes = w142_storage_index_mark(0_u64, [2_u64], 0x100_u64)
    indexes = w142_storage_concat([first_indexes, second_indexes] of Bytes)
    streams = w142_storage_streams(
      dictionary,
      [8_u64, 8_u64, dictionary.size.to_u64],
      indexes,
      [0_u64, first_indexes.size.to_u64, indexes.size.to_u64],
      2
    )

    selected = CrystalClick::BinaryLowCardinalityStorageCodec.decode(
      type,
      streams,
      [1_u64, 1_u64],
      first_mark: 1,
      mark_count: 1
    )
    selected[0][0].child_at(0).as_string.should eq("blue")
  end

  it "rejects a changed global dictionary coordinate when the mark omits update" do
    type = CrystalClick::BinaryDataType.low_cardinality(CrystalClick::BinaryDataType.primitive("String"))
    first_dictionary = w142_storage_dictionary_update("a")
    second_dictionary = w142_storage_dictionary_update("b")
    dictionary = w142_storage_concat([
      w142_storage_u64_le(1_u64),
      first_dictionary,
      second_dictionary,
    ] of Bytes)
    first_indexes = w142_storage_index_mark(0_u64, [1_u64], 0x500_u64)
    no_update_indexes = w142_storage_index_mark(0_u64, [1_u64], 0x100_u64)
    indexes = w142_storage_concat([first_indexes, no_update_indexes] of Bytes)
    streams = w142_storage_streams(
      dictionary,
      [8_u64, (8 + first_dictionary.size).to_u64, dictionary.size.to_u64],
      indexes,
      [0_u64, first_indexes.size.to_u64, indexes.size.to_u64],
      2
    )

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryLowCardinalityStorageCodec.decode(
        type,
        streams,
        [1_u64, 1_u64],
        first_mark: 1,
        mark_count: 1
      )
    end
  end

  it "rejects multiple index records hidden inside one nonempty mark interval" do
    type = CrystalClick::BinaryDataType.low_cardinality(CrystalClick::BinaryDataType.primitive("String"))
    dictionary = w142_storage_dictionary_update("a")
    indexes = w142_storage_concat([
      w142_storage_index_mark(0_u64, [1_u64], 0x500_u64),
      w142_storage_index_mark(0_u64, [0_u64], 0x100_u64),
    ] of Bytes)
    streams = w142_storage_one_mark_streams(
      w142_storage_concat([w142_storage_u64_le(1_u64), dictionary] of Bytes),
      indexes
    )

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryLowCardinalityStorageCodec.decode(type, streams, [1_u64])
    end
  end

  it "skips a zero-occurrence flattened mark between populated index segments" do
    type = CrystalClick::BinaryDataType.low_cardinality(CrystalClick::BinaryDataType.primitive("String"))
    dictionary = w142_storage_concat([
      w142_storage_u64_le(1_u64),
      w142_storage_dictionary_update("a"),
    ] of Bytes)
    first_indexes = w142_storage_index_mark(0_u64, [1_u64], 0x500_u64)
    last_indexes = w142_storage_index_mark(0_u64, [1_u64], 0x100_u64)
    index_bytes = w142_storage_concat([first_indexes, last_indexes] of Bytes)
    streams = w142_storage_streams(
      dictionary,
      [8_u64, 8_u64, 8_u64, dictionary.size.to_u64],
      index_bytes,
      [0_u64, first_indexes.size.to_u64, first_indexes.size.to_u64, index_bytes.size.to_u64],
      3
    )

    decoded = CrystalClick::BinaryLowCardinalityStorageCodec.decode(
      type,
      streams,
      [1_u64, 0_u64, 1_u64]
    )
    decoded.size.should eq(3)
    decoded[0][0].child_at(0).as_string.should eq("a")
    decoded[1].should be_empty
    decoded[2][0].child_at(0).as_string.should eq("a")

    selected_empty = CrystalClick::BinaryLowCardinalityStorageCodec.decode(
      type,
      streams,
      [1_u64, 0_u64, 1_u64],
      first_mark: 1,
      mark_count: 1
    )
    selected_empty.size.should eq(1)
    selected_empty[0].should be_empty
  end

  it "represents all-empty marks and a zero-mark part without inventing index headers" do
    type = CrystalClick::BinaryDataType.low_cardinality(CrystalClick::BinaryDataType.primitive("String"))
    version_only = w142_storage_u64_le(1_u64)
    two_empty_marks = w142_storage_streams(
      version_only,
      [8_u64, 8_u64, 8_u64],
      Bytes.empty,
      [0_u64, 0_u64, 0_u64],
      2
    )
    decoded = CrystalClick::BinaryLowCardinalityStorageCodec.decode(
      type,
      two_empty_marks,
      [0_u64, 0_u64]
    )
    decoded.size.should eq(2)
    decoded.each(&.should be_empty)

    zero_marks = w142_storage_streams(version_only, [8_u64], Bytes.empty, [0_u64], 0)
    CrystalClick::BinaryLowCardinalityStorageCodec.decode(type, zero_marks, [] of UInt64).should be_empty
    bulk_empty = CrystalClick::BinaryBulkCodec.decode(
      type,
      two_empty_marks,
      [0_u64, 0_u64],
      first_mark: 0,
      mark_count: 2
    )
    bulk_empty.size.should eq(2)
    bulk_empty.each(&.should be_empty)
  end

  it "honors exact aggregate byte, node, and element budgets and rejects each one-short bound" do
    type = CrystalClick::BinaryDataType.low_cardinality(CrystalClick::BinaryDataType.primitive("String"))
    streams = w142_storage_one_mark_streams(
      w142_storage_dictionary,
      w142_storage_index_mark(0_u64, [1_u64])
    )
    measured = CrystalClick::BinaryCodecBudget.new(w142_storage_limits)
    CrystalClick::BinaryLowCardinalityStorageCodec.decode_with_budget(type, streams, [1_u64], measured)
    nodes = measured.node_count.to_i
    elements = measured.element_count.to_i
    bytes = measured.wire_byte_count.to_i
    nodes.should be > 0
    elements.should be > 0
    bytes.should be > 0

    exact = w142_storage_exact_limits(nodes, elements, bytes)
    CrystalClick::BinaryLowCardinalityStorageCodec.decode(
      type,
      streams,
      [1_u64],
      limits: exact
    ).size.should eq(1)

    [
      w142_storage_exact_limits(nodes - 1, elements, bytes),
      w142_storage_exact_limits(nodes, elements - 1, bytes),
      w142_storage_exact_limits(nodes, elements, bytes - 1),
    ].each do |limits|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryLowCardinalityStorageCodec.decode(type, streams, [1_u64], limits: limits)
      end
    end
  end

  it "charges additional dictionaries from unselected marks to aggregate node and element budgets" do
    type = CrystalClick::BinaryDataType.low_cardinality(CrystalClick::BinaryDataType.primitive("String"))
    additional_mark = ->(id : UInt8) do
      w142_storage_concat([
        w142_storage_u64_le(0x600_u64),
        w142_storage_u64_le(2_u64),
        w142_storage_string(""),
        w142_storage_string("x"),
        w142_storage_u64_le(1_u64),
        Bytes[id],
      ] of Bytes)
    end
    first = additional_mark.call(0_u8)
    second = additional_mark.call(1_u8)
    indexes = w142_storage_concat([first, second] of Bytes)
    streams = w142_storage_streams(
      w142_storage_u64_le(1_u64),
      [8_u64, 8_u64, 8_u64],
      indexes,
      [0_u64, first.size.to_u64, indexes.size.to_u64],
      2
    )

    # Metadata consumes 8 nodes/elements; selected output consumes 2 nodes
    # and 2 edges, while four additional String keys across both marks consume
    # at least four more nodes and four elements. One mark is deliberately
    # unselected, but replay still inspects/materializes its local dictionary.
    [
      w142_storage_exact_limits(13, 10_000, 1_024),
      w142_storage_exact_limits(10_000, 13, 1_024),
    ].each do |limits|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryLowCardinalityStorageCodec.decode(
          type,
          streams,
          [1_u64, 1_u64],
          first_mark: 1,
          mark_count: 1,
          limits: limits
        )
      end
    end
  end

  it "rejects UInt64::MAX dictionary, index, and supplied occurrence counts before materialization" do
    type = CrystalClick::BinaryDataType.low_cardinality(CrystalClick::BinaryDataType.primitive("String"))
    empty_indexes = w142_storage_index_mark(0_u64, [] of UInt64)

    huge_dictionary = w142_storage_concat([
      w142_storage_u64_le(1_u64),
      w142_storage_u64_le(UInt64::MAX),
    ] of Bytes)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryLowCardinalityStorageCodec.decode(
        type,
        w142_storage_one_mark_streams(huge_dictionary, w142_storage_index_mark(0_u64, [0_u64])),
        [1_u64]
      )
    end

    huge_index_count = w142_storage_concat([
      w142_storage_u64_le(0x503_u64), # global/update, UInt64 indexes
      w142_storage_u64_le(UInt64::MAX),
    ] of Bytes)
    expect_raises(CrystalClick::CorruptPartError, "LowCardinality index row count does not match its mark") do
      CrystalClick::BinaryLowCardinalityStorageCodec.decode(
        type,
        w142_storage_one_mark_streams(w142_storage_dictionary, huge_index_count),
        [1_u64]
      )
    end

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryLowCardinalityStorageCodec.decode(
        type,
        w142_storage_one_mark_streams(w142_storage_dictionary, empty_indexes),
        [UInt64::MAX]
      )
    end
  end

  it "detaches lane bytes and offset grids from both constructor buffers and returned snapshots" do
    type = CrystalClick::BinaryDataType.low_cardinality(CrystalClick::BinaryDataType.primitive("String"))
    original_dictionary = w142_storage_dictionary
    original_indexes = w142_storage_index_mark(0_u64, [1_u64])
    dictionary_stream = CrystalClick::BinaryBulkStream.new(original_dictionary, [8_u64, original_dictionary.size.to_u64])
    index_stream = CrystalClick::BinaryBulkStream.new(original_indexes, [0_u64, original_indexes.size.to_u64])
    streams = CrystalClick::BinaryBulkStreams.new(
      mark_count: 1,
      streams: {
        "root.dictionary" => dictionary_stream,
        "root.indexes"    => index_stream,
      } of String => CrystalClick::BinaryBulkStream
    )

    original_dictionary[9] = 0_u8
    original_indexes[8] = 0xff_u8
    dictionary_copy = streams.stream("root.dictionary").bytes
    index_copy = streams.stream("root.indexes").bytes
    dictionary_copy[9] = 0_u8
    index_copy[8] = 0xff_u8
    dictionary_offsets = streams.stream("root.dictionary").offsets
    index_offsets = streams.stream("root.indexes").offsets
    dictionary_offsets[0] = 0_u64
    index_offsets[1] = 0_u64

    decoded = CrystalClick::BinaryLowCardinalityStorageCodec.decode(type, streams, [1_u64])
    decoded[0][0].child_at(0).as_string.should eq("red")
  end

  it "rejects wrong lane roles, malformed special grids, and out-of-range selected windows" do
    type = CrystalClick::BinaryDataType.low_cardinality(CrystalClick::BinaryDataType.primitive("String"))
    dictionary = w142_storage_dictionary
    indexes = w142_storage_index_mark(0_u64, [1_u64])

    wrong_roles = CrystalClick::BinaryBulkStreams.new(
      mark_count: 1,
      streams: {
        "root.dict"    => CrystalClick::BinaryBulkStream.new(dictionary, [8_u64, dictionary.size.to_u64]),
        "root.indexes" => CrystalClick::BinaryBulkStream.new(indexes, [0_u64, indexes.size.to_u64]),
      } of String => CrystalClick::BinaryBulkStream
    )
    malformed_grids = [
      w142_storage_streams(dictionary, [7_u64, dictionary.size.to_u64], indexes, [0_u64, indexes.size.to_u64], 1),
      w142_storage_streams(dictionary, [8_u64, dictionary.size.to_u64], indexes, [0_u64, indexes.size.to_u64 + 1_u64], 1),
      w142_storage_streams(dictionary, [8_u64], indexes, [0_u64, indexes.size.to_u64], 1),
    ] of CrystalClick::BinaryBulkStreams
    malformed_grids.each do |streams|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryLowCardinalityStorageCodec.decode(type, streams, [1_u64])
      end
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryLowCardinalityStorageCodec.decode(type, wrong_roles, [1_u64])
    end

    valid = w142_storage_one_mark_streams(dictionary, indexes)
    [
      {-1, 0},
      {2, 0},
      {0, 2},
    ].each do |window|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryLowCardinalityStorageCodec.decode(
          type,
          valid,
          [1_u64],
          first_mark: window[0],
          mark_count: window[1]
        )
      end
    end
  end

  it "keeps Dynamic closed while binding an empty typed Object LC roster" do
    string_type = CrystalClick::BinaryDataType.primitive("String")
    type = CrystalClick::BinaryDataType.low_cardinality(string_type)
    dynamic = CrystalClick::DynamicStructure.new([type] of CrystalClick::BinaryDataType)
    discriminator = CrystalClick::DynamicDiscriminatorCodec.encode(
      dynamic,
      [] of Array(UInt8)
    )
    empty_string = CrystalClick::BinaryBulkStreams.new(
      mark_count: 0,
      streams: {
        "root.data" => CrystalClick::BinaryBulkStream.new(Bytes.empty, [0_u64]),
      } of String => CrystalClick::BinaryBulkStream
    )
    empty_low_cardinality = w142_storage_streams(
      w142_storage_u64_le(1_u64),
      [8_u64],
      Bytes.empty,
      [0_u64],
      0
    )
    dynamic_streams = CrystalClick::DynamicValueStreams.new(
      discriminator,
      {
        "SharedVariant" => empty_string,
        type.name       => empty_low_cardinality,
      } of String => CrystalClick::BinaryBulkStreams
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::DynamicValueCodec.decode(dynamic, dynamic_streams)
    end

    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure
    )
    typed_plan = CrystalClick::ObjectDocumentPlan.new(structures, {"typed" => type})
    typed_physical = CrystalClick::ObjectDocumentPhysicalPlan.new("obj", typed_plan)
    typed_physical.typed("typed").stream_names.should eq({
      "root.dictionary" => "obj.typed.dict",
      "root.indexes"    => "obj.typed",
    })

    object_dynamic = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["dynamic"] of String),
      {"dynamic" => dynamic}
    )
    dynamic_plan = CrystalClick::ObjectDocumentPlan.new(
      object_dynamic,
      {} of String => CrystalClick::BinaryDataType
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentPhysicalPlan.new("obj", dynamic_plan)
    end
  end
end
