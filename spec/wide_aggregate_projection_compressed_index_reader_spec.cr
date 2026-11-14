require "./spec_helper"
require "./support/offline_materialized_view_compact_transform_w286_fixture"
require "./support/projection_checksum_fixture"

private module WideAggregateCompressedIndexW300Fixture
  extend self

  alias Aggregate = CrystalClick::WidePartProjectionAggregate
  alias ChecksumRecord = CrystalClick::PartWriterInfrastructure::ChecksumRecord
  alias ChecksumsWriter = CrystalClick::PartWriterInfrastructure::PartChecksumsWriter

  NAME      = "by_bucket"
  KEY_NAME  = "bucket"
  KEYS      = Slice[10_u64, 20_u64, 30_u64, 40_u64, 50_u64, 60_u64]
  IDS       = Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64]
  UINT64    = CrystalClick::BinaryDataType.primitive("UInt64")
  STRING    = CrystalClick::BinaryDataType.primitive("String")
  SUM_TYPE  = CrystalClick::BinaryDataType.aggregate_sum("UInt64")
  SUM_STATE = "sum(value)"

  def catalog(& : CrystalClick::OfflineCatalog, String -> Nil)
    root = File.tempname("crystal-click-w300-reader")
    _, metadata, target = CompactMaterializedViewTransformW286Fixture.catalog(root, target_value_declaration: "UInt64")
    target_path = File.join(metadata, "target.sql")
    target_sql = File.read(target_path).sub(
      "`label` String\n)",
      "`label` String, `bucket` UInt64, PROJECTION #{NAME} (SELECT bucket, sum(value) GROUP BY bucket)\n)"
    )
    File.write(target_path, target_sql)

    view_path = File.join(metadata, "view.sql")
    view_sql = File.read(view_path)
      .sub("`label` String", "`label` String, `bucket` UInt64")
      .sub("AS SELECT k, v, v FROM lab.source WHERE k > 1", "AS SELECT k, k, v FROM lab.source WHERE k > 1")
    File.write(view_path, view_sql)
    yield CrystalClick::OfflineCatalog.open(root), target
  ensure
    FileUtils.rm_rf(root) if root
  end

  def projection(compress_primary_key : Bool = true) : CrystalClick::WidePartProjection
    CrystalClick::WidePartProjection.precomputed_aggregate(
      NAME,
      KEY_NAME,
      KEYS,
      [Aggregate.sum_uint64("value", Slice[100_u64, 200_u64, 300_u64, 400_u64, 500_u64, 600_u64])],
      rows_per_mark: 2,
      compress_primary_key: compress_primary_key,
    )
  end

  def transform(catalog : CrystalClick::OfflineCatalog, child : CrystalClick::WidePartProjection, compact_parent : Bool) : String
    if compact_parent
      catalog.transform_materialized_view_part(
        "lab", "view", "all_1_1_0", ["k"], "all_8_8_0", rows_per_mark: 2,
        mark_format: CrystalClick::CompactMarkFormat::Mrk4,
      ) do |input|
        columns = output(input).map { |name, type, values| CrystalClick::CompactPartColumn.binary_bulk(name, type, values) }
        CrystalClick::CompactPartTransformOutput.new(IDS, columns, projections: [child])
      end
    else
      catalog.transform_materialized_view_part("lab", "view", "all_1_1_0", ["k"], "all_8_8_0", rows_per_mark: 2) do |input|
        columns = output(input).map { |name, type, values| CrystalClick::WidePartColumn.binary_bulk(name, type, values) }
        CrystalClick::WidePartTransformOutput.new(IDS, columns, projections: [child])
      end
    end
  end

  def attach(catalog : CrystalClick::OfflineCatalog, target : String, parent : String) : CrystalClick::OfflineTable
    File.rename(parent, File.join(target, File.basename(parent)))
    CrystalClick::OfflineCatalog.open(catalog.root)["lab"]["target"]
  end

  def rehash_file!(directory : String, file : String, compressed : Bool = false) : Nil
    data = File.read(File.join(directory, file)).to_slice
    records = CrystalClick::PartChecksums.open(directory).entries.map do |name, entry|
      if name == file
        ChecksumRecord.new(name, data.size.to_u64, CrystalClick::CityHashV1.file_hash(data), compressed,
          entry.uncompressed_size, entry.uncompressed_hash)
      else
        ChecksumRecord.new(name, entry.physical_size, entry.file_hash, entry.compressed, entry.uncompressed_size, entry.uncompressed_hash)
      end
    end
    ChecksumsWriter.write(directory, records)
  end

  def rewrite_index!(parent : String, &mutation : Bytes -> Nil) : Nil
    child = File.join(parent, "#{NAME}.proj")
    checksums = CrystalClick::PartChecksums.open(child)
    entry = checksums.entry("primary.cidx") || raise "missing primary.cidx fixture entry"
    physical = File.read(File.join(child, "primary.cidx")).to_slice
    raw = CrystalClick::CompressedBlock.decode_all(
      physical,
      CrystalClick::CompressedStreamLimits::DEFAULT_MAX_FRAME_COMPRESSED_BYTES,
      CrystalClick::CompressedStreamLimits::DEFAULT_MAX_FRAME_DECOMPRESSED_BYTES,
      CrystalClick::PrimaryKeyIndex::MAX_INDEX_FILE_BYTES,
    )
    mutation.call(raw)
    replacement = CrystalClick::CompressedMarkWriter.encode_all(raw, 4096, CrystalClick::CompressedStreamBudget.write_default)
    File.write(File.join(child, "primary.cidx"), replacement)
    records = checksums.entries.map do |name, current|
      if name == "primary.cidx"
        ChecksumRecord.new(name, replacement.size.to_u64, CrystalClick::CityHashV1.file_hash(replacement), true,
          raw.size.to_u64, CrystalClick::CityHashV1.file_hash(raw))
      else
        ChecksumRecord.new(name, current.physical_size, current.file_hash, current.compressed, current.uncompressed_size, current.uncompressed_hash)
      end
    end
    ChecksumsWriter.write(child, records)
    ProjectionChecksumFixture.rebind!(parent, NAME)
  end

  def rewrite_index_metadata!(parent : String, &mutation : CrystalClick::PartChecksums::Entry -> ChecksumRecord)
    child = File.join(parent, "#{NAME}.proj")
    records = CrystalClick::PartChecksums.open(child).entries.map do |name, entry|
      name == "primary.cidx" ? yield(entry) : ChecksumRecord.new(name, entry.physical_size, entry.file_hash, entry.compressed, entry.uncompressed_size, entry.uncompressed_hash)
    end
    ChecksumsWriter.write(child, records)
    ProjectionChecksumFixture.rebind!(parent, NAME)
  end

  def rewrite_index_file_hash!(parent : String) : Nil
    child = File.join(parent, "#{NAME}.proj")
    records = CrystalClick::PartChecksums.open(child).entries.map do |name, entry|
      if name == "primary.cidx"
        ChecksumRecord.new(name, entry.physical_size, {entry.file_hash[0] ^ 1_u64, entry.file_hash[1]}, entry.compressed, entry.uncompressed_size, entry.uncompressed_hash)
      else
        ChecksumRecord.new(name, entry.physical_size, entry.file_hash, entry.compressed, entry.uncompressed_size, entry.uncompressed_hash)
      end
    end
    ChecksumsWriter.write(child, records)
    ProjectionChecksumFixture.rebind!(parent, NAME)
  end

  private def output(input : CrystalClick::OfflinePartTransformInput)
    source = [] of UInt64
    input.each_batch { |batch| source.concat(batch.values_for("k")) }
    source.should eq([1_u64, 2_u64, 3_u64, 4_u64])
    values = [UInt64::MAX, 2_u64, 0_u64, 3_u64, 4_u64, 5_u64, 6_u64]
    labels = Array(CrystalClick::BinaryValue).new(IDS.size) { CrystalClick::BinaryValue.string("row") }
    buckets = ([KEYS[0]] + KEYS.to_a).map { |key| CrystalClick::BinaryValue.uint64(key) }
    columns = [
      {"value", UINT64, values.map { |value| CrystalClick::BinaryValue.uint64(value) }},
      {"label", STRING, labels},
      {KEY_NAME, UINT64, buckets},
    ]
    columns.map { |name, type, column_values| {name, type, column_values.each_slice(2).to_a} }
  end
