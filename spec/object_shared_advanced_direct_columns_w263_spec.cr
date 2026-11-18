require "./spec_helper"

private def w263_direct_limits : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(64, 100_000, 1_000_000, 64 * 1024 * 1024)
end

private def w263_direct_row(pairs : Array(Tuple(String, String))) : CrystalClick::ObjectSharedMapRow
  entries = pairs.map do |pair|
    CrystalClick::ObjectSharedMapEntry.new(pair[0].to_slice, CrystalClick::BinaryValue.string(pair[1]))
  end
  entries.sort! do |left, right|
    CrystalClick::ObjectSharedChunkStructure.compare_paths(
      String.build(left.path_byte_size) { |io| left.path_byte_size.times { |index| io.write_byte(left.path_byte_at(index)) } },
      String.build(right.path_byte_size) { |io| right.path_byte_size.times { |index| io.write_byte(right.path_byte_at(index)) } },
    )
  end
  CrystalClick::ObjectSharedMapRow.new(entries)
end

private def w263_direct_batch(
  buckets : Array(CrystalClick::ObjectSharedPhysicalChunk),
  row_count : Int32,
) : CrystalClick::CompactJsonColumnarBatch
  paths = [] of String
  buckets.each do |bucket|
    bucket.path_count.times { |index| paths << bucket.path_at(index).name }
  end
  batch = CrystalClick::CompactJsonColumnarBatch.from_layout(
    paths,
    [] of String,
    {} of String => CrystalClick::BinaryDataType,
    row_count,
    1_000_u64,
  )
  batch.begin_mark!(0, "part", "/part", 0, 0_u64, 0_u64, 0_u64, row_count.to_u64)
  batch
end

private def w263_direct_text(value : CrystalClick::BinaryValue) : String
  String.build(value.byte_size) do |io|
    value.byte_size.times { |index| io.write_byte(value.byte_at(index)) }
  end
end

private def w263_decode_into_columns(
  buckets : Array(CrystalClick::ObjectSharedPhysicalChunk),
  copy : CrystalClick::ObjectSharedCopyStreams,
  row_count : Int32,
) : CrystalClick::CompactJsonColumnarBatch
  batch = w263_direct_batch(buckets, row_count)
  decoded_rows = CrystalClick::ObjectSharedAdvancedChunkCodec.decode_into_columns(
    buckets,
    copy,
    CrystalClick::BinaryCodecBudget.new(w263_direct_limits),
    batch,
    0_i32,
  ) { |_path| }
  decoded_rows.should eq(row_count.to_u64)
  batch
end

