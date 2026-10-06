require "./spec_helper"

private def w195_limits(
  max_depth : Int = 64,
  max_nodes : Int = 100_000,
  max_elements : Int = 1_000_000,
  max_bytes : Int = 64 * 1024 * 1024,
) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(max_depth, max_nodes, max_elements, max_bytes)
end

private def w195_paths_per_bucket(bucket_count : Int, per_bucket : Int = 1) : Array(String)
  grouped = Array(Array(String)).new(bucket_count) { [] of String }
  candidate = 0
  while grouped.any? { |paths| paths.size < per_bucket }
    path = "w195-path-#{candidate}"
    bucket = CrystalClick::ObjectSharedBucketLayout.bucket_for(path, bucket_count)
    grouped[bucket] << path if grouped[bucket].size < per_bucket
    candidate += 1
  end
  grouped.flatten
end

private def w195_row(pairs : Array(Tuple(String, CrystalClick::BinaryValue))) : CrystalClick::ObjectSharedMapRow
  entries = pairs.map do |pair|
    CrystalClick::ObjectSharedMapEntry.new(pair[0].to_slice, pair[1])
  end
  entries.sort! do |left, right|
    common_size = Math.min(left.path_byte_size, right.path_byte_size)
    comparison = 0
    common_size.times do |index|
      if left.path_byte_at(index) != right.path_byte_at(index)
        comparison = left.path_byte_at(index) <=> right.path_byte_at(index)
        break
      end
    end
    comparison == 0 ? left.path_byte_size <=> right.path_byte_size : comparison
  end
  CrystalClick::ObjectSharedMapRow.new(entries)
end

private def w195_assert_rows(
  actual : Array(CrystalClick::ObjectSharedMapRow),
  expected : Array(CrystalClick::ObjectSharedMapRow),
) : Nil
  actual.size.should eq(expected.size)
  actual.each_with_index do |row, row_index|
    row.entry_count.should eq(expected[row_index].entry_count)
    row.entry_count.times do |entry_index|
      left = row.entry_at(entry_index)
      right = expected[row_index].entry_at(entry_index)
      left.path_byte_size.should eq(right.path_byte_size)
      left.path_byte_size.times do |byte_index|
        left.path_byte_at(byte_index).should eq(right.path_byte_at(byte_index))
      end
      w195_value_exact?(left.value, right.value).should be_true
    end
  end
end

private def w195_value_exact?(actual : CrystalClick::BinaryValue, expected : CrystalClick::BinaryValue) : Bool
  return false unless actual.type == expected.type
  return false unless actual.is_null? == expected.is_null?
  return true if actual.is_null?
  if actual.type.tag == CrystalClick::BinaryDataType::TAG_VARIANT
    return false unless actual.variant_index? == expected.variant_index?
  end
  if actual.type.tag == CrystalClick::BinaryDataType::TAG_JSON || actual.type.contains_qbit?
    return actual == expected
  end
  if w195_composite_value?(actual.type)
    return false unless actual.child_count == expected.child_count
    actual.child_count.times do |index|
      return false unless w195_value_exact?(actual.child_at(index), expected.child_at(index))
    end
    return true
  end
  return false unless actual.byte_size == expected.byte_size
  actual.byte_size.times do |index|
    return false unless actual.byte_at(index) == expected.byte_at(index)
  end
  true
end

private def w195_composite_value?(type : CrystalClick::BinaryDataType) : Bool
  case type.tag
  when CrystalClick::BinaryDataType::TAG_ARRAY,
       CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE,
       CrystalClick::BinaryDataType::TAG_NAMED_TUPLE,
       CrystalClick::BinaryDataType::TAG_MAP,
       CrystalClick::BinaryDataType::TAG_NESTED,
       CrystalClick::BinaryDataType::TAG_NULLABLE,
       CrystalClick::BinaryDataType::TAG_LOW_CARDINALITY,
       CrystalClick::BinaryDataType::TAG_VARIANT,
       CrystalClick::BinaryDataType::TAG_DYNAMIC,
       CrystalClick::BinaryDataType::TAG_SIMPLE_AGGREGATE
    true
  else
    false
  end
