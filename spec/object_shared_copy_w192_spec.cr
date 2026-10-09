require "./spec_helper"

private def w192_record(
  row_count : UInt64,
  paths : Array(String),
) : CrystalClick::ObjectSharedChunkStructure
  CrystalClick::ObjectSharedChunkStructure.new(
    row_count,
    paths,
    {0_u64, 0_u64},
    {0_u64, 0_u64},
    {0_u64, 0_u64},
  )
end

private def w192_structures(
  paths : Array(String),
  bucket_count : Int,
  row_count : UInt64 = 1_u64,
) : Array(CrystalClick::ObjectSharedChunkStructure)
  grouped = Array(Array(String)).new(bucket_count) { [] of String }
  paths.each do |path|
    bucket = CrystalClick::ObjectSharedBucketLayout.bucket_for(path, bucket_count)
    grouped[bucket] << path
  end
  grouped.map do |bucket_paths|
    bucket_paths.sort! do |left, right|
      CrystalClick::ObjectSharedChunkStructure.compare_paths(left, right)
    end
    w192_record(row_count, bucket_paths)
  end
end

private def w192_row(paths : Array(String), values : Array(CrystalClick::BinaryValue)) : CrystalClick::ObjectSharedMapRow
  raise "test fixture path/value mismatch" unless paths.size == values.size
  entries = Array(CrystalClick::ObjectSharedMapEntry).new(paths.size)
  paths.each_with_index do |path, index|
    entries << CrystalClick::ObjectSharedMapEntry.new(path.to_slice, values[index])
  end
  CrystalClick::ObjectSharedMapRow.new(entries)
end

private def w192_var_uint(value : UInt64) : Bytes
  output = [] of UInt8
  remaining = value
  loop do
    payload = (remaining & 0x7f_u64).to_u8
    remaining >>= 7
    output << (remaining == 0_u64 ? payload : payload | 0x80_u8)
    break if remaining == 0_u64
  end
  Bytes.new(output.size) { |index| output[index] }
end

private def w192_concat(parts : Array(Bytes)) : Bytes
  total = 0
  parts.each { |part| total += part.size }
  output = Bytes.new(total)
  offset = 0
  parts.each do |part|
    part.each do |byte|
      output[offset] = byte
      offset += 1
    end
  end
  output
end

private def w192_sizes(counts : Array(UInt64)) : Bytes
  output = Bytes.new(counts.size * 8)
  counts.each_with_index do |count, row_index|
    8.times do |byte_index|
      output[row_index * 8 + byte_index] = ((count >> (byte_index * 8)) & 0xff_u64).to_u8
    end
  end
  output
end

private def w192_outer_string(envelope : Bytes) : Bytes
  w192_concat([w192_var_uint(envelope.size.to_u64), envelope] of Bytes)
end

private def w192_bool_value(value : Bool) : Bytes
  Bytes[0x02_u8, 0x2d_u8, value ? 0x01_u8 : 0x00_u8]
end

private def w192_bool_rows(paths : Array(String)) : Array(CrystalClick::ObjectSharedMapRow)
  entries = Array(CrystalClick::ObjectSharedMapEntry).new(paths.size)
  paths.each_with_index do |path, index|
    entries << CrystalClick::ObjectSharedMapEntry.new(
      path.to_slice,
      CrystalClick::BinaryValue.bool(index.even?),
    )
  end
  [CrystalClick::ObjectSharedMapRow.new(entries)] of CrystalClick::ObjectSharedMapRow
end

private def w192_limits(
  max_depth : Int = 64,
  max_nodes : Int = 4_096,
  max_elements : Int = 1_000_000,
  max_bytes : Int = 64 * 1024 * 1024,
) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(max_depth, max_nodes, max_elements, max_bytes)
end

