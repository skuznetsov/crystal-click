require "./spec_helper"

private module CompactCompressedIndexWriterW301
  extend self

  PARENT_KEYS = Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64, 8_u64, 9_u64, 10_u64, 11_u64, 12_u64]
  GROUP_KEYS  = Slice[10_u64, 20_u64, 30_u64, 40_u64, 50_u64, 60_u64]
  SUB_KEYS    = Slice[1_u64, 2_u64, 1_u64, 2_u64, 1_u64, 2_u64]
  COUNTS      = Slice[2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 2_u64]

  def count_projection(
    name : String,
    compress_primary_key : Bool = false,
    compress_marks : Bool = false,
  ) : CrystalClick::CompactPartProjection
    CrystalClick::CompactPartProjection.precomputed_count(
      name,
      "score",
      GROUP_KEYS,
      COUNTS,
      rows_per_mark: 2,
      frame_bytes: 9,
      compress_marks: compress_marks,
      compress_primary_key: compress_primary_key,
    )
  end

  def paired_count_projection(
    name : String,
    compress_primary_key : Bool = false,
    compress_marks : Bool = false,
  ) : CrystalClick::CompactPartProjection
    CrystalClick::CompactPartProjection.precomputed_count(
      name,
      {"score", "sub"},
      {GROUP_KEYS, SUB_KEYS},
      COUNTS,
      rows_per_mark: 2,
      frame_bytes: 9,
      compress_marks: compress_marks,
      compress_primary_key: compress_primary_key,
    )
  end

  def columns : Array(CrystalClick::CompactPartColumn)
    values = PARENT_KEYS.map { |value| CrystalClick::BinaryValue.uint64(value) }
    [CrystalClick::CompactPartColumn.binary_bulk(
      "value",
      CrystalClick::BinaryDataType.primitive("UInt64"),
      values.each.each_slice(2).to_a,
    )] of CrystalClick::CompactPartColumn
  end

  def budgets(read_limits : CrystalClick::CompressedStreamLimits = CrystalClick::CompressedStreamLimits.new) : CrystalClick::ProjectionWriterBudgets
    limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
    CrystalClick::ProjectionWriterBudgets.new(
      CrystalClick::BinaryCodecBudget.new(limits, true),
      CrystalClick::CompressedStreamBudget.write_default,
      CrystalClick::BinaryCodecBudget.new(limits, false),
      CrystalClick::CompressedStreamBudget.new(read_limits),
    )
  end

  def write_parent(path : String, projections : Array(CrystalClick::CompactPartProjection), budgets : CrystalClick::ProjectionWriterBudgets) : String
    CrystalClick::CompactPartOperation.write_uint64_columns(
      path,
      "id",
      PARENT_KEYS,
      columns,
      2,
      9,
      CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
      budgets.write_transport.limits,
      budgets.read_transport.limits,
      CrystalClick::CompactMarkFormat::Mrk4,
      CrystalClick::CompactVariantDiscriminatorMode::Compact,
      projections: projections,
      projection_budgets: budgets,
    )
  end

  def count_binding : CrystalClick::PartSchemaBinding
    CrystalClick::PartSchemaBinding.new(
      "score",
      [
        {"score", "UInt64"},
        {"sub", "UInt64"},
        {"count()", "AggregateFunction(count)"},
      ] of Tuple(String, String),
      "projection",
    )
  end
end

