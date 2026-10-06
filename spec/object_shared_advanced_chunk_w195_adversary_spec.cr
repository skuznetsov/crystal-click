require "./spec_helper"

private def w195a_limits(
  max_depth : Int = 64,
  max_nodes : Int = 100_000,
  max_elements : Int = 1_000_000,
  max_bytes : Int = 64 * 1024 * 1024,
) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(max_depth, max_nodes, max_elements, max_bytes)
end

private def w195a_same_bucket_paths : Array(String)
  grouped = Array(String).new
  bucket : Int32? = nil
  candidate = 0
  while grouped.size < 2
    path = "w195-same-#{candidate}"
    path_bucket = CrystalClick::ObjectSharedBucketLayout.bucket_for(path, 2)
    if bucket.nil?
      bucket = path_bucket
      grouped << path
    elsif path_bucket == bucket
      grouped << path
    end
    candidate += 1
  end
  grouped
end

private def w195a_row(paths : Array(String), values : Array(String)) : CrystalClick::ObjectSharedMapRow
  entries = Array(CrystalClick::ObjectSharedMapEntry).new(paths.size)
  paths.each_with_index do |path, index|
    entries << CrystalClick::ObjectSharedMapEntry.new(path.to_slice, CrystalClick::BinaryValue.string(values[index]))
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