private def w192_two_bucket_non_global_order : Tuple(Array(String), Array(String))
  bucket_one_path : String? = nil
  bucket_zero_path : String? = nil
  candidate = 0
  while bucket_one_path.nil? || bucket_zero_path.nil?
    suffix = candidate.to_s
    name_a = "a#{suffix}"
    name_z = "z#{suffix}"
    if CrystalClick::ObjectSharedBucketLayout.bucket_for(name_a, 2) == 1 && bucket_one_path.nil?
      bucket_one_path = name_a
    end
    if CrystalClick::ObjectSharedBucketLayout.bucket_for(name_z, 2) == 0 && bucket_zero_path.nil?
      bucket_zero_path = name_z
    end
    candidate += 1
  end
  row_paths = [bucket_one_path.not_nil!, bucket_zero_path.not_nil!] of String
  dictionary_order = [bucket_zero_path.not_nil!, bucket_one_path.not_nil!] of String
  {row_paths, dictionary_order}
end

describe "W192 paired Object shared Copy codec" do
  it "decodes and exactly re-encodes the first stock root ADVANCED v2 chunk" do
    # These exact first-chunk slices are independently cut from the retained
    # W191 decompressor outputs. Full-lane stdout SHA-256 values are:
    # sizes 493c238f320b0c861040b1c683dd4f3ba02617e92db016df26d8bf1d01991a8a,
    # indexes ed8404ae356f14216e3b4a252c2d69721551ce0d544e80e9b82e920d594734fd,
    # values 138f1061f5a7504b62d630b13dfe748732a9b73e570dc3755c445c11286dd856.
    # The two UInt64 counts are [1, 2]; they are row counts, not prefixes.
    sizes = Bytes[
      0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x02_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    ]
    indexes = Bytes[0x01_u8, 0x00_u8, 0x02_u8]
    values = Bytes[
      0x0b_u8, 0x15_u8, 0x09_u8, 0x72_u8, 0x2d_u8, 0x61_u8, 0x6c_u8, 0x70_u8, 0x68_u8, 0x61_u8, 0x2d_u8, 0x31_u8,
      0x08_u8, 0x15_u8, 0x06_u8, 0x72_u8, 0x2d_u8, 0x61_u8, 0x61_u8, 0x2d_u8, 0x32_u8,
      0x0a_u8, 0x15_u8, 0x08_u8, 0x72_u8, 0x2d_u8, 0x62_u8, 0x65_u8, 0x74_u8, 0x61_u8, 0x2d_u8, 0x32_u8,
    ]
    structures = w192_structures(["alpha", "aa", "beta"] of String, 2, 2_u64)
    rows = [
      w192_row(["alpha"] of String, [CrystalClick::BinaryValue.string("r-alpha-1")] of CrystalClick::BinaryValue),
      w192_row(
        ["aa", "beta"] of String,
        [CrystalClick::BinaryValue.string("r-aa-2"), CrystalClick::BinaryValue.string("r-beta-2")] of CrystalClick::BinaryValue,
      ),
    ] of CrystalClick::ObjectSharedMapRow

    decoded = CrystalClick::ObjectSharedCopyCodec.decode(sizes, indexes, values, structures)
    decoded.size.should eq(2)
    decoded[0].entry_at(0).path.should eq(Bytes[0x61_u8, 0x6c_u8, 0x70_u8, 0x68_u8, 0x61_u8])
    decoded[0].entry_at(0).value.as_string.should eq("r-alpha-1")
    decoded[1].entry_at(0).path.should eq(Bytes[0x61_u8, 0x61_u8])
    decoded[1].entry_at(0).value.as_string.should eq("r-aa-2")
    decoded[1].entry_at(1).path.should eq(Bytes[0x62_u8, 0x65_u8, 0x74_u8, 0x61_u8])
    decoded[1].entry_at(1).value.as_string.should eq("r-beta-2")

    encoded = CrystalClick::ObjectSharedCopyCodec.encode(rows, structures)
    encoded.sizes.should eq(sizes)
    encoded.indexes.should eq(indexes)
    encoded.values.should eq(values)
  end

  it "keeps bucket ordinal dictionary order separate from each row's byte-sorted path order" do
    row_paths, dictionary_order = w192_two_bucket_non_global_order
    structures = Array(CrystalClick::ObjectSharedChunkStructure).new
    structures << w192_record(1_u64, [dictionary_order[0]] of String)
    structures << w192_record(1_u64, [dictionary_order[1]] of String)
    rows = [w192_bool_rows(row_paths)[0]] of CrystalClick::ObjectSharedMapRow

    CrystalClick::ObjectSharedBucketLayout.bucket_for(dictionary_order[0], 2).should eq(0)
    CrystalClick::ObjectSharedBucketLayout.bucket_for(dictionary_order[1], 2).should eq(1)
    CrystalClick::ObjectSharedChunkStructure.compare_paths(row_paths[0], row_paths[1]).should be < 0

    encoded = CrystalClick::ObjectSharedCopyCodec.encode(rows, structures)
    encoded.sizes.should eq(w192_sizes([2_u64] of UInt64))
    encoded.indexes.should eq(Bytes[0x01_u8, 0x00_u8])
    encoded.values.should eq(w192_concat([
      w192_bool_value(true), w192_bool_value(false),
    ] of Bytes))
    decoded = CrystalClick::ObjectSharedCopyCodec.decode(encoded.sizes, encoded.indexes, encoded.values, structures)
    decoded[0].entry_at(0).path.should eq(row_paths[0].to_slice)
    decoded[0].entry_at(1).path.should eq(row_paths[1].to_slice)
  end

  it "round-trips nested Array, Tuple, Nullable, opaque paths, and the Dynamic Nothing NULL sentinel" do
    int64 = CrystalClick::BinaryDataType.primitive("Int64")
    string = CrystalClick::BinaryDataType.primitive("String")
    nullable_int64 = CrystalClick::BinaryDataType.nullable(int64)
    nullable_string = CrystalClick::BinaryDataType.nullable(string)
    array_type = CrystalClick::BinaryDataType.array(nullable_int64)
    tuple_type = CrystalClick::BinaryDataType.tuple(
      [array_type, nullable_string] of CrystalClick::BinaryDataType,
      ["items", "label"] of String,
    )
    array_value = CrystalClick::BinaryValue.array(array_type, [
      CrystalClick::BinaryValue.nullable(nullable_int64),
      CrystalClick::BinaryValue.nullable(nullable_int64, CrystalClick::BinaryValue.int64(42_i64)),
    ] of CrystalClick::BinaryValue)
    tuple_value = CrystalClick::BinaryValue.tuple(tuple_type, [
      array_value,
      CrystalClick::BinaryValue.nullable(nullable_string, CrystalClick::BinaryValue.string("inside")),
    ] of CrystalClick::BinaryValue)
    opaque_paths = [String.new(Bytes[0x00_u8]), String.new(Bytes[0xff_u8])] of String
    row = w192_row(opaque_paths, [tuple_value, CrystalClick::BinaryValue.null] of CrystalClick::BinaryValue)
    structures = w192_structures(opaque_paths, 1)
    rows = [row] of CrystalClick::ObjectSharedMapRow

    encoded = CrystalClick::ObjectSharedCopyCodec.encode(rows, structures)
    decoded = CrystalClick::ObjectSharedCopyCodec.decode(encoded.sizes, encoded.indexes, encoded.values, structures)
    decoded[0].entry_at(0).path.should eq(Bytes[0x00_u8])
    decoded[0].entry_at(1).path.should eq(Bytes[0xff_u8])
    decoded[0].entry_at(0).value.type.name.should eq("Tuple(items Array(Nullable(Int64)), label Nullable(String))")
    tuple = decoded[0].entry_at(0).value.elements
    tuple[0].elements[0].is_null?.should be_true
    tuple[0].elements[1].elements[0].as_int64.should eq(42_i64)
    tuple[1].elements[0].as_string.should eq("inside")
    decoded[0].entry_at(1).value.type.name.should eq("Nothing")
    decoded[0].entry_at(1).value.is_null?.should be_true
  end

  it "retains zero-child chunks and positive-row chunks with empty dictionaries" do
    zero_chunk_structures = [w192_record(0_u64, [] of String)] of CrystalClick::ObjectSharedChunkStructure
    zero_chunk_rows = [] of CrystalClick::ObjectSharedMapRow
    zero_chunk = CrystalClick::ObjectSharedCopyCodec.encode(zero_chunk_rows, zero_chunk_structures)
    zero_chunk.sizes.should be_empty
    zero_chunk.indexes.should be_empty
    zero_chunk.values.should be_empty
    CrystalClick::ObjectSharedCopyCodec.decode(
      zero_chunk.sizes,
      zero_chunk.indexes,
      zero_chunk.values,
      zero_chunk_structures,
    ).should be_empty

    empty_rows = [
      CrystalClick::ObjectSharedMapRow.new([] of CrystalClick::ObjectSharedMapEntry),
      CrystalClick::ObjectSharedMapRow.new([] of CrystalClick::ObjectSharedMapEntry),
    ] of CrystalClick::ObjectSharedMapRow
    positive_rows_structures = [w192_record(2_u64, [] of String)] of CrystalClick::ObjectSharedChunkStructure
    encoded = CrystalClick::ObjectSharedCopyCodec.encode(empty_rows, positive_rows_structures)
    encoded.sizes.should eq(w192_sizes([0_u64, 0_u64] of UInt64))
    encoded.indexes.should be_empty
    encoded.values.should be_empty
    decoded = CrystalClick::ObjectSharedCopyCodec.decode(
      encoded.sizes,
      encoded.indexes,
      encoded.values,
      positive_rows_structures,
    )
    decoded.size.should eq(2)
    decoded.each { |row| row.entry_count.should eq(0) }
  end

  it "rejects structure row disagreement, bucket misplacement, duplicate or unused dictionary paths" do
    row = w192_row(["a"] of String, [CrystalClick::BinaryValue.bool(true)] of CrystalClick::BinaryValue)
    rows = [row] of CrystalClick::ObjectSharedMapRow
    good = w192_structures(["a"] of String, 2)
    streams = CrystalClick::ObjectSharedCopyCodec.encode(rows, good)

    mismatched = [w192_record(1_u64, ["a"] of String), w192_record(2_u64, [] of String)] of CrystalClick::ObjectSharedChunkStructure
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedCopyCodec.decode(streams.sizes, streams.indexes, streams.values, mismatched)
    end

    bucket_zero_path = (0..1024).map { |index| "misplaced#{index}" }.find do |path|
      CrystalClick::ObjectSharedBucketLayout.bucket_for(path, 2) == 0
    end.not_nil!
    misplaced = [w192_record(1_u64, [] of String), w192_record(1_u64, [bucket_zero_path] of String)] of CrystalClick::ObjectSharedChunkStructure
    misplaced_row = w192_row([bucket_zero_path] of String, [CrystalClick::BinaryValue.bool(true)] of CrystalClick::BinaryValue)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectSharedCopyCodec.encode([misplaced_row] of CrystalClick::ObjectSharedMapRow, misplaced)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedCopyCodec.decode(streams.sizes, streams.indexes, streams.values, misplaced)
    end

    duplicate = [w192_record(1_u64, ["a"] of String), w192_record(1_u64, ["a"] of String)] of CrystalClick::ObjectSharedChunkStructure
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedCopyCodec.decode(streams.sizes, streams.indexes, streams.values, duplicate)
    end

    unused = w192_structures(["a", "unused"] of String, 1)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectSharedCopyCodec.encode(rows, unused)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedCopyCodec.decode(streams.sizes, streams.indexes, streams.values, unused)
    end
  end

  it "rejects row-count mismatches, oversized counts, and counts that exceed the in-memory total domain" do
    structure = [w192_record(1_u64, [] of String)] of CrystalClick::ObjectSharedChunkStructure
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedCopyCodec.decode(w192_sizes([0_u64, 0_u64] of UInt64), Bytes.empty, Bytes.empty, structure)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedCopyCodec.decode(w192_sizes([UInt64::MAX] of UInt64), Bytes.empty, Bytes.empty, structure)
    end

    two_rows = [w192_record(2_u64, [] of String)] of CrystalClick::ObjectSharedChunkStructure
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedCopyCodec.decode(
        w192_sizes([Int32::MAX.to_u64, 1_u64] of UInt64),
        Bytes.empty,
        Bytes.empty,
        two_rows,
      )
    end
  end

  it "rejects fixed-width index extents outside the dictionary and unsorted reconstructed rows" do
    one_path = w192_structures(["a"] of String, 1)
    sizes = w192_sizes([1_u64] of UInt64)
    values = w192_bool_value(true)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedCopyCodec.decode(sizes, Bytes.empty, values, one_path)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedCopyCodec.decode(sizes, Bytes[0_u8, 0_u8], values, one_path)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedCopyCodec.decode(sizes, Bytes[0x01_u8], values, one_path)
    end

    two_paths = w192_structures(["a", "b"] of String, 1)
    reversed_sizes = w192_sizes([2_u64] of UInt64)
    reversed_indexes = Bytes[0x01_u8, 0x00_u8]
    reversed_values = w192_concat([w192_bool_value(true), w192_bool_value(false)] of Bytes)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedCopyCodec.decode(reversed_sizes, reversed_indexes, reversed_values, two_paths)
    end
  end

  it "rejects truncated, trailing, and noncanonical outer String frames and inner Dynamic envelopes" do
    structures = w192_structures(["a"] of String, 1)
    sizes = w192_sizes([1_u64] of UInt64)
    indexes = Bytes[0x00_u8]
    [
      Bytes.empty,
      Bytes[0x05_u8, 0x2d_u8],
      Bytes[0x80_u8, 0x00_u8, 0x2d_u8, 0x01_u8],
      Bytes[0x02_u8, 0x2d_u8, 0x01_u8, 0x00_u8],
      Bytes[0x03_u8, 0x2d_u8, 0x01_u8, 0x00_u8],
    ].each do |malformed_values|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::ObjectSharedCopyCodec.decode(sizes, indexes, malformed_values, structures)
      end
    end
  end

  it "round-trips the now-admitted JSON actual envelope without changing its descriptor" do
    json_type = CrystalClick::BinaryDataType.json(max_dynamic_paths: 0, max_dynamic_types: 0)
    json_row = CrystalClick::BinaryJsonRow.new(json_type, [] of Tuple(String, CrystalClick::BinaryValue))
    json_value = CrystalClick::BinaryValue.json(json_type, json_row)
    row = w192_row(["json"] of String, [json_value] of CrystalClick::BinaryValue)
    structures = w192_structures(["json"] of String, 1)
    streams = CrystalClick::ObjectSharedCopyCodec.encode([row] of CrystalClick::ObjectSharedMapRow, structures)
    decoded = CrystalClick::ObjectSharedCopyCodec.decode(streams.sizes, streams.indexes, streams.values, structures)
    decoded[0].entry_at(0).value.type.should eq(json_type)
    decoded[0].entry_at(0).value.json_row.empty?.should be_true
    CrystalClick::BinaryValueCodec.encode(decoded[0].entry_at(0).value).should eq(
      CrystalClick::BinaryValueCodec.encode(json_value),
    )
  end

  it "detaches all stream getters and reconstructed opaque path bytes" do
    raw_path = String.new(Bytes[0x80_u8, 0x00_u8, 0xff_u8])
    row = w192_row([raw_path] of String, [CrystalClick::BinaryValue.string("raw")] of CrystalClick::BinaryValue)
    structures = w192_structures([raw_path] of String, 1)
    streams = CrystalClick::ObjectSharedCopyCodec.encode([row] of CrystalClick::ObjectSharedMapRow, structures)
    sizes_before = streams.sizes
    indexes_before = streams.indexes
    values_before = streams.values
    exposed_sizes = streams.sizes
    exposed_indexes = streams.indexes
    exposed_values = streams.values
    exposed_sizes[0] = exposed_sizes[0] ^ 0xff_u8
    exposed_indexes[0] = exposed_indexes[0] ^ 0xff_u8
    exposed_values[0] = exposed_values[0] ^ 0xff_u8
    streams.sizes.should eq(sizes_before)
    streams.indexes.should eq(indexes_before)
    streams.values.should eq(values_before)

    decoded = CrystalClick::ObjectSharedCopyCodec.decode(sizes_before, indexes_before, values_before, structures)
    sizes_before[0] = 0xff_u8
    indexes_before[0] = 0xff_u8
    values_before[0] = 0xff_u8
    decoded[0].entry_at(0).path.should eq(Bytes[0x80_u8, 0x00_u8, 0xff_u8])
    decoded[0].entry_at(0).value.as_string.should eq("raw")
  end

  it "uses one caller budget across Copy lanes, dictionary metadata, rows, entries, and scalar children" do
    paths = ["a", "longer"] of String
    rows = [
      w192_row(["a"] of String, [CrystalClick::BinaryValue.bool(true)] of CrystalClick::BinaryValue),
      w192_row(["longer"] of String, [CrystalClick::BinaryValue.bool(false)] of CrystalClick::BinaryValue),
    ] of CrystalClick::ObjectSharedMapRow
    structures = w192_structures(paths, 1, 2_u64)
    write_budget = CrystalClick::BinaryCodecBudget.new(w192_limits, true)
    encoded = CrystalClick::ObjectSharedCopyCodec.encode_with_budget(rows, structures, write_budget)
    write_budget.wire_byte_count.should eq(
      (encoded.sizes.size + encoded.indexes.size + encoded.values.size).to_i64,
    )
    write_budget.element_count.should be >= 7_i64

    read_budget = CrystalClick::BinaryCodecBudget.new(w192_limits)
    decoded = CrystalClick::ObjectSharedCopyCodec.decode_with_budget(
      encoded.sizes,
      encoded.indexes,
      encoded.values,
      structures,
      read_budget,
    )
    decoded.size.should eq(2)
    read_budget.wire_byte_count.should eq(
      (encoded.sizes.size + encoded.indexes.size + encoded.values.size).to_i64,
    )

    measured_budget = CrystalClick::BinaryCodecBudget.new(w192_limits, true)
    CrystalClick::ObjectSharedCopyCodec.encode_with_budget(rows, structures, measured_budget)
    tight_nodes = measured_budget.node_count.to_i + 1
    tight_elements = measured_budget.element_count.to_i * 2 + 1
    tight_bytes = measured_budget.wire_byte_count.to_i * 2 + 1
    shared_budget = CrystalClick::BinaryCodecBudget.new(
      w192_limits(max_nodes: tight_nodes, max_elements: tight_elements, max_bytes: tight_bytes),
      true,
    )
    CrystalClick::ObjectSharedCopyCodec.encode_with_budget(rows, structures, shared_budget)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectSharedCopyCodec.encode_with_budget(rows, structures, shared_budget)
    end

    measured_read_budget = CrystalClick::BinaryCodecBudget.new(w192_limits)
    CrystalClick::ObjectSharedCopyCodec.decode_with_budget(
      encoded.sizes,
      encoded.indexes,
      encoded.values,
      structures,
      measured_read_budget,
    )
    read_tight_nodes = measured_read_budget.node_count.to_i + 1
    read_tight_elements = measured_read_budget.element_count.to_i * 2 + 1
    read_tight_bytes = measured_read_budget.wire_byte_count.to_i * 2 + 1
    shared_read_budget = CrystalClick::BinaryCodecBudget.new(
      w192_limits(max_nodes: read_tight_nodes, max_elements: read_tight_elements, max_bytes: read_tight_bytes),
    )
    CrystalClick::ObjectSharedCopyCodec.decode_with_budget(
      encoded.sizes,
      encoded.indexes,
      encoded.values,
      structures,
      shared_read_budget,
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedCopyCodec.decode_with_budget(
        encoded.sizes,
        encoded.indexes,
        encoded.values,
        structures,
        shared_read_budget,
      )
    end

    expect_raises(ArgumentError) do
      CrystalClick::ObjectSharedCopyCodec.encode_with_budget(
        rows,
        structures,
        CrystalClick::BinaryCodecBudget.new(w192_limits),
      )
    end
    expect_raises(ArgumentError) do
      CrystalClick::ObjectSharedCopyCodec.decode_with_budget(
        encoded.sizes,
        encoded.indexes,
        encoded.values,
        structures,
        CrystalClick::BinaryCodecBudget.new(w192_limits, true),
      )
    end
  end

  it "preflights repeated long-path copies as logical element work rather than duplicate wire bytes" do
    long_path = String.new(Bytes.new(256) { 0x70_u8 })
    rows = Array(CrystalClick::ObjectSharedMapRow).new(32)
    32.times do
      rows << w192_row([long_path] of String, [CrystalClick::BinaryValue.bool(true)] of CrystalClick::BinaryValue)
    end
    structures = w192_structures([long_path] of String, 1, 32_u64)
    fixture = CrystalClick::ObjectSharedCopyCodec.encode(
      rows,
      structures,
      w192_limits(max_nodes: 10_000, max_elements: 100_000, max_bytes: 100_000),
    )
    fixture.values.size.should be < long_path.bytesize * 32

    limits = w192_limits(max_nodes: 10_000, max_elements: 2_000, max_bytes: 100_000)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectSharedCopyCodec.encode(rows, structures, limits)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedCopyCodec.decode(
        fixture.sizes,
        fixture.indexes,
        fixture.values,
        structures,
        limits,
      )
    end
  end

  it "selects UInt8, UInt16, and UInt32 index widths at actual dictionary boundaries" do
    [
      {256, 1, Bytes[0xff_u8]},
      {257, 2, Bytes[0x00_u8, 0x01_u8]},
      {65_536, 2, Bytes[0xff_u8, 0xff_u8]},
      {65_537, 4, Bytes[0x00_u8, 0x00_u8, 0x01_u8, 0x00_u8]},
    ].each do |case_data|
      count = case_data[0]
      width = case_data[1]
      final_index = case_data[2]
      paths = Array(String).new(count) { |index| "p#{index}" }
      paths.sort! { |left, right| CrystalClick::ObjectSharedChunkStructure.compare_paths(left, right) }
      rows = w192_bool_rows(paths)
      structures = w192_structures(paths, 1)
      limits = w192_limits(
        max_depth: 64,
        max_nodes: 1_000_000,
        max_elements: 4_000_000,
        max_bytes: 16 * 1024 * 1024,
      )
      encoded = CrystalClick::ObjectSharedCopyCodec.encode(rows, structures, limits)
      encoded.sizes.should eq(w192_sizes([count.to_u64] of UInt64))
      encoded.indexes.size.should eq(count * width)
      encoded.indexes[count * width - final_index.size, final_index.size].should eq(final_index)
      decoded = CrystalClick::ObjectSharedCopyCodec.decode(
        encoded.sizes,
        encoded.indexes,
        encoded.values,
        structures,
        limits,
      )
      decoded.size.should eq(1)
      decoded[0].entry_count.should eq(count)
      decoded[0].entry_at(0).path.should eq(paths[0].to_slice)
      decoded[0].entry_at(count - 1).path.should eq(paths[count - 1].to_slice)
    end
  end
end
