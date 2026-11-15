require "./spec_helper"
require "./support/projection_checksum_fixture"

private module CompactAggregateCompressedIndexW301Fixture
  extend self

  alias Aggregate = CrystalClick::WidePartProjectionAggregate
  alias ChecksumRecord = CrystalClick::PartWriterInfrastructure::ChecksumRecord
  alias ChecksumsWriter = CrystalClick::PartWriterInfrastructure::PartChecksumsWriter
  alias Projection = CrystalClick::WidePartProjection | CrystalClick::CompactPartProjection

  NAME       = "by_pair"
  KEY_NAMES  = {"tenant", "bucket"}
  KEY_ONE    = Slice[1_u64, 1_u64, 2_u64, 2_u64]
  KEY_TWO    = Slice[10_u64, 20_u64, 30_u64, 40_u64]
  DUP_ONE    = Slice[1_u64, 1_u64, 2_u64]
  DUP_TWO    = Slice[10_u64, 20_u64, 30_u64]
  SUM_VALUES = Slice[100_u64, 200_u64, 300_u64, 400_u64]
  PARENT_IDS = Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64, 8_u64]
  UINT64     = CrystalClick::BinaryDataType.primitive("UInt64")
  SUM_STATE  = "sum(value)"

  def projection(
    compress_marks : Bool = false,
    duplicate_last_start_and_terminal : Bool = false,
  ) : CrystalClick::CompactPartProjection
    first = duplicate_last_start_and_terminal ? DUP_ONE : KEY_ONE
    second = duplicate_last_start_and_terminal ? DUP_TWO : KEY_TWO
    values = duplicate_last_start_and_terminal ? SUM_VALUES[0, 3] : SUM_VALUES
    CrystalClick::CompactPartProjection.precomputed_aggregate(
      NAME,
      KEY_NAMES,
      {first, second},
      [Aggregate.sum_uint64("value", values)] of Aggregate,
      rows_per_mark: 2,
      frame_bytes: 9,
      compress_marks: compress_marks,
    )
  end

  def write_parent(
    root : String,
    compact_parent : Bool,
    child : CrystalClick::CompactPartProjection,
  ) : String
    parent = File.join(root, "all_1_1_0")
    if compact_parent
      columns = [parent_column_compact] of CrystalClick::CompactPartColumn
      CrystalClick::CompactPartOperation.write_uint64_columns(
        parent,
        "id",
        PARENT_IDS,
        columns,
        2,
        9,
        CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
        CrystalClick::CompressedStreamLimits.new,
        CrystalClick::CompressedStreamLimits.new,
        CrystalClick::CompactMarkFormat::Mrk4,
        CrystalClick::CompactVariantDiscriminatorMode::Compact,
        projections: [child] of Projection,
      )
    else
      CrystalClick::WidePartWriter.write_uint64_columns(
        parent,
        "id",
        PARENT_IDS,
        [parent_column_wide] of CrystalClick::WidePartColumn,
        rows_per_mark: 2,
        frame_bytes: 9,
        projections: [child] of Projection,
      )
    end
    parent
  end

  def convert_raw_index_to_cidx!(parent : String) : Bytes
    child = child_path(parent)
    raw_path = File.join(child, "primary.idx")
    raw = File.read(raw_path).to_slice
    physical = CrystalClick::CompressedMarkWriter.encode_all(
      raw,
      9,
      CrystalClick::CompressedStreamBudget.write_default,
    )
    File.write(File.join(child, "primary.cidx"), physical)
    File.delete(raw_path)

    checksums = CrystalClick::PartChecksums.open(child)
    records = checksums.entries.map do |name, entry|
      next if name == "primary.idx"
      ChecksumRecord.new(
        name,
        entry.physical_size,
        entry.file_hash,
        entry.compressed,
        entry.uncompressed_size,
        entry.uncompressed_hash,
      )
    end.compact
    records << ChecksumRecord.new(
      "primary.cidx",
      physical.size.to_u64,
      CrystalClick::CityHashV1.file_hash(physical),
      true,
      raw.size.to_u64,
      CrystalClick::CityHashV1.file_hash(raw),
    )
    ChecksumsWriter.write(child, records)
    ProjectionChecksumFixture.rebind!(parent, NAME)
    raw
  end

  def rewrite_index!(parent : String, &mutation : Bytes -> Nil) : Nil
    child = child_path(parent)
    checksums = CrystalClick::PartChecksums.open(child)
    checksums.entry("primary.cidx") || raise "missing primary.cidx fixture entry"
    physical = File.read(File.join(child, "primary.cidx")).to_slice
    raw = CrystalClick::CompressedBlock.decode_all(
      physical,
      CrystalClick::CompressedStreamLimits::DEFAULT_MAX_FRAME_COMPRESSED_BYTES,
      CrystalClick::CompressedStreamLimits::DEFAULT_MAX_FRAME_DECOMPRESSED_BYTES,
      CrystalClick::PrimaryKeyIndex::MAX_INDEX_FILE_BYTES,
    )
    mutation.call(raw)
    replacement = CrystalClick::CompressedMarkWriter.encode_all(
      raw,
      9,
      CrystalClick::CompressedStreamBudget.write_default,
    )
    File.write(File.join(child, "primary.cidx"), replacement)
    records = checksums.entries.map do |name, entry|
      if name == "primary.cidx"
        ChecksumRecord.new(
          name,
          replacement.size.to_u64,
          CrystalClick::CityHashV1.file_hash(replacement),
          true,
          raw.size.to_u64,
          CrystalClick::CityHashV1.file_hash(raw),
        )
      else
        ChecksumRecord.new(
          name, entry.physical_size, entry.file_hash, entry.compressed,
          entry.uncompressed_size, entry.uncompressed_hash
        )
      end
    end
    ChecksumsWriter.write(child, records)
    ProjectionChecksumFixture.rebind!(parent, NAME)
  end

  def rewrite_index_metadata!(parent : String, &mutation : CrystalClick::PartChecksums::Entry -> ChecksumRecord) : Nil
    child = child_path(parent)
    records = CrystalClick::PartChecksums.open(child).entries.map do |name, entry|
      if name == "primary.cidx"
        yield(entry)
      else
        ChecksumRecord.new(
          name, entry.physical_size, entry.file_hash, entry.compressed,
          entry.uncompressed_size, entry.uncompressed_hash
        )
      end
    end
    ChecksumsWriter.write(child, records)
    ProjectionChecksumFixture.rebind!(parent, NAME)
  end

  def rewrite_index_file_hash!(parent : String) : Nil
    rewrite_index_metadata!(parent) do |entry|
      file_hash = entry.file_hash
      ChecksumRecord.new(
        "primary.cidx",
        entry.physical_size,
        {file_hash[0] ^ 1_u64, file_hash[1]},
        true,
        entry.uncompressed_size,
        entry.uncompressed_hash,
      )
    end
  end

  def rewrite_index_raw_hash!(parent : String) : Nil
    rewrite_index_metadata!(parent) do |entry|
      raw_hash = entry.uncompressed_hash || raise "missing cidx raw hash"
      ChecksumRecord.new(
        "primary.cidx",
        entry.physical_size,
        entry.file_hash,
        true,
        entry.uncompressed_size,
        {raw_hash[0] ^ 1_u64, raw_hash[1]},
      )
    end
  end

  def rewrite_index_size!(parent : String) : Nil
    rewrite_index_metadata!(parent) do |entry|
      raw_size = entry.uncompressed_size || raise "missing cidx raw size"
      ChecksumRecord.new(
        "primary.cidx",
        entry.physical_size,
        entry.file_hash,
        true,
        raw_size + sizeof(UInt64).to_u64,
        entry.uncompressed_hash,
      )
    end
  end

  def child_path(parent : String) : String
    File.join(parent, "#{NAME}.proj")
  end

  def parent_column_compact : CrystalClick::CompactPartColumn
    values = PARENT_IDS.map { |value| CrystalClick::BinaryValue.uint64(value) }
    CrystalClick::CompactPartColumn.binary_bulk("value", UINT64, values.each.each_slice(2).to_a)
  end

  def parent_column_wide : CrystalClick::WidePartColumn
    values = PARENT_IDS.map { |value| CrystalClick::BinaryValue.uint64(value) }
    CrystalClick::WidePartColumn.binary_bulk("value", UINT64, values.each.each_slice(2).to_a)
  end
