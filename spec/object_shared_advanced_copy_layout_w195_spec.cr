require "./spec_helper"

private def w195_copy_path(bucket : Int32) : String
  candidate = 0
  loop do
    path = "w195-copy-layout-#{candidate}"
    return path if CrystalClick::ObjectSharedBucketLayout.bucket_for(path, 2) == bucket
    candidate += 1
  end
end

private def w195_copy_row(pairs : Array(Tuple(String, CrystalClick::BinaryValue))) : CrystalClick::ObjectSharedMapRow
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

private def w195_copy_layout_wire_bytes(
  chunks_by_parent : Array(Array(CrystalClick::ObjectSharedAdvancedChunk)),
) : UInt64
  total = 0_u64
  chunks_by_parent.each do |chunks|
    chunks.each do |chunk|
      streams = chunk.copy_streams
      total += streams.sizes_size.to_u64
      total += streams.indexes_size.to_u64
      total += streams.values_size.to_u64
    end
  end
  total
end

private def w195_copy_layout_inputs(
  files : Hash(String, CrystalClick::CompressedMarkFiles),
  &
) : Nil
  paths = [] of String
  inputs = Hash(String, CrystalClick::ObjectSharedPhysicalLaneInput).new
  begin
    files.each do |name, lane|
      data = lane.data
      marks = lane.marks
      data_path = File.tempname("crystal-click-w195-copy-#{name}-data")
      marks_path = File.tempname("crystal-click-w195-copy-#{name}-marks")
      paths << data_path
      paths << marks_path
      File.open(data_path, "wb") { |io| io.write(data) }
      File.open(marks_path, "wb") { |io| io.write(marks) }
      inputs[name] = CrystalClick::ObjectSharedPhysicalLaneInput.new(
        data_path, marks_path, data.size.to_i64, marks.size.to_i64
      )
    end
    yield inputs
  ensure
    paths.each { |path| File.delete(path) if File.exists?(path) }
  end
end

