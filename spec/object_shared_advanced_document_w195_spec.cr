require "./spec_helper"

private def w195d_schema(
  limits : CrystalClick::BinaryCodecLimits = CrystalClick::ObjectDocumentSchema::DEFAULT_LIMITS,
) : CrystalClick::ObjectDocumentSchema
  CrystalClick::ObjectDocumentSchema.new(
    {"t" => CrystalClick::BinaryDataType.primitive("UInt8")},
    max_dynamic_paths: 0,
    max_dynamic_types: 0,
    limits: limits,
  )
end

private def w195d_plan(
  schema : CrystalClick::ObjectDocumentSchema,
  shared_version : UInt64,
) : CrystalClick::ObjectDocumentPlan
  object = CrystalClick::ObjectStructure.new(
    [] of String,
    shared_data_version: shared_version,
    bucket_count: 2_u64,
  )
  CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      object,
      {} of String => CrystalClick::DynamicStructure,
    ),
    schema.typed_paths,
  )
end

private def w195d_paths_per_bucket : Array(String)
  grouped = Array(Array(String)).new(2) { [] of String }
  candidate = 0
  while grouped.any? { |paths| paths.empty? }
    path = "w195-document-path-#{candidate}"
    bucket = CrystalClick::ObjectSharedBucketLayout.bucket_for(path, 2)
    grouped[bucket] << path if grouped[bucket].empty?
    candidate += 1
  end
  grouped.flatten
end

private def w195d_many_paths(total : Int, bucket_count : Int32) : Array(String)
  grouped = Array(Array(String)).new(bucket_count) { [] of String }
  candidate = 0
  count = 0
  while count < total
    path = "w195-document-wide-path-#{candidate}"
    bucket = CrystalClick::ObjectSharedBucketLayout.bucket_for(path, bucket_count)
    grouped[bucket] << path
    candidate += 1
    count += 1
  end
  grouped.flatten
end

private def w195d_row_for_paths(paths : Array(String)) : CrystalClick::ObjectSharedMapRow
  ordered = paths.sort!
  entries = ordered.map do |path|
    CrystalClick::ObjectSharedMapEntry.new(path.to_slice, CrystalClick::BinaryValue.string("wide-value"))
  end
  CrystalClick::ObjectSharedMapRow.new(entries)
end

private def w195d_row_for_pairs(
  pairs : Array(Tuple(String, String)),
) : CrystalClick::ObjectSharedMapRow
  ordered = pairs.sort_by(&.[0])
  entries = ordered.map do |pair|
    CrystalClick::ObjectSharedMapEntry.new(pair[0].to_slice, CrystalClick::BinaryValue.string(pair[1]))
  end
  CrystalClick::ObjectSharedMapRow.new(entries)
end

private def w195d_document(
  typed : UInt8,
  shared : Array(Tuple(String, String)),
) : CrystalClick::ObjectDocument
  fields = Hash(String, CrystalClick::BinaryValue).new
  fields["t"] = CrystalClick::BinaryValue.fixed(
    CrystalClick::BinaryDataType.primitive("UInt8"),
    Bytes[typed],
  )
  shared.each do |entry|
    fields[entry[0]] = CrystalClick::BinaryValue.string(entry[1])
  end
  CrystalClick::ObjectDocument.new(fields)
end

private def with_w195d_part_parent(label : String, & : String ->)
  parent = File.tempname("crystal-click-w195-document-#{label}-")
  Dir.mkdir(parent)
  yield parent
ensure
  FileUtils.rm_rf(parent) if parent && Dir.exists?(parent)
end

private def w195d_lane_input(
  root : String,
  name : String,
  files : CrystalClick::CompressedMarkFiles,
) : CrystalClick::ObjectSharedPhysicalLaneInput
  data_path = File.join(root, "#{name}.bin")
  marks_path = File.join(root, "#{name}.mrk2")
  data = files.data
  marks = files.marks
  File.write(data_path, data)
  File.write(marks_path, marks)
  CrystalClick::ObjectSharedPhysicalLaneInput.new(
    data_path,
    marks_path,
    data.size.to_i64,
    marks.size.to_i64,
  )
end