end

private alias W301CompactReader = CompactAggregateCompressedIndexW301Fixture

describe "W301 Compact aggregate compressed primary-index reader" do
  it "keeps a same-index raw control readable" do
    root = File.tempname("crystal-click-w301-compact-reader-raw-")
    Dir.mkdir(root)
    begin
      parent = W301CompactReader.write_parent(root, false, W301CompactReader.projection)
      child = W301CompactReader.child_path(parent)
      reader = CrystalClick::CompactBinaryBulkColumnReader.open_projection_aggregate(child, W301CompactReader::SUM_STATE)
      reader.projection_aggregate_key_names.should eq(["tenant", "bucket"])
      reader.read_marks(0, reader.mark_count).size.should eq(reader.mark_count)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "admits a valid cidx for direct state reads and state-only or key-only EOF windows under both parent layouts" do
    [false, true].each do |compact_parent|
      root = File.tempname("crystal-click-w301-compact-reader-cidx-")
      Dir.mkdir(root)
      begin
        projection = W301CompactReader.projection(compress_marks: compact_parent)
        parent = W301CompactReader.write_parent(root, compact_parent, projection)
        child = W301CompactReader.child_path(parent)
        raw = W301CompactReader.convert_raw_index_to_cidx!(parent)
        checksums = CrystalClick::PartChecksums.open(child)
        CrystalClick::ProjectionPrimaryIndex.read_compressed(
          child,
          raw.size.to_i64,
          checksums,
          CrystalClick::CompressedStreamBudget.read_default,
        ).should eq(raw)

        reader = CrystalClick::CompactBinaryBulkColumnReader.open_projection_aggregate(child, W301CompactReader::SUM_STATE)
        reader.projection_aggregate_key_names.should eq(["tenant", "bucket"])
        reader.read_marks(0, reader.mark_count).size.should eq(reader.mark_count)

        [W301CompactReader::SUM_STATE, "tenant"].each do |column|
          table = CrystalClick::CompactPartTable.open_selected_projection_child_typed(parent, W301CompactReader::NAME, [column])
          table.total_row_count.should eq(W301CompactReader::KEY_ONE.size.to_u64)
          window_callbacks = 0
          table.scan_typed_window(1_u64, 1) { |_batch| window_callbacks += 1 }
          window_callbacks.should eq(1)
          eof_callbacks = 0
          table.scan_typed_window(table.total_row_count, 1) { |_batch| eof_callbacks += 1 }
          eof_callbacks.should eq(0)
        end
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end

  it "accepts an explicit terminal tuple equal to the final mark-start tuple" do
    [false, true].each do |compact_parent|
      root = File.tempname("crystal-click-w301-compact-reader-duplicate-terminal-")
      Dir.mkdir(root)
      begin
        projection = W301CompactReader.projection(
          compress_marks: compact_parent,
          duplicate_last_start_and_terminal: true,
        )
        parent = W301CompactReader.write_parent(root, compact_parent, projection)
        child = W301CompactReader.child_path(parent)
        raw = W301CompactReader.convert_raw_index_to_cidx!(parent)
        tuple_bytes = 2 * sizeof(UInt64)
        raw[tuple_bytes, tuple_bytes].should eq(raw[tuple_bytes * 2, tuple_bytes])

        reader = CrystalClick::CompactBinaryBulkColumnReader.open_projection_aggregate(child, W301CompactReader::SUM_STATE)
        reader.row_count.should eq(W301CompactReader::DUP_ONE.size.to_u64)
        reader.read_marks(0, reader.mark_count).size.should eq(reader.mark_count)
        table = CrystalClick::CompactPartTable.open_selected_projection_child_typed(parent, W301CompactReader::NAME, ["tenant"])
        table.scan_typed_window(1_u64, 1) { |_batch| }
        table.scan_typed_window(table.total_row_count, 1) { |_batch| fail "duplicate terminal EOF window yielded a batch" }
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end

  it "rejects rehashed wrong interior and distinct terminal tuples before state-only or key-only EOF callbacks" do
    [
      {1, sizeof(UInt64)},
      {2, sizeof(UInt64)},
    ].each do |tuple_index, lane_offset|
      [W301CompactReader::SUM_STATE, "tenant"].each do |column|
        root = File.tempname("crystal-click-w301-compact-reader-bad-tuple-")
        Dir.mkdir(root)
        begin
          parent = W301CompactReader.write_parent(root, false, W301CompactReader.projection)
          child = W301CompactReader.child_path(parent)
          raw_before = W301CompactReader.convert_raw_index_to_cidx!(parent)
          tuple_width = 2 * sizeof(UInt64)
          (raw_before[tuple_width * 1, tuple_width] == raw_before[tuple_width * 2, tuple_width]).should be_false
          W301CompactReader.rewrite_index!(parent) do |raw|
            offset = tuple_index * tuple_width + lane_offset
            value = IO::ByteFormat::LittleEndian.decode(UInt64, raw[offset, sizeof(UInt64)])
            IO::ByteFormat::LittleEndian.encode(value ^ 1_u64, raw[offset, sizeof(UInt64)])
          end

          callbacks = 0
          expect_raises(CrystalClick::CorruptPartError, /ordered Compact key marks/) do
            table = CrystalClick::CompactPartTable.open_selected_projection_child_typed(parent, W301CompactReader::NAME, [column])
            table.scan_typed_window(table.total_row_count, 1) { |_batch| callbacks += 1 }
          end
          callbacks.should eq(0)
        ensure
          FileUtils.rm_rf(root)
        end
      end
    end
  end

  it "rejects malformed cidx metadata and an extra raw representation before EOF callbacks" do
    [:raw_size, :raw_hash, :physical_hash, :dual_raw].each do |failure|
      root = File.tempname("crystal-click-w301-compact-reader-bad-metadata-")
      Dir.mkdir(root)
      begin
        parent = W301CompactReader.write_parent(root, false, W301CompactReader.projection)
        child = W301CompactReader.child_path(parent)
        W301CompactReader.convert_raw_index_to_cidx!(parent)
        case failure
        when :raw_size
          W301CompactReader.rewrite_index_size!(parent)
        when :raw_hash
          W301CompactReader.rewrite_index_raw_hash!(parent)
        when :physical_hash
          W301CompactReader.rewrite_index_file_hash!(parent)
        when :dual_raw
          raw_record = CrystalClick::PartWriterInfrastructure::PrimaryIndexWriter.write_compound(
            child,
            [W301CompactReader::KEY_ONE, W301CompactReader::KEY_TWO] of Slice(UInt64),
            2,
          )
          checksums = CrystalClick::PartChecksums.open(child)
          records = checksums.entries.map do |name, entry|
            W301CompactReader::ChecksumRecord.new(
              name, entry.physical_size, entry.file_hash, entry.compressed,
              entry.uncompressed_size, entry.uncompressed_hash
            )
          end
          records << raw_record
          W301CompactReader::ChecksumsWriter.write(child, records)
          ProjectionChecksumFixture.rebind!(parent, W301CompactReader::NAME)
        end

        callbacks = 0
        expect_raises(CrystalClick::CorruptPartError) do
          table = CrystalClick::CompactPartTable.open_selected_projection_child_typed(parent, W301CompactReader::NAME, [W301CompactReader::SUM_STATE])
          table.scan_typed_window(table.total_row_count, 1) { |_batch| callbacks += 1 }
        end
        callbacks.should eq(0)
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end
end