describe "W263 direct SharedData Copy-to-column decode" do
  it "appends sparse Copy values directly and verifies their per-path Data rows" do
    rows = [
      w263_direct_row([{"direct-a", "a0"}, {"direct-b", "b0"}] of Tuple(String, String)),
      w263_direct_row([{"direct-a", "a1"}] of Tuple(String, String)),
      w263_direct_row([{"direct-b", "b2"}] of Tuple(String, String)),
    ] of CrystalClick::ObjectSharedMapRow
    encoded = CrystalClick::ObjectSharedAdvancedChunkCodec.encode(
      rows,
      1,
      CrystalClick::BinaryCodecBudget.new(w263_direct_limits, true),
    )

    batch = w263_decode_into_columns(encoded.buckets, encoded.copy_streams, 3)
    path_a = batch.column_for("direct-a").not_nil!
    path_b = batch.column_for("direct-b").not_nil!
    w263_direct_text(path_a.value_at(0).not_nil!).should eq("a0")
    w263_direct_text(path_a.value_at(1).not_nil!).should eq("a1")
    path_a.value_at(2).should be_nil
    w263_direct_text(path_b.value_at(0).not_nil!).should eq("b0")
    path_b.value_at(1).should be_nil
    w263_direct_text(path_b.value_at(2).not_nil!).should eq("b2")
  end

  it "rejects a repeated dictionary index in one Copy row" do
    rows = [
      w263_direct_row([{"direct-a", "a0"}, {"direct-b", "b0"}] of Tuple(String, String)),
    ] of CrystalClick::ObjectSharedMapRow
    encoded = CrystalClick::ObjectSharedAdvancedChunkCodec.encode(
      rows,
      1,
      CrystalClick::BinaryCodecBudget.new(w263_direct_limits, true),
    )
    indexes = encoded.copy_streams.indexes
    indexes[1] = indexes[0]
    copy = CrystalClick::ObjectSharedCopyStreams.new(
      encoded.copy_streams.sizes,
      indexes,
      encoded.copy_streams.values,
    )
    buckets = encoded.buckets
    batch = w263_direct_batch(buckets, 1)

    expect_raises(CrystalClick::CorruptPartError, "Object shared Copy row indexes are not in byte-path order") do
      CrystalClick::ObjectSharedAdvancedChunkCodec.decode_into_columns(
        buckets,
        copy,
        CrystalClick::BinaryCodecBudget.new(w263_direct_limits),
        batch,
        0_i32,
      ) { |_path| }
    end
  end

  it "rejects an unreferenced dictionary entry after a valid-width cross-row index change" do
    rows = [
      w263_direct_row([{"direct-a", "a0"}] of Tuple(String, String)),
      w263_direct_row([{"direct-b", "b1"}] of Tuple(String, String)),
    ] of CrystalClick::ObjectSharedMapRow
    encoded = CrystalClick::ObjectSharedAdvancedChunkCodec.encode(
      rows,
      1,
      CrystalClick::BinaryCodecBudget.new(w263_direct_limits, true),
    )
    indexes = encoded.copy_streams.indexes
    indexes[1] = indexes[0]
    copy = CrystalClick::ObjectSharedCopyStreams.new(
      encoded.copy_streams.sizes,
      indexes,
      encoded.copy_streams.values,
    )
    buckets = encoded.buckets
    batch = w263_direct_batch(buckets, 2)

    expect_raises(CrystalClick::CorruptPartError, "Object shared Copy dictionary contains an unreferenced path") do
      CrystalClick::ObjectSharedAdvancedChunkCodec.decode_into_columns(
        buckets,
        copy,
        CrystalClick::BinaryCodecBudget.new(w263_direct_limits),
        batch,
        0_i32,
      ) { |_path| }
    end
  end

  it "rejects a per-path mismatch when both Data streams remain valid" do
    rows = [
      w263_direct_row([{"direct-a", "aa"}, {"direct-b", "bb"}] of Tuple(String, String)),
      w263_direct_row([{"direct-a", "cc"}, {"direct-b", "dd"}] of Tuple(String, String)),
    ] of CrystalClick::ObjectSharedMapRow
    encoded = CrystalClick::ObjectSharedAdvancedChunkCodec.encode(
      rows,
      1,
      CrystalClick::BinaryCodecBudget.new(w263_direct_limits, true),
    )
    bucket = encoded.bucket_at(0)
    first = bucket.path_at(0)
    second = bucket.path_at(1)
    swapped = [
      CrystalClick::ObjectSharedPhysicalPath.new(first.name, second.streams),
      CrystalClick::ObjectSharedPhysicalPath.new(second.name, first.streams),
    ] of CrystalClick::ObjectSharedPhysicalPath
    mutated_buckets = [
      CrystalClick::ObjectSharedPhysicalChunk.new(bucket.row_count, swapped),
    ] of CrystalClick::ObjectSharedPhysicalChunk
    batch = w263_direct_batch(mutated_buckets, 2)

    expect_raises(CrystalClick::CorruptPartError, "Object shared Copy value disagrees with its per-path Dynamic row") do
      CrystalClick::ObjectSharedAdvancedChunkCodec.decode_into_columns(
        mutated_buckets,
        encoded.copy_streams,
        CrystalClick::BinaryCodecBudget.new(w263_direct_limits),
        batch,
        0_i32,
      ) { |_path| }
    end
  end

  it "rejects a non-NULL Data row where the Copy roster has no path entry" do
    rows = [
      w263_direct_row([{"direct-a", "a0"}] of Tuple(String, String)),
      w263_direct_row([{"direct-b", "b1"}] of Tuple(String, String)),
    ] of CrystalClick::ObjectSharedMapRow
    encoded = CrystalClick::ObjectSharedAdvancedChunkCodec.encode(
      rows,
      1,
      CrystalClick::BinaryCodecBudget.new(w263_direct_limits, true),
    )
    bucket = encoded.bucket_at(0)
    first = bucket.path_at(0)
    second = bucket.path_at(1)
    shifted = [
      CrystalClick::ObjectSharedPhysicalPath.new(first.name, first.streams),
      CrystalClick::ObjectSharedPhysicalPath.new(second.name, first.streams),
    ] of CrystalClick::ObjectSharedPhysicalPath
    mutated_buckets = [
      CrystalClick::ObjectSharedPhysicalChunk.new(bucket.row_count, shifted),
    ] of CrystalClick::ObjectSharedPhysicalChunk
    batch = w263_direct_batch(mutated_buckets, 2)

    expect_raises(CrystalClick::CorruptPartError, "absent Object shared path has a non-NULL Dynamic row") do
      CrystalClick::ObjectSharedAdvancedChunkCodec.decode_into_columns(
        mutated_buckets,
        encoded.copy_streams,
        CrystalClick::BinaryCodecBudget.new(w263_direct_limits),
        batch,
        0_i32,
      ) { |_path| }
    end
  end
end