private def w195d_copy_inputs(
  root : String,
  files : CrystalClick::ObjectSharedAdvancedDocumentFiles,
) : Hash(String, CrystalClick::ObjectSharedPhysicalLaneInput)
  inputs = Hash(String, CrystalClick::ObjectSharedPhysicalLaneInput).new
  CrystalClick::ObjectSharedAdvancedDocumentCodec::COPY_LANES.each do |lane|
    inputs[lane] = w195d_lane_input(root, "copy-#{lane}", files.copy_lane(lane))
  end
  inputs
end

private def w195d_copy_lane_inputs(
  root : String,
  files : Hash(String, CrystalClick::CompressedMarkFiles),
) : Hash(String, CrystalClick::ObjectSharedPhysicalLaneInput)
  inputs = Hash(String, CrystalClick::ObjectSharedPhysicalLaneInput).new
  CrystalClick::ObjectSharedAdvancedDocumentCodec::COPY_LANES.each do |lane|
    input_files = files[lane]? || raise("missing W195 Copy lane #{lane}")
    inputs[lane] = w195d_lane_input(root, "copy-#{lane}", input_files)
  end
  inputs
end

private def w195d_bucket_inputs(
  root : String,
  ordinal : Int32,
  files : CrystalClick::ObjectSharedPhysicalBucketFiles,
) : CrystalClick::ObjectSharedPhysicalBucketLaneInputs
  inputs = Hash(String, CrystalClick::ObjectSharedPhysicalLaneInput).new
  CrystalClick::ObjectSharedPhysicalBucketLaneInputs::LANE_NAMES.each do |lane|
    inputs[lane] = w195d_lane_input(root, "bucket-#{ordinal}-#{lane}", files.lane(lane))
  end
  CrystalClick::ObjectSharedPhysicalBucketLaneInputs.new(inputs)
end