describe "W301 Compact aggregate compressed primary-index writer" do
  it "preserves the opt-in through schema binding and writes a multi-frame cidx while defaults remain raw" do
    root = File.tempname("crystal-click-w301-index-writer-")
    Dir.mkdir(root)
    begin
      raw = CompactCompressedIndexWriterW301.count_projection("by_raw")
      raw.compress_primary_key.should be_false
      compressed = CompactCompressedIndexWriterW301.paired_count_projection("by_compressed", true, true)
      compressed.compress_primary_key.should be_true
      bound = compressed.with_schema_binding(CompactCompressedIndexWriterW301.count_binding)
      bound.compress_primary_key.should be_true
      compressed_uncompressed_marks = CompactCompressedIndexWriterW301.paired_count_projection(
        "by_compressed_raw_marks", true, false
      )

      CompactCompressedIndexWriterW301.write_parent(
        File.join(root, "all_1_1_0"),
        [raw, bound, compressed_uncompressed_marks] of CrystalClick::CompactPartProjection,
        CompactCompressedIndexWriterW301.budgets,
      )

      raw_child = File.join(root, "all_1_1_0", "by_raw.proj")
      File.file?(File.join(raw_child, "primary.idx")).should be_true
      File.exists?(File.join(raw_child, "primary.cidx")).should be_false
      File.file?(File.join(raw_child, "data.mrk4")).should be_true
      File.exists?(File.join(raw_child, "data.cmrk4")).should be_false

      compressed_child = File.join(root, "all_1_1_0", "by_compressed.proj")
      File.file?(File.join(compressed_child, "primary.cidx")).should be_true
      File.exists?(File.join(compressed_child, "primary.idx")).should be_false
      File.file?(File.join(compressed_child, "data.cmrk4")).should be_true
      File.exists?(File.join(compressed_child, "data.mrk4")).should be_false
      Dir.children(compressed_child).should contain("primary.cidx")
      checksums = CrystalClick::PartChecksums.open(compressed_child)
      entry = checksums.entry("primary.cidx").not_nil!
      entry.compressed.should be_true
      entry.uncompressed_size.should eq(64_u64)

      raw_index = Bytes.new(64)
      [10_u64, 1_u64, 30_u64, 1_u64, 50_u64, 1_u64, 60_u64, 2_u64].each_with_index do |key, index|
        IO::ByteFormat::LittleEndian.encode(key, raw_index[index * 8, 8])
      end
      entry.uncompressed_hash.should eq(CrystalClick::CityHashV1.file_hash(raw_index))
      physical_index = File.read(File.join(compressed_child, "primary.cidx")).to_slice
      frame_index = CrystalClick::CompressedFrameIndex.new(
        physical_index,
        CrystalClick::CompressedStreamLimits.new,
        CrystalClick::CompressedStreamBudget.read_default,
      )
      frame_index.frames.size.should be > 1
      decoded = CrystalClick::ProjectionPrimaryIndex.read_compressed(
        compressed_child,
        raw_index.size.to_i64,
        checksums,
        CrystalClick::CompressedStreamBudget.read_default,
      )
      decoded.should eq(raw_index)

      compressed_raw_marks_child = File.join(root, "all_1_1_0", "by_compressed_raw_marks.proj")
      File.file?(File.join(compressed_raw_marks_child, "primary.cidx")).should be_true
      File.exists?(File.join(compressed_raw_marks_child, "primary.idx")).should be_false
      File.file?(File.join(compressed_raw_marks_child, "data.mrk4")).should be_true
      File.exists?(File.join(compressed_raw_marks_child, "data.cmrk4")).should be_false
    ensure
      FileUtils.rm_rf(root) if Dir.exists?(root)
    end
  end

  it "removes the parent stage when sibling cidx children exhaust the shared read budget" do
    control_root = File.tempname("crystal-click-w301-index-budget-control-")
    failure_root = File.tempname("crystal-click-w301-index-budget-failure-")
    Dir.mkdir(control_root)
    Dir.mkdir(failure_root)
    begin
      control_budgets = CompactCompressedIndexWriterW301.budgets
      CompactCompressedIndexWriterW301.write_parent(
        File.join(control_root, "all_1_1_0"),
        [
          CompactCompressedIndexWriterW301.count_projection("by_first", true),
          CompactCompressedIndexWriterW301.count_projection("by_second"),
        ] of CrystalClick::CompactPartProjection,
        control_budgets,
      )
      one_child_decoded_bytes = control_budgets.read_transport.decoded_byte_count
      one_child_decoded_bytes.should be > 0_i64

      read_limits = CrystalClick::CompressedStreamLimits.new(
        max_decoded_bytes: one_child_decoded_bytes,
      )
      failure_budgets = CompactCompressedIndexWriterW301.budgets(read_limits)
      expect_raises(CrystalClick::CorruptPartError, /decoded-byte limit exceeded/) do
        CompactCompressedIndexWriterW301.write_parent(
          File.join(failure_root, "all_1_1_0"),
          [
            CompactCompressedIndexWriterW301.count_projection("by_first", true),
            CompactCompressedIndexWriterW301.count_projection("by_second", true),
          ] of CrystalClick::CompactPartProjection,
          failure_budgets,
        )
      end

      File.exists?(File.join(failure_root, "all_1_1_0")).should be_false
      Dir.children(failure_root).should be_empty
    ensure
      FileUtils.rm_rf(control_root) if Dir.exists?(control_root)
      FileUtils.rm_rf(failure_root) if Dir.exists?(failure_root)
    end
  end

  it "exposes the opt-in on every Compact aggregate projection constructor" do
    sum = CrystalClick::WidePartProjectionAggregate.sum_uint64("value", Slice[1_u64])
    one_key = CrystalClick::CompactPartProjection.precomputed_aggregate(
      "by_one", "k", Slice[10_u64], [sum] of CrystalClick::WidePartProjectionAggregate,
      compress_primary_key: true,
    )
    one_key.compress_primary_key.should be_true

    two_key = CrystalClick::CompactPartProjection.precomputed_aggregate(
      "by_two",
      {"k", "sub"},
      {Slice[10_u64], Slice[20_u64]},
      [sum] of CrystalClick::WidePartProjectionAggregate,
      compress_primary_key: true,
    )
    two_key.compress_primary_key.should be_true

    multi_key = CrystalClick::CompactPartProjection.precomputed_aggregate(
      "by_many",
      ["k", "sub", "third"],
      [Slice[10_u64], Slice[20_u64], Slice[30_u64]],
      [sum] of CrystalClick::WidePartProjectionAggregate,
      compress_primary_key: true,
    )
    multi_key.compress_primary_key.should be_true

    pair_count = CrystalClick::CompactPartProjection.precomputed_count(
      "by_pair_count",
      {"k", "sub"},
      {Slice[10_u64], Slice[20_u64]},
      Slice[1_u64],
      compress_primary_key: true,
    )
    pair_count.compress_primary_key.should be_true
  end
end