describe "W195 Object shared advanced Copy layout" do
  it "joins chunk-local Copy streams onto the physical parent mark grid and splits them exactly" do
    path_zero = w195_copy_path(0)
    path_one = w195_copy_path(1)
    first_rows = [
      w195_copy_row([
        {path_zero, CrystalClick::BinaryValue.string("zero-a")},
        {path_one, CrystalClick::BinaryValue.string("one-a")},
      ] of Tuple(String, CrystalClick::BinaryValue)),
      w195_copy_row([{path_one, CrystalClick::BinaryValue.string("one-b")}] of Tuple(String, CrystalClick::BinaryValue)),
    ] of CrystalClick::ObjectSharedMapRow
    zero_rows = [] of CrystalClick::ObjectSharedMapRow
    second_parent_rows = [
      w195_copy_row([{path_zero, CrystalClick::BinaryValue.string("zero-c")}] of Tuple(String, CrystalClick::BinaryValue)),
    ] of CrystalClick::ObjectSharedMapRow

    chunks_by_parent = [
      [
        CrystalClick::ObjectSharedAdvancedChunkCodec.encode(
          first_rows,
          2,
          CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
        ),
        CrystalClick::ObjectSharedAdvancedChunkCodec.encode(
          zero_rows,
          2,
          CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
        ),
      ] of CrystalClick::ObjectSharedAdvancedChunk,
      [
        CrystalClick::ObjectSharedAdvancedChunkCodec.encode(
          second_parent_rows,
          2,
          CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
        ),
      ] of CrystalClick::ObjectSharedAdvancedChunk,
    ] of Array(CrystalClick::ObjectSharedAdvancedChunk)
    # Physical parents can carry array-child cardinality that differs from
    # the Copy row schedule; this layer preserves both coordinate systems.
    physical_rows = [2_u64, 2_u64]

    codec_write_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true)
    transport_write_budget = CrystalClick::CompressedStreamBudget.write_default
    files = CrystalClick::ObjectSharedAdvancedCopyLayout.encode(
      chunks_by_parent,
      physical_rows,
      codec_write_budget,
      transport_write_budget,
      7,
    )
    files.keys.sort.should eq(["indexes", "sizes", "values"])
    transport_write_budget.file_byte_count.should be > 0

    bucket_parents = Array(Array(CrystalClick::ObjectSharedPhysicalParentMark)).new(2) do |bucket_index|
      chunks_by_parent.map_with_index do |chunks, parent_index|
        bucket_chunks = chunks.map { |chunk| chunk.bucket_at(bucket_index) }
        CrystalClick::ObjectSharedPhysicalParentMark.new(physical_rows[parent_index], bucket_chunks)
      end
    end

    w195_copy_layout_inputs(files) do |inputs|
      decoded = CrystalClick::ObjectSharedAdvancedCopyLayout.decode(
        inputs,
        bucket_parents,
        physical_rows,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
        CrystalClick::CompressedStreamBudget.read_default,
      )
      decoded.size.should eq(chunks_by_parent.size)
      decoded.each_with_index do |parent_chunks, parent_index|
        parent_chunks.size.should eq(chunks_by_parent[parent_index].size)
        parent_chunks.each_with_index do |copy_streams, chunk_index|
          original = chunks_by_parent[parent_index][chunk_index].copy_streams
          copy_streams.sizes.should eq(original.sizes)
          copy_streams.indexes.should eq(original.indexes)
          copy_streams.values.should eq(original.values)
        end
      end
    end
  end

  it "rejects a physical mark grid with a different parent count" do
    empty_row = CrystalClick::ObjectSharedMapRow.new([] of CrystalClick::ObjectSharedMapEntry)
    chunk = CrystalClick::ObjectSharedAdvancedChunkCodec.encode(
      [empty_row] of CrystalClick::ObjectSharedMapRow,
      1,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
    )
    expect_raises(ArgumentError) do
      CrystalClick::ObjectSharedAdvancedCopyLayout.encode(
        [[chunk]] of Array(CrystalClick::ObjectSharedAdvancedChunk),
        [1_u64, 1_u64],
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
        CrystalClick::CompressedStreamBudget.write_default,
      )
    end
  end

  it "preflights lane bytes and keeps one codec budget across repeated layouts" do
    path = "w195-copy-layout-budget"
    row = w195_copy_row([{path, CrystalClick::BinaryValue.string("budgeted")}] of Tuple(String, CrystalClick::BinaryValue))
    chunk = CrystalClick::ObjectSharedAdvancedChunkCodec.encode(
      [row] of CrystalClick::ObjectSharedMapRow,
      1,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
    )
    chunks = [[chunk]] of Array(CrystalClick::ObjectSharedAdvancedChunk)
    physical_rows = [1_u64]
    wire_bytes = w195_copy_layout_wire_bytes(chunks)
    wire_bytes.should be > 0_u64

    too_small = CrystalClick::BinaryCodecBudget.new(
      CrystalClick::BinaryCodecLimits.new(
        max_depth: 64,
        max_nodes: 4096,
        max_elements: 1_000_000,
        max_bytes: wire_bytes.to_i - 1,
      ),
      true,
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectSharedAdvancedCopyLayout.encode(
        chunks,
        physical_rows,
        too_small,
        CrystalClick::CompressedStreamBudget.write_default,
      )
    end
    too_small.wire_byte_count.should eq(0_i64)

    exact = CrystalClick::BinaryCodecBudget.new(
      CrystalClick::BinaryCodecLimits.new(
        max_depth: 64,
        max_nodes: 4096,
        max_elements: 1_000_000,
        max_bytes: wire_bytes.to_i,
      ),
      true,
    )
    CrystalClick::ObjectSharedAdvancedCopyLayout.encode(
      chunks,
      physical_rows,
      exact,
      CrystalClick::CompressedStreamBudget.write_default,
    )
    exact.wire_byte_count.should eq(wire_bytes.to_i64)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectSharedAdvancedCopyLayout.encode(
        chunks,
        physical_rows,
        exact,
        CrystalClick::CompressedStreamBudget.write_default,
      )
    end
    exact.wire_byte_count.should eq(wire_bytes.to_i64)
  end
end