describe "W195 persisted Object ADVANCED/CHUNKED documents" do
  it "round-trips root ADVANCED and CHUNKED values through the paired Wide writer and reader" do
    schema = w195d_schema
    paths = w195d_paths_per_bucket
    path_bucket_zero = paths.find do |path|
      CrystalClick::ObjectSharedBucketLayout.bucket_for(path, 2) == 0
    end.not_nil!
    path_bucket_one = paths.find do |path|
      CrystalClick::ObjectSharedBucketLayout.bucket_for(path, 2) == 1
    end.not_nil!
    granules = [
      [
        w195d_document(1_u8, [
          {path_bucket_zero, "zero-first"},
          {path_bucket_one, "one-first"},
        ] of Tuple(String, String)),
        w195d_document(2_u8, [{path_bucket_zero, "zero-second"}] of Tuple(String, String)),
      ] of CrystalClick::ObjectDocument,
      [
        w195d_document(3_u8, [{path_bucket_one, "one-third"}] of Tuple(String, String)),
        w195d_document(4_u8, [] of Tuple(String, String)),
      ] of CrystalClick::ObjectDocument,
    ] of Array(CrystalClick::ObjectDocument)

    {2_u64, 3_u64}.each do |shared_version|
      with_w195d_part_parent(shared_version.to_s) do |parent|
        part = File.join(parent, "all_1_1_0")
        plan = w195d_plan(schema, shared_version)
        CrystalClick::WidePartWriter.write_uint64_object_pair(
          part,
          "pk",
          Slice[10_u64, 20_u64, 30_u64, 40_u64],
          "payload",
          schema,
          plan,
          granules,
          rows_per_mark: 2,
        ).should eq(part)

        reader = CrystalClick::ObjectColumnReader.open(part, "payload", schema)
        reader.row_count.should eq(4_u64)
        reader.mark_row_counts.should eq([2_u64, 2_u64])
        selected = reader.read_marks(1, 1)
        selected.size.should eq(1)
        selected[0].size.should eq(2)
        selected[0][0].value_for("t").bytes.should eq(Bytes[3_u8])
        selected[0][0].value_for(path_bucket_one).as_string.should eq("one-third")
        selected[0][1].value_for("t").bytes.should eq(Bytes[4_u8])
        selected[0][1].has_path?(path_bucket_zero).should be_false
        selected[0][1].has_path?(path_bucket_one).should be_false
      end
    end
  end

  it "keeps zero-child physical marks distinct from populated recursive CHUNKED child rows" do
    object_schema = w195d_schema
    object_plan = w195d_plan(object_schema, 3_u64)
    schema = CrystalClick::StorageColumnSchema.parse("Array(#{object_schema.declaration})")
    plans = {"root/array[0]" => object_plan}
    child_path = w195d_paths_per_bucket[0]
    empty = CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue)
    populated = CrystalClick::StorageColumnValue.array([
      CrystalClick::StorageColumnValue.object_document(
        w195d_document(9_u8, [{child_path, "recursive-child"}] of Tuple(String, String)),
      ),
    ] of CrystalClick::StorageColumnValue)
    granules = [
      [empty] of CrystalClick::StorageColumnValue,
      [populated] of CrystalClick::StorageColumnValue,
    ] of Array(CrystalClick::StorageColumnValue)

    with_w195d_part_parent("recursive") do |parent|
      part = File.join(parent, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_recursive_pair(
        part,
        "pk",
        Slice[100_u64, 200_u64],
        "payload",
        schema,
        plans,
        granules,
        rows_per_mark: 1,
        mode: CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
      ).should eq(part)

      reader = CrystalClick::RecursiveStorageColumnReader.open(part, "payload", schema)
      reader.mark_row_counts.should eq([1_u64, 1_u64])
      selected = reader.read_marks(0, 2)
      selected.size.should eq(2)
      selected[0].size.should eq(1)
      selected[0][0].array?.should be_true
      selected[0][0].child_count.should eq(0)
      selected[1][0].array?.should be_true
      selected[1][0].child_count.should eq(1)
      child = selected[1][0].child_at(0).object_document
      child.value_for("t").bytes.should eq(Bytes[9_u8])
      child.value_for(child_path).as_string.should eq("recursive-child")
    end
  end

  it "uses the whole chunk dictionary width when more than 256 paths span two buckets" do
    wide_limits = CrystalClick::BinaryCodecLimits.new(
      max_depth: 64,
      max_nodes: 100_000,
      max_elements: 1_000_000,
      max_bytes: 64 * 1024 * 1024,
    )
    schema = w195d_schema(wide_limits)
    paths = w195d_many_paths(257, 2)
    paths.map { |path| CrystalClick::ObjectSharedBucketLayout.bucket_for(path, 2) }.uniq.sort.should eq([0, 1])
    row = w195d_row_for_paths(paths)
    chunk = CrystalClick::ObjectSharedAdvancedChunkCodec.encode(
      [row] of CrystalClick::ObjectSharedMapRow,
      2,
      CrystalClick::BinaryCodecBudget.new(wide_limits, true),
    )
    chunk.copy_streams.indexes_size.should eq(257 * 2)

    pairs = Array(Tuple(String, String)).new(paths.size)
    paths.each_with_index { |path, index| pairs << {path, "wide-value-#{index}"} }
    document = w195d_document(7_u8, pairs)
    with_w195d_part_parent("wide-dictionary") do |parent|
      part = File.join(parent, "all_1_1_0")
      plan = w195d_plan(schema, 2_u64)
      CrystalClick::WidePartWriter.write_uint64_object_pair(
        part,
        "pk",
        Slice[70_u64],
        "payload",
        schema,
        plan,
        [[document] of CrystalClick::ObjectDocument] of Array(CrystalClick::ObjectDocument),
        rows_per_mark: 1,
        limits: wide_limits,
      ).should eq(part)

      reader = CrystalClick::ObjectColumnReader.open(part, "payload", schema)
      decoded = reader.read_marks(0, 1)
      decoded[0].size.should eq(1)
      decoded[0][0].value_for("t").bytes.should eq(Bytes[7_u8])
      paths.each_with_index do |path, index|
        decoded[0][0].value_for(path).as_string.should eq("wide-value-#{index}")
      end
    end
  end

  it "rejects different per-bucket chunk schedules even when total logical rows match" do
    paths = w195d_paths_per_bucket
    path_zero = paths.find { |path| CrystalClick::ObjectSharedBucketLayout.bucket_for(path, 2) == 0 }.not_nil!
    path_one = paths.find { |path| CrystalClick::ObjectSharedBucketLayout.bucket_for(path, 2) == 1 }.not_nil!
    rows = [
      w195d_row_for_pairs([
        {path_zero, "zero"}, {path_one, "one"},
      ] of Tuple(String, String)),
      w195d_row_for_pairs([
        {path_zero, "zero-later"},
      ] of Tuple(String, String)),
    ] of CrystalClick::ObjectSharedMapRow
    canonical = CrystalClick::ObjectSharedAdvancedDocumentCodec.encode(
      [rows] of Array(CrystalClick::ObjectSharedMapRow),
      [2_u64],
      3,
      2,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
      CrystalClick::CompressedStreamBudget.write_default,
    )
    alternate_chunk = CrystalClick::ObjectSharedAdvancedChunkCodec.encode(
      rows,
      2,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
    )
    alternate_parent = CrystalClick::ObjectSharedPhysicalParentMark.new(
      2_u64,
      [alternate_chunk.bucket_at(1)] of CrystalClick::ObjectSharedPhysicalChunk,
    )
    alternate_bucket = CrystalClick::ObjectSharedPhysicalBucketCodec.encode(
      3,
      [alternate_parent] of CrystalClick::ObjectSharedPhysicalParentMark,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
      CrystalClick::CompressedStreamBudget.write_default,
    )

    with_w195d_part_parent("schedule-mismatch") do |parent|
      copy_inputs = w195d_copy_inputs(parent, canonical)
      bucket_inputs = [
        w195d_bucket_inputs(parent, 0, canonical.bucket_at(0)),
        w195d_bucket_inputs(parent, 1, alternate_bucket),
      ] of CrystalClick::ObjectSharedPhysicalBucketLaneInputs
      valid_zero = CrystalClick::ObjectSharedPhysicalBucketCodec.decode(
        3,
        bucket_inputs[0],
        [2_u64],
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
        CrystalClick::CompressedStreamBudget.read_default,
      )
      valid_one = CrystalClick::ObjectSharedPhysicalBucketCodec.decode(
        3,
        bucket_inputs[1],
        [2_u64],
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
        CrystalClick::CompressedStreamBudget.read_default,
      )
      valid_zero[0].chunks.map(&.row_count).should eq([1_u64, 1_u64])
      valid_one[0].chunks.map(&.row_count).should eq([2_u64])
      expect_raises(CrystalClick::CorruptPartError, /chunk schedules disagree/) do
        CrystalClick::ObjectSharedAdvancedDocumentCodec.decode(
          copy_inputs,
          bucket_inputs,
          [2_u64],
          [2_u64],
          3,
          2,
          CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
          CrystalClick::CompressedStreamBudget.read_default,
        )
      end
    end
  end

  it "rejects equal-count same-total bucket schedules with different per-chunk rows" do
    paths = w195d_paths_per_bucket
    path_zero = paths.find { |path| CrystalClick::ObjectSharedBucketLayout.bucket_for(path, 2) == 0 }.not_nil!
    path_one = paths.find { |path| CrystalClick::ObjectSharedBucketLayout.bucket_for(path, 2) == 1 }.not_nil!
    rows = [
      w195d_row_for_pairs([{path_zero, "zero-a"}, {path_one, "one-a"}] of Tuple(String, String)),
      w195d_row_for_pairs([{path_zero, "zero-b"}] of Tuple(String, String)),
      w195d_row_for_pairs([{path_one, "one-c"}] of Tuple(String, String)),
    ] of CrystalClick::ObjectSharedMapRow
    write_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true)
    chunk_one = CrystalClick::ObjectSharedAdvancedChunkCodec.encode([rows[0]], 2, write_budget)
    chunk_two = CrystalClick::ObjectSharedAdvancedChunkCodec.encode([rows[1], rows[2]], 2, write_budget)
    canonical_chunks = [[chunk_one, chunk_two]] of Array(CrystalClick::ObjectSharedAdvancedChunk)
    copy_files = CrystalClick::ObjectSharedAdvancedCopyLayout.encode(
      canonical_chunks,
      [3_u64],
      write_budget,
      CrystalClick::CompressedStreamBudget.write_default,
    )
    canonical_bucket_zero = CrystalClick::ObjectSharedPhysicalBucketCodec.encode(
      3,
      [CrystalClick::ObjectSharedPhysicalParentMark.new(3_u64, [
        chunk_one.bucket_at(0), chunk_two.bucket_at(0),
      ] of CrystalClick::ObjectSharedPhysicalChunk)] of CrystalClick::ObjectSharedPhysicalParentMark,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
      CrystalClick::CompressedStreamBudget.write_default,
    )

    reversed_first = CrystalClick::ObjectSharedAdvancedChunkCodec.encode([rows[0], rows[1]], 2,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true))
    reversed_second = CrystalClick::ObjectSharedAdvancedChunkCodec.encode([rows[2]], 2,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true))
    alternate_bucket_one = CrystalClick::ObjectSharedPhysicalBucketCodec.encode(
      3,
      [CrystalClick::ObjectSharedPhysicalParentMark.new(3_u64, [
        reversed_first.bucket_at(1), reversed_second.bucket_at(1),
      ] of CrystalClick::ObjectSharedPhysicalChunk)] of CrystalClick::ObjectSharedPhysicalParentMark,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
      CrystalClick::CompressedStreamBudget.write_default,
    )

    with_w195d_part_parent("schedule-row-vector") do |parent|
      copy_inputs = w195d_copy_lane_inputs(parent, copy_files)
      bucket_inputs = [
        w195d_bucket_inputs(parent, 0, canonical_bucket_zero),
        w195d_bucket_inputs(parent, 1, alternate_bucket_one),
      ] of CrystalClick::ObjectSharedPhysicalBucketLaneInputs
      canonical_decoded = CrystalClick::ObjectSharedPhysicalBucketCodec.decode(
        3,
        bucket_inputs[0],
        [3_u64],
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
        CrystalClick::CompressedStreamBudget.read_default,
      )
      alternate_decoded = CrystalClick::ObjectSharedPhysicalBucketCodec.decode(
        3,
        bucket_inputs[1],
        [3_u64],
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
        CrystalClick::CompressedStreamBudget.read_default,
      )
      canonical_decoded[0].chunks.map(&.row_count).should eq([1_u64, 2_u64])
      alternate_decoded[0].chunks.map(&.row_count).should eq([2_u64, 1_u64])
      expect_raises(CrystalClick::CorruptPartError, /chunk row schedules disagree/) do
        CrystalClick::ObjectSharedAdvancedDocumentCodec.decode(
          copy_inputs,
          bucket_inputs,
          [3_u64],
          [3_u64],
          3,
          2,
          CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
          CrystalClick::CompressedStreamBudget.read_default,
        )
      end
    end
  end

  it "charges coordinator nodes cumulatively before materializing decoded parent rows" do
    empty_row = CrystalClick::ObjectSharedMapRow.new([] of CrystalClick::ObjectSharedMapEntry)
    write_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true)
    files = CrystalClick::ObjectSharedAdvancedDocumentCodec.encode(
      [[empty_row]] of Array(CrystalClick::ObjectSharedMapRow),
      [1_u64],
      2,
      2,
      write_budget,
      CrystalClick::CompressedStreamBudget.write_default,
    )

    with_w195d_part_parent("decode-node-accounting") do |parent|
      copy_inputs = w195d_copy_inputs(parent, files)
      bucket_inputs = [
        w195d_bucket_inputs(parent, 0, files.bucket_at(0)),
        w195d_bucket_inputs(parent, 1, files.bucket_at(1)),
      ] of CrystalClick::ObjectSharedPhysicalBucketLaneInputs

      physical_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
      bucket_parents = [] of Array(CrystalClick::ObjectSharedPhysicalParentMark)
      bucket_inputs.each do |inputs|
        bucket_parents << CrystalClick::ObjectSharedPhysicalBucketCodec.decode(
          2,
          inputs,
          [1_u64],
          physical_budget,
          CrystalClick::CompressedStreamBudget.read_default,
        )
      end

      copy_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
      copy_by_parent = CrystalClick::ObjectSharedAdvancedCopyLayout.decode(
        copy_inputs,
        bucket_parents,
        [1_u64],
        copy_budget,
        CrystalClick::CompressedStreamBudget.read_default,
      )

      physical_chunks = bucket_parents.map { |parents| parents[0].chunk_at(0) }
      chunk_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
      CrystalClick::ObjectSharedAdvancedChunkCodec.decode(
        physical_chunks,
        copy_by_parent[0][0],
        chunk_budget,
      ).size.should eq(1)

      component_nodes = physical_budget.node_count + copy_budget.node_count + chunk_budget.node_count
      shared_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
      read_transport = CrystalClick::CompressedStreamBudget.read_default
      decode = -> do
        CrystalClick::ObjectSharedAdvancedDocumentCodec.decode(
          copy_inputs,
          bucket_inputs,
          [1_u64],
          [1_u64],
          2,
          2,
          shared_budget,
          read_transport,
        )
      end

      decode.call.size.should eq(1)
      first_total = shared_budget.node_count
      first_total.should be >= component_nodes + 2_i64

      decode.call.size.should eq(1)
      (shared_budget.node_count - first_total).should be >= component_nodes + 2_i64
    end
  end
end