end

describe "W195 Object shared advanced chunk composition" do
  it "pairs Copy rows with full-cardinality per-path Dynamic lanes across bucket ordinals" do
    paths = w195_paths_per_bucket(2)
    bucket_zero_path = paths.find do |path|
      CrystalClick::ObjectSharedBucketLayout.bucket_for(path, 2) == 0
    end.not_nil!
    bucket_one_path = paths.find do |path|
      CrystalClick::ObjectSharedBucketLayout.bucket_for(path, 2) == 1
    end.not_nil!
    rows = [
      w195_row([
        {bucket_zero_path, CrystalClick::BinaryValue.string("zero-0")},
        {bucket_one_path, CrystalClick::BinaryValue.string("one-0")},
      ] of Tuple(String, CrystalClick::BinaryValue)),
      w195_row([
        {bucket_one_path, CrystalClick::BinaryValue.string("one-1")},
      ] of Tuple(String, CrystalClick::BinaryValue)),
    ] of CrystalClick::ObjectSharedMapRow

    budget = CrystalClick::BinaryCodecBudget.new(w195_limits, true)
    encoded = CrystalClick::ObjectSharedAdvancedChunkCodec.encode(rows, 2, budget)

    encoded.row_count.should eq(2_u64)
    encoded.bucket_count.should eq(2)
    encoded.buckets.each_with_index do |bucket, ordinal|
      bucket.row_count.should eq(2_u64)
      bucket.path_count.should eq(1)
      path = bucket.path_at(0)
      CrystalClick::ObjectSharedBucketLayout.bucket_for(path.name, 2).should eq(ordinal)
      decoded_path = CrystalClick::ObjectSharedPathCodec.decode(
        path.streams.data,
        path.streams.events,
        2,
        CrystalClick::BinaryDataType.dynamic(max_types: 0),
        w195_limits,
      )
      decoded_path.size.should eq(2)
      if path.name == bucket_zero_path
        decoded_path[0].is_null?.should be_false
        decoded_path[0].child_at(0).as_string.should eq("zero-0")
        decoded_path[1].is_null?.should be_true
      else
        decoded_path[0].child_at(0).as_string.should eq("one-0")
        decoded_path[1].child_at(0).as_string.should eq("one-1")
      end
    end

    read_budget = CrystalClick::BinaryCodecBudget.new(w195_limits)
    decoded_rows = CrystalClick::ObjectSharedAdvancedChunkCodec.decode(encoded.buckets, encoded.copy_streams, read_budget)
    w195_assert_rows(decoded_rows, rows)
    budget.node_count.should be > 0
    read_budget.node_count.should be > 0
  end

  it "keeps positive all-empty rows and zero-row chunks distinct" do
    empty_row = CrystalClick::ObjectSharedMapRow.new([] of CrystalClick::ObjectSharedMapEntry)
    positive = CrystalClick::ObjectSharedAdvancedChunkCodec.encode(
      [empty_row, empty_row] of CrystalClick::ObjectSharedMapRow,
      2,
      CrystalClick::BinaryCodecBudget.new(w195_limits, true),
    )
    positive.row_count.should eq(2_u64)
    positive.buckets.each do |bucket|
      bucket.row_count.should eq(2_u64)
      bucket.path_count.should eq(0)
    end
    w195_assert_rows(
      CrystalClick::ObjectSharedAdvancedChunkCodec.decode(
        positive.buckets,
        positive.copy_streams,
        CrystalClick::BinaryCodecBudget.new(w195_limits),
      ),
      [empty_row, empty_row] of CrystalClick::ObjectSharedMapRow,
    )

    zero = CrystalClick::ObjectSharedAdvancedChunkCodec.encode(
      [] of CrystalClick::ObjectSharedMapRow,
      2,
      CrystalClick::BinaryCodecBudget.new(w195_limits, true),
    )
    zero.row_count.should eq(0_u64)
    zero.copy_streams.sizes.should be_empty
    zero.buckets.each do |bucket|
      bucket.row_count.should eq(0_u64)
      bucket.path_count.should eq(0)
    end
    CrystalClick::ObjectSharedAdvancedChunkCodec.decode(
      zero.buckets,
      zero.copy_streams,
      CrystalClick::BinaryCodecBudget.new(w195_limits),
    ).should be_empty
  end

  it "joins recursive nullable-array values, an empty array, and an absent path exactly" do
    path = "w195-recursive-path"
    int64 = CrystalClick::BinaryDataType.primitive("Int64")
    nullable_int64 = CrystalClick::BinaryDataType.nullable(int64)
    array_type = CrystalClick::BinaryDataType.array(nullable_int64)
    present = CrystalClick::BinaryValue.array(array_type, [
      CrystalClick::BinaryValue.nullable(nullable_int64, CrystalClick::BinaryValue.int64(7_i64)),
      CrystalClick::BinaryValue.nullable(nullable_int64),
    ] of CrystalClick::BinaryValue)
    empty = CrystalClick::BinaryValue.array(array_type, [] of CrystalClick::BinaryValue)
    rows = [
      w195_row([{path, present}] of Tuple(String, CrystalClick::BinaryValue)),
      CrystalClick::ObjectSharedMapRow.new([] of CrystalClick::ObjectSharedMapEntry),
      w195_row([{path, empty}] of Tuple(String, CrystalClick::BinaryValue)),
    ] of CrystalClick::ObjectSharedMapRow

    encoded = CrystalClick::ObjectSharedAdvancedChunkCodec.encode(
      rows,
      1,
      CrystalClick::BinaryCodecBudget.new(w195_limits, true),
    )
    bucket_path = encoded.bucket_at(0).path_at(0)
    decoded_path = CrystalClick::ObjectSharedPathCodec.decode(
      bucket_path.streams.data,
      bucket_path.streams.events,
      rows.size,
      CrystalClick::BinaryDataType.dynamic(max_types: 0),
    )
    decoded_path[0].is_null?.should be_false
    decoded_path[0].child_at(0).type.should eq(array_type)
    decoded_path[0].child_at(0).child_at(0).child_at(0).as_int64.should eq(7_i64)
    decoded_path[0].child_at(0).child_at(1).is_null?.should be_true
    decoded_path[1].is_null?.should be_true
    decoded_path[2].child_at(0).type.should eq(array_type)
    decoded_path[2].child_at(0).elements.should be_empty

    decoded = CrystalClick::ObjectSharedAdvancedChunkCodec.decode(
      encoded.buckets,
      encoded.copy_streams,
      CrystalClick::BinaryCodecBudget.new(w195_limits),
    )
    w195_assert_rows(decoded, rows)
  end

  it "keeps one caller wire budget cumulative across exact chunk calls" do
    path = "w195-budget-path"
    rows = [
      w195_row([{path, CrystalClick::BinaryValue.string("same-wire")}] of Tuple(String, CrystalClick::BinaryValue)),
    ] of CrystalClick::ObjectSharedMapRow
    probe_budget = CrystalClick::BinaryCodecBudget.new(w195_limits, true)
    CrystalClick::ObjectSharedAdvancedChunkCodec.encode(rows, 1, probe_budget)
    chunk_wire = probe_budget.wire_byte_count
    chunk_wire.should be > 0

    exact_limits = w195_limits(max_bytes: chunk_wire.to_i)
    shared_budget = CrystalClick::BinaryCodecBudget.new(exact_limits, true)
    CrystalClick::ObjectSharedAdvancedChunkCodec.encode(rows, 1, shared_budget)
    shared_budget.wire_byte_count.should eq(chunk_wire)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectSharedAdvancedChunkCodec.encode(rows, 1, shared_budget)
    end
    shared_budget.wire_byte_count.should eq(chunk_wire)

    # The second exact chunk is valid with an isolated budget of the same size;
    # only resetting the caller budget would allow the pair above to succeed.
    isolated = CrystalClick::BinaryCodecBudget.new(exact_limits, true)
    CrystalClick::ObjectSharedAdvancedChunkCodec.encode(rows, 1, isolated)
    isolated.wire_byte_count.should eq(chunk_wire)
  end
end