describe "W195 Object shared advanced chunk adversaries" do
  it "rejects equal-shape path Data swapped while Copy still names the original paths" do
    paths = w195a_same_bucket_paths
    rows = [
      w195a_row(paths, ["aaaa", "bbbb"] of String),
      w195a_row(paths, ["cccc", "dddd"] of String),
    ] of CrystalClick::ObjectSharedMapRow
    encoded = CrystalClick::ObjectSharedAdvancedChunkCodec.encode(
      rows,
      2,
      CrystalClick::BinaryCodecBudget.new(w195a_limits, true),
    )

    target_bucket = CrystalClick::ObjectSharedBucketLayout.bucket_for(paths[0], 2)
    original = encoded.bucket_at(target_bucket)
    original.path_count.should eq(2)
    first = original.path_at(0)
    second = original.path_at(1)
    first.streams.data.size.should eq(second.streams.data.size)
    first.streams.events.map(&.relative_offset).should eq(second.streams.events.map(&.relative_offset))

    swapped = [
      CrystalClick::ObjectSharedPhysicalPath.new(first.name, second.streams),
      CrystalClick::ObjectSharedPhysicalPath.new(second.name, first.streams),
    ] of CrystalClick::ObjectSharedPhysicalPath
    swapped.sort! { |left, right| CrystalClick::ObjectSharedPhysicalPath.compare_names(left.name, right.name) }
    mutated_bucket = CrystalClick::ObjectSharedPhysicalChunk.new(original.row_count, swapped)
    bucket_chunks = encoded.buckets
    bucket_chunks[target_bucket] = mutated_bucket

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedAdvancedChunkCodec.decode(
        bucket_chunks,
        encoded.copy_streams,
        CrystalClick::BinaryCodecBudget.new(w195a_limits),
      )
    end
  end

  it "rejects a top-level NULL map value because native Object extraction omits it" do
    rows = [CrystalClick::ObjectSharedMapRow.new([
      CrystalClick::ObjectSharedMapEntry.new("null-path".to_slice, CrystalClick::BinaryValue.null),
    ] of CrystalClick::ObjectSharedMapEntry)] of CrystalClick::ObjectSharedMapRow

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectSharedAdvancedChunkCodec.encode(
        rows,
        1,
        CrystalClick::BinaryCodecBudget.new(w195a_limits, true),
      )
    end
  end

  it "rejects bucket chunks with mismatched logical row counts before pairing lanes" do
    empty_path_chunks = [
      CrystalClick::ObjectSharedPhysicalChunk.new(2_u64, [] of CrystalClick::ObjectSharedPhysicalPath),
      CrystalClick::ObjectSharedPhysicalChunk.new(1_u64, [] of CrystalClick::ObjectSharedPhysicalPath),
    ] of CrystalClick::ObjectSharedPhysicalChunk
    # Sizes describe the first bucket's two rows; the bucket structure join
    # must reject the second bucket's contradictory logical chunk extent.
    copy = CrystalClick::ObjectSharedCopyCodec.encode(
      [
        CrystalClick::ObjectSharedMapRow.new([] of CrystalClick::ObjectSharedMapEntry),
        CrystalClick::ObjectSharedMapRow.new([] of CrystalClick::ObjectSharedMapEntry),
      ] of CrystalClick::ObjectSharedMapRow,
      [
        CrystalClick::ObjectSharedChunkStructure.new(2_u64, [] of String, {0_u64, 0_u64}, {0_u64, 0_u64}, {0_u64, 0_u64}),
        CrystalClick::ObjectSharedChunkStructure.new(2_u64, [] of String, {0_u64, 0_u64}, {0_u64, 0_u64}, {0_u64, 0_u64}),
      ] of CrystalClick::ObjectSharedChunkStructure,
    )

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedAdvancedChunkCodec.decode(
        empty_path_chunks,
        copy,
        CrystalClick::BinaryCodecBudget.new(w195a_limits),
      )
    end
  end

  it "preflights Copy and path snapshots before charging or copying them" do
    row = w195a_row(["w195-preflight-path"] of String, ["payload"] of String)
    encoded = CrystalClick::ObjectSharedAdvancedChunkCodec.encode(
      [row] of CrystalClick::ObjectSharedMapRow,
      1,
      CrystalClick::BinaryCodecBudget.new(w195a_limits, true),
    )
    copy_bytes = encoded.copy_streams.sizes_size.to_u64 +
                 encoded.copy_streams.indexes_size.to_u64 +
                 encoded.copy_streams.values_size.to_u64
    path_bytes = 0_u64
    encoded.buckets.each do |bucket|
      bucket.path_count.times do |index|
        path_bytes += bucket.path_at(index).streams.data_size.to_u64
      end
    end
    total_input_bytes = copy_bytes + path_bytes
    total_input_bytes.should be > 0_u64

    tight = CrystalClick::BinaryCodecLimits.new(
      64,
      100_000,
      1_000_000,
      total_input_bytes.to_i - 1,
    )
    budget = CrystalClick::BinaryCodecBudget.new(tight)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedAdvancedChunkCodec.decode(encoded.buckets, encoded.copy_streams, budget)
    end
    # The enclosing owner's non-consumptive snapshot preflight rejects before
    # a detached lane getter or either child codec can charge the shared budget.
    budget.wire_byte_count.should eq(0)
  end

  it "rejects a valid equal-shape recursive Data lane with a changed scalar payload" do
    path = "w195-recursive-mutation"
    int64 = CrystalClick::BinaryDataType.primitive("Int64")
    nullable = CrystalClick::BinaryDataType.nullable(int64)
    array = CrystalClick::BinaryDataType.array(nullable)
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    original_array = CrystalClick::BinaryValue.array(array, [
      CrystalClick::BinaryValue.nullable(nullable, CrystalClick::BinaryValue.int64(7_i64)),
      CrystalClick::BinaryValue.nullable(nullable),
    ] of CrystalClick::BinaryValue)
    empty_array = CrystalClick::BinaryValue.array(array, [] of CrystalClick::BinaryValue)
    rows = [
      CrystalClick::ObjectSharedMapRow.new([
        CrystalClick::ObjectSharedMapEntry.new(path.to_slice, original_array),
      ] of CrystalClick::ObjectSharedMapEntry),
      CrystalClick::ObjectSharedMapRow.new([] of CrystalClick::ObjectSharedMapEntry),
      CrystalClick::ObjectSharedMapRow.new([
        CrystalClick::ObjectSharedMapEntry.new(path.to_slice, empty_array),
      ] of CrystalClick::ObjectSharedMapEntry),
    ] of CrystalClick::ObjectSharedMapRow
    encoded = CrystalClick::ObjectSharedAdvancedChunkCodec.encode(
      rows,
      1,
      CrystalClick::BinaryCodecBudget.new(w195a_limits, true),
    )
    original_path = encoded.bucket_at(0).path_at(0)

    changed_array = CrystalClick::BinaryValue.array(array, [
      CrystalClick::BinaryValue.nullable(nullable, CrystalClick::BinaryValue.int64(8_i64)),
      CrystalClick::BinaryValue.nullable(nullable),
    ] of CrystalClick::BinaryValue)
    changed_rows = [
      CrystalClick::BinaryValue.dynamic(dynamic, changed_array),
      CrystalClick::BinaryValue.dynamic(dynamic),
      CrystalClick::BinaryValue.dynamic(dynamic, empty_array),
    ] of CrystalClick::BinaryValue
    changed_streams = CrystalClick::ObjectSharedPathCodec.encode(
      dynamic,
      {"root" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)},
      changed_rows,
    )
    changed_streams.data.size.should eq(original_path.streams.data_size)
    changed_events = changed_streams.events.map { |event| {event.name, event.relative_offset} }
    original_events = original_path.streams.events.map { |event| {event.name, event.relative_offset} }
    changed_events.should eq(original_events)

    changed_path = CrystalClick::ObjectSharedPhysicalPath.new(original_path.name, changed_streams)
    changed_bucket = CrystalClick::ObjectSharedPhysicalChunk.new(3_u64, [changed_path] of CrystalClick::ObjectSharedPhysicalPath)
    buckets = encoded.buckets
    buckets[0] = changed_bucket
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedAdvancedChunkCodec.decode(
        buckets,
        encoded.copy_streams,
        CrystalClick::BinaryCodecBudget.new(w195a_limits),
      )
    end
  end
end