end

private alias W300Reader = WideAggregateCompressedIndexW300Fixture

describe "W300 Wide aggregate compressed primary-index reader" do
  it "authenticates state-only and key-only EOF scans under Wide and Compact parents" do
    [false, true].each do |compact_parent|
      W300Reader.catalog do |catalog, target|
        parent = W300Reader.transform(catalog, W300Reader.projection, compact_parent)
        child_path = File.join(parent, "#{W300Reader::NAME}.proj")
        File.exists?(File.join(child_path, "primary.cidx")).should be_true
        File.exists?(File.join(child_path, "primary.idx")).should be_false
        table = W300Reader.attach(catalog, target, parent)

        [W300Reader::SUM_STATE, W300Reader::KEY_NAME].each do |column|
          yielded = false
          table.scan_projection_typed_window(W300Reader::NAME, [column], W300Reader::KEYS.size.to_u64, 1) do |_batch|
            yielded = true
          end
          yielded.should be_false
        end
      end
    end
  end

  it "rejects rehashed wrong later and terminal tuples before state-only or key-only EOF callbacks" do
    [1, 3].each do |tuple_index|
      [W300Reader::SUM_STATE, W300Reader::KEY_NAME].each do |column|
        W300Reader.catalog do |catalog, target|
          parent = W300Reader.transform(catalog, W300Reader.projection, false)
          W300Reader.rewrite_index!(parent) do |raw|
            offset = tuple_index * sizeof(UInt64)
            value = IO::ByteFormat::LittleEndian.decode(UInt64, raw[offset, sizeof(UInt64)])
            IO::ByteFormat::LittleEndian.encode(value ^ 1_u64, raw[offset, sizeof(UInt64)])
          end
          table = W300Reader.attach(catalog, target, parent)
          callback_reached = false
          expect_raises(CrystalClick::CorruptPartError, /ordered key marks/) do
            table.scan_projection_typed_window(W300Reader::NAME, [column], W300Reader::KEYS.size.to_u64, 1) do |_batch|
              callback_reached = true
            end
          end
          callback_reached.should be_false
        end
      end
    end
  end

  it "rejects an aligned in-range interior plain mark position after checksum rebinding" do
    W300Reader.catalog do |catalog, target|
      parent = W300Reader.transform(catalog, W300Reader.projection, false)
      child = File.join(parent, "#{W300Reader::NAME}.proj")
      key_reader = CrystalClick::WidePart.open_projection_child_typed(child, W300Reader::KEY_NAME, W300Reader::NAME)
      marks_name = File.basename(key_reader.mark_path)
      mutate_fixture_file(child, marks_name) do |marks|
        offset = CrystalClick::WidePart::MARK_SIZE + sizeof(UInt64)
        position = IO::ByteFormat::LittleEndian.decode(UInt64, marks[offset, sizeof(UInt64)])
        IO::ByteFormat::LittleEndian.encode(position + sizeof(UInt64), marks[offset, sizeof(UInt64)])
      end
      W300Reader.rehash_file!(child, marks_name)
      ProjectionChecksumFixture.rebind!(parent, W300Reader::NAME)
      table = W300Reader.attach(catalog, target, parent)

      expect_raises(CrystalClick::CorruptPartError, /fixed-width projection lane span/) do
        table.scan_projection_typed_window(W300Reader::NAME, [W300Reader::SUM_STATE], W300Reader::KEYS.size.to_u64, 1) do
          fail "yielded a key lane whose interior mark offset was rehashed"
        end
      end
    end
  end

  it "rejects malformed transport metadata, bad hashes, a missing file, and a dual raw index before EOF callbacks" do
    [:size, :physical_hash, :raw_hash, :missing_file, :dual_file].each do |failure|
      W300Reader.catalog do |catalog, target|
        parent = W300Reader.transform(catalog, W300Reader.projection, false)
        child = File.join(parent, "#{W300Reader::NAME}.proj")
        case failure
        when :size
          W300Reader.rewrite_index_metadata!(parent) do |entry|
            W300Reader::ChecksumRecord.new("primary.cidx", entry.physical_size, entry.file_hash, true, UInt64::MAX, entry.uncompressed_hash)
          end
        when :physical_hash
          W300Reader.rewrite_index_file_hash!(parent)
        when :raw_hash
          W300Reader.rewrite_index_metadata!(parent) do |entry|
            W300Reader::ChecksumRecord.new("primary.cidx", entry.physical_size, entry.file_hash, true, entry.uncompressed_size, {entry.uncompressed_hash.not_nil![0] ^ 1_u64, entry.uncompressed_hash.not_nil![1]})
          end
        when :missing_file
          File.delete(File.join(child, "primary.cidx"))
          ProjectionChecksumFixture.rebind!(parent, W300Reader::NAME)
        when :dual_file
          record = CrystalClick::PartWriterInfrastructure::PrimaryIndexWriter.write_compound(child, [W300Reader::KEYS], 2)
          checksums = CrystalClick::PartChecksums.open(child)
          records = checksums.entries.map do |name, entry|
            W300Reader::ChecksumRecord.new(name, entry.physical_size, entry.file_hash, entry.compressed, entry.uncompressed_size, entry.uncompressed_hash)
          end
          records << record
          W300Reader::ChecksumsWriter.write(child, records)
          ProjectionChecksumFixture.rebind!(parent, W300Reader::NAME)
        end
        table = W300Reader.attach(catalog, target, parent)
        callback_reached = false
        expect_raises(CrystalClick::CorruptPartError) do
          table.scan_projection_typed_window(W300Reader::NAME, [W300Reader::SUM_STATE], W300Reader::KEYS.size.to_u64, 1) do
            callback_reached = true
          end
        end
        callback_reached.should be_false
      end
    end
  end

  it "keeps the W299 raw aggregate projection route available" do
    W300Reader.catalog do |catalog, target|
      parent = W300Reader.transform(catalog, W300Reader.projection(false), false)
      table = W300Reader.attach(catalog, target, parent)
      values = [] of UInt64
      table.scan_projection_typed(W300Reader::NAME, [W300Reader::KEY_NAME]) do |batch|
        values.concat(batch.values_for(W300Reader::KEY_NAME))
      end
      values.should eq(W300Reader::KEYS.to_a)
    end
  end
end
