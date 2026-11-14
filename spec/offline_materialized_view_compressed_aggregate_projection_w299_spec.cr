require "./spec_helper"
require "./support/offline_materialized_view_compact_transform_w286_fixture"
require "./support/projection_checksum_fixture"

private module CompressedAggregateProjectionW299Fixture
  extend self

  alias Aggregate = CrystalClick::WidePartProjectionAggregate
  alias Projection = CrystalClick::WidePartProjection
  alias ChecksumRecord = CrystalClick::PartWriterInfrastructure::ChecksumRecord
  alias ChecksumsWriter = CrystalClick::PartWriterInfrastructure::PartChecksumsWriter

  NAME      = "by_group"
  KEY_NAMES = ["region", "day", "bucket", "zone"]
  WORD      = 0x0102030405060708_u64
  KEYS      = [
    Slice[0_u64, 0_u64, 0_u64, 0_u64, 0_u64, 10_u64],
    Slice[8_u64, 8_u64, 8_u64, 8_u64, 9_u64, 0_u64],
    Slice[0_u64, 0_u64, 2_u64, UInt64::MAX, 0_u64, 0_u64],
    Slice[2_u64, WORD, 0_u64, 1_u64, 1_u64, 4_u64],
  ]
  IDS         = Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64]
  UINT64      = CrystalClick::BinaryDataType.primitive("UInt64")
  STRING      = CrystalClick::BinaryDataType.primitive("String")
  COUNT_TYPE  = CrystalClick::BinaryDataType.aggregate_count
  STATES      = ["max(value)", "count()", "sum(value)", "min(value)"]
  ALL_COLUMNS = KEY_NAMES + STATES
  DDL         = "SELECT zone, max(value) AS mx, day, count(), sum(value), region, min(value) GROUP BY region, day, bucket, zone"

  def with_catalog(& : CrystalClick::OfflineCatalog, String -> Nil) : Nil
    root = File.tempname("crystal-click-w299")
    _, database, target = CompactMaterializedViewTransformW286Fixture.catalog(root, target_value_declaration: "UInt64")
    keys = KEY_NAMES.map { |key| "`#{key}` UInt64" }.join(", ")
    table = File.join(database, "target.sql")
    File.write(table, File.read(table).sub("`label` String\n)", "`label` String, #{keys}, PROJECTION #{NAME} (#{DDL})\n)"))
    view = File.join(database, "view.sql")
    File.write(view, File.read(view).sub("`label` String", "`label` String, #{keys}")
      .sub("AS SELECT k, v, v FROM lab.source WHERE k > 1", "AS SELECT k, k, v, k, k, k, k FROM lab.source"))
    yield CrystalClick::OfflineCatalog.open(root), target
  ensure
    FileUtils.rm_rf(root) if root
  end

  def aggregates : Array(Aggregate)
    [
      Aggregate.max_uint64("value", Slice[UInt64::MAX, 0_u64, WORD, 3_u64, UInt64::MAX, 9_u64]),
      Aggregate.count(Slice[2_u64, 1_u64, 1_u64, 1_u64, 1_u64, 1_u64]),
      Aggregate.sum_uint64("value", Slice[1_u64, 0_u64, WORD, 3_u64, UInt64::MAX, 9_u64]),
      Aggregate.min_uint64("value", Slice[2_u64, 0_u64, WORD, 3_u64, UInt64::MAX, 9_u64]),
    ]
  end

  def child(compress_marks : Bool = true) : Projection
    Projection.precomputed_aggregate(
      NAME, KEY_NAMES, KEYS, aggregates, rows_per_mark: 2, compress_marks: compress_marks
    )
  end

  def transform(
    catalog : CrystalClick::OfflineCatalog,
    projection : Projection,
    compact_parent : Bool,
  ) : String
    if compact_parent
      catalog.transform_materialized_view_part(
        "lab", "view", "all_1_1_0", ["k"], "all_8_8_0", rows_per_mark: 2, batch_rows: 2,
        mark_format: CrystalClick::CompactMarkFormat::Mrk4,
      ) do |input|
        columns = output(input).map { |name, type, values| CrystalClick::CompactPartColumn.binary_bulk(name, type, values) }
        CrystalClick::CompactPartTransformOutput.new(IDS, columns, projections: [projection])
      end
    else
      catalog.transform_materialized_view_part(
        "lab", "view", "all_1_1_0", ["k"], "all_8_8_0", rows_per_mark: 2, batch_rows: 2,
      ) do |input|
        columns = output(input).map { |name, type, values| CrystalClick::WidePartColumn.binary_bulk(name, type, values) }
        CrystalClick::WidePartTransformOutput.new(IDS, columns, projections: [projection])
      end
    end
  end

  def attach(catalog : CrystalClick::OfflineCatalog, target : String, parent : String) : CrystalClick::OfflineTable
    File.rename(parent, File.join(target, File.basename(parent)))
    CrystalClick::OfflineCatalog.open(catalog.root)["lab"]["target"]
  end

  def expected_rows : Array(Array(String))
    KEYS[0].size.times.map do |row|
      KEYS.map { |lane| lane[row].to_s } + [
        minmax_state_hex([UInt64::MAX, 0_u64, WORD, 3_u64, UInt64::MAX, 9_u64][row]),
        [2_u64, 1_u64, 1_u64, 1_u64, 1_u64, 1_u64][row].to_s,
        fixed_state_hex([1_u64, 0_u64, WORD, 3_u64, UInt64::MAX, 9_u64][row]),
        minmax_state_hex([2_u64, 0_u64, WORD, 3_u64, UInt64::MAX, 9_u64][row]),
      ]
    end.to_a
  end

  def mark_name(column : String) : String
    "#{CrystalClick::StreamName.hash(CrystalClick::PhysicalStreamName.escape(column))}.cmrk2"
  end

  def read_rows(table : CrystalClick::OfflineTable, columns : Array(String), start : UInt64, length : Int) : Array(Array(String))
    rows = [] of Array(String)
    table.scan_projection_typed_window(NAME, columns, start, length) do |batch|
      batch.column_names.should eq(columns)
      key_columns = KEY_NAMES.select { |name| columns.includes?(name) }.map { |name| batch.values_for(name, UInt64) }
      count_values = if columns.includes?("count()")
                       batch.aggregate_count_states_for("count()", COUNT_TYPE).map(&.count_state)
                     else
                       [] of UInt64
                     end
      state_values = STATES.reject { |name| name == "count()" }.select { |name| columns.includes?(name) }
        .map { |name| batch.binary_bulk_values_for(name).map { |value| value.aggregate_function_state_bytes.hexstring } }
      state_names = STATES.reject { |name| name == "count()" }.select { |name| columns.includes?(name) }
      batch_rows = if columns.includes?("count()")
                     count_values.size
                   elsif !key_columns.empty?
                     key_columns.first.size
                   else
                     state_values.first.size
                   end
      batch_rows.times do |row|
        values = [] of String
        key_columns.each { |column| values << column[row].to_s }
        if columns.includes?("max(value)")
          values << state_values[state_names.index("max(value)").not_nil!][row]
        end
        values << count_values[row].to_s if columns.includes?("count()")
        if columns.includes?("sum(value)")
          values << state_values[state_names.index("sum(value)").not_nil!][row]
        end
        if columns.includes?("min(value)")
          values << state_values[state_names.index("min(value)").not_nil!][row]
        end
        rows << values
      end
    end
    rows
  end

  def refresh_compressed_marks!(parent : String, mark_name : String, raw : Bytes? = nil, physical : Bytes? = nil) : Nil
    child = File.join(parent, "#{NAME}.proj")
    checksums = CrystalClick::PartChecksums.open(child)
    old = checksums.entry(mark_name).not_nil!
    canonical = raw || CrystalClick::CompressedBlock.decode_all(File.read(File.join(child, mark_name)).to_slice)
    encoded = physical || CrystalClick::CompressedMarkWriter.encode_all(
      canonical, 4096, CrystalClick::CompressedStreamBudget.write_default
    )
    File.write(File.join(child, mark_name), encoded)
    records = checksums.entries.map do |name, entry|
      if name == mark_name
        ChecksumRecord.new(
          name, encoded.size.to_u64, CrystalClick::CityHashV1.file_hash(encoded), true,
          canonical.size.to_u64, CrystalClick::CityHashV1.file_hash(canonical)
        )
      else
        ChecksumRecord.new(name, entry.physical_size, entry.file_hash, entry.compressed,
          entry.uncompressed_size, entry.uncompressed_hash)
      end
    end
    ChecksumsWriter.write(child, records)
    ProjectionChecksumFixture.rebind!(parent, NAME)
    old.physical_size.should be > 0_u64
    nil
  end

  def add_duplicate_plain_sidecar!(parent : String, compressed_name : String) : Nil
    child = File.join(parent, "#{NAME}.proj")
    checksums = CrystalClick::PartChecksums.open(child)
    physical = File.read(File.join(child, compressed_name)).to_slice
    plain_name = compressed_name.sub(/\.cmrk2\z/, ".mrk2")
    File.write(File.join(child, plain_name), physical)
    records = checksums.entries.map do |name, entry|
      ChecksumRecord.new(name, entry.physical_size, entry.file_hash, entry.compressed,
        entry.uncompressed_size, entry.uncompressed_hash)
    end
    records << ChecksumRecord.new(
      plain_name, physical.size.to_u64, CrystalClick::CityHashV1.file_hash(physical), false
    )
    ChecksumsWriter.write(child, records)
    ProjectionChecksumFixture.rebind!(parent, NAME)
    nil
  end

  def switch_compressed_mark_to_plain!(parent : String, compressed_name : String) : Nil
    child = File.join(parent, "#{NAME}.proj")
    checksums = CrystalClick::PartChecksums.open(child)
    compressed_path = File.join(child, compressed_name)
    canonical = CrystalClick::CompressedBlock.decode_all(File.read(compressed_path).to_slice)
    plain_name = compressed_name.sub(/\.cmrk2\z/, ".mrk2")
    File.write(File.join(child, plain_name), canonical)
    File.delete(compressed_path)
    records = checksums.entries.reject { |name, _entry| name == compressed_name }.map do |name, entry|
      ChecksumRecord.new(name, entry.physical_size, entry.file_hash, entry.compressed,
        entry.uncompressed_size, entry.uncompressed_hash)
    end
    records << ChecksumRecord.new(
      plain_name, canonical.size.to_u64, CrystalClick::CityHashV1.file_hash(canonical), false
    )
    ChecksumsWriter.write(child, records)
    ProjectionChecksumFixture.rebind!(parent, NAME)
    nil
  end

  private def fixed_state_hex(value : UInt64) : String
    bytes = Bytes.new(sizeof(UInt64))
    IO::ByteFormat::LittleEndian.encode(value, bytes)
    bytes.hexstring
  end

  private def minmax_state_hex(value : UInt64) : String
    bytes = Bytes.new(sizeof(UInt64) + 1)
    bytes[0] = 1_u8
    IO::ByteFormat::LittleEndian.encode(value, bytes[1, sizeof(UInt64)])
    bytes.hexstring
  end

  private def output(input : CrystalClick::OfflinePartTransformInput)
    source = [] of UInt64
    input.each_batch { |batch| source.concat(batch.values_for("k")) }
    source.should eq([1_u64, 2_u64, 3_u64, 4_u64])
    values = [UInt64::MAX, 2_u64, 0_u64, WORD, 3_u64, UInt64::MAX, 9_u64]
    columns = [
      {"value", UINT64, values.map { |value| CrystalClick::BinaryValue.uint64(value) }},
      {"label", STRING, Array(CrystalClick::BinaryValue).new(IDS.size) { CrystalClick::BinaryValue.string("row") }},
    ]
    KEY_NAMES.zip(KEYS).each do |name, lane|
      rows = [lane[0]] + lane.to_a
      columns << {name, UINT64, rows.map { |value| CrystalClick::BinaryValue.uint64(value) }}
    end
    columns.map { |name, type, rows| {name, type, rows.each_slice(2).to_a} }
  end
end

private alias W299 = CompressedAggregateProjectionW299Fixture

describe "W299 Wide compressed UInt64 aggregate projection marks" do
  it "writes a complete compressed child independent of Wide or Compact parent layout and reads full and selected windows" do
    [false, true].each do |compact_parent|
      W299.with_catalog do |catalog, target|
        parent = W299.transform(catalog, W299.child, compact_parent)
        attached = W299.attach(catalog, target, parent)
        child = File.join(attached.part_candidates.first.path, "#{W299::NAME}.proj")
        mark_files = Dir.children(child).select(&.ends_with?(".cmrk2")).sort
        mark_files.size.should eq(W299::ALL_COLUMNS.size)
        Dir.children(child).select(&.ends_with?(".mrk2")).should be_empty
        checksums = CrystalClick::PartChecksums.open(child)
        mark_files.each do |name|
          entry = checksums.entry(name).not_nil!
          physical = File.read(File.join(child, name)).to_slice
          entry.compressed.should be_true
          entry.physical_size.should eq(physical.size.to_u64)
          entry.file_hash.should eq(CrystalClick::CityHashV1.file_hash(physical))
          physical[CrystalClick::CompressedBlock::CHECKSUM_SIZE].should eq(CrystalClick::CompressedBlock::METHOD_LZ4)
          entry.uncompressed_size.should eq(4_u64 * CrystalClick::CompressedMarkWriter::MARK_RECORD_SIZE.to_u64)
          entry.uncompressed_hash.should eq(CrystalClick::CityHashV1.file_hash(
            CrystalClick::CompressedBlock.decode_all(File.read(File.join(child, name)).to_slice)
          ))
        end

        W299.read_rows(attached, W299::ALL_COLUMNS, 0_u64, 6).should eq(W299.expected_rows)
        W299.read_rows(attached, W299::ALL_COLUMNS, 1_u64, 4).should eq(W299.expected_rows[1, 4])
        W299.read_rows(attached, W299::STATES, 1_u64, 4).should eq(W299.expected_rows[1, 4].map { |row| row[4..] })
      end
    end
  end

  it "rejects stale or misbound mark declarations before callbacks for either parent layout" do
    [false, true].each do |compact_parent|
      mark_name = W299.mark_name("sum(value)")
      W299.with_catalog do |catalog, target|
        parent = W299.transform(catalog, W299.child, compact_parent)
        child = File.join(parent, "#{W299::NAME}.proj")
        mutate_fixture_file(child, mark_name) { |bytes| bytes[bytes.size - 1] ^= 1_u8 }
        ProjectionChecksumFixture.rebind!(parent, W299::NAME)
        table = W299.attach(catalog, target, parent)
        callbacks = 0
        expect_raises(CrystalClick::CorruptPartError, /checksum|mark|sidecar|mix/i) do
          table.scan_projection_typed_window(W299::NAME, W299::STATES, 0_u64, 1) do |_batch|
            callbacks += 1
          end
        end
        callbacks.should eq(0)
      end

      W299.with_catalog do |catalog, target|
        parent = W299.transform(catalog, W299.child, compact_parent)
        W299.add_duplicate_plain_sidecar!(parent, mark_name)
        table = W299.attach(catalog, target, parent)
        callbacks = 0
        expect_raises(CrystalClick::CorruptPartError, /sidecar|checksum/i) do
          table.scan_projection_typed_window(W299::NAME, W299::STATES, 0_u64, 1) do |_batch|
            callbacks += 1
          end
        end
        callbacks.should eq(0)
      end
    end
  end

  it "rejects rehashed invalid and truncated compressed frames before callbacks for either parent layout" do
    [false, true].each do |compact_parent|
      mark_name = W299.mark_name("sum(value)")
      W299.with_catalog do |catalog, target|
        parent = W299.transform(catalog, W299.child, compact_parent)
        physical = File.read(File.join(parent, "#{W299::NAME}.proj", mark_name)).to_slice.dup
        physical[0] ^= 1_u8
        W299.refresh_compressed_marks!(parent, mark_name, physical: physical)
        table = W299.attach(catalog, target, parent)
        callbacks = 0
        expect_raises(CrystalClick::CorruptPartError, /compressed|checksum|frame/i) do
          table.scan_projection_typed_window(W299::NAME, W299::STATES, 0_u64, 1) do |_batch|
            callbacks += 1
          end
        end
        callbacks.should eq(0)
      end

      W299.with_catalog do |catalog, target|
        parent = W299.transform(catalog, W299.child, compact_parent)
        physical = File.read(File.join(parent, "#{W299::NAME}.proj", mark_name)).to_slice.dup
        truncated = physical[0, physical.size - 1]
        W299.refresh_compressed_marks!(parent, mark_name, physical: truncated)
        table = W299.attach(catalog, target, parent)
        callbacks = 0
        expect_raises(CrystalClick::CorruptPartError, /compressed|checksum|frame/i) do
          table.scan_projection_typed_window(W299::NAME, W299::STATES, 0_u64, 1) do |_batch|
            callbacks += 1
          end
        end
        callbacks.should eq(0)
      end
    end
  end

  it "checks a rehashed same-row-count later mark span before emitting an earlier window" do
    [false, true].each do |compact_parent|
      W299.with_catalog do |catalog, target|
        parent = W299.transform(catalog, W299.child, compact_parent)
        mark_name = W299.mark_name("sum(value)")
        child = File.join(parent, "#{W299::NAME}.proj")
        raw = CrystalClick::CompressedBlock.decode_all(File.read(File.join(child, mark_name)).to_slice).dup
        mark_start = 2 * CrystalClick::CompressedMarkWriter::MARK_RECORD_SIZE
        offset = mark_start + sizeof(UInt64)
        value = IO::ByteFormat::LittleEndian.decode(UInt64, raw[offset, sizeof(UInt64)])
        IO::ByteFormat::LittleEndian.encode(value + 1_u64, raw[offset, sizeof(UInt64)])
        W299.refresh_compressed_marks!(parent, mark_name, raw)
        table = W299.attach(catalog, target, parent)
        callbacks = 0
        expect_raises(CrystalClick::CorruptPartError, /grid|span|offset|mark/i) do
          table.scan_projection_typed_window(W299::NAME, W299::STATES, 0_u64, 1) do |_batch|
            callbacks += 1
          end
        end
        callbacks.should eq(0)
      end
    end
  end

  it "preflights a rehashed hidden fourth-key mark for Sum and Count requests through EOF" do
    [false, true].each do |compact_parent|
      W299.with_catalog do |catalog, target|
        parent = W299.transform(catalog, W299.child, compact_parent)
        mark_name = W299.mark_name("zone")
        child = File.join(parent, "#{W299::NAME}.proj")
        raw = CrystalClick::CompressedBlock.decode_all(File.read(File.join(child, mark_name)).to_slice).dup
        mark_start = 2 * CrystalClick::CompressedMarkWriter::MARK_RECORD_SIZE
        offset = mark_start + sizeof(UInt64)
        value = IO::ByteFormat::LittleEndian.decode(UInt64, raw[offset, sizeof(UInt64)])
        IO::ByteFormat::LittleEndian.encode(value + 1_u64, raw[offset, sizeof(UInt64)])
        W299.refresh_compressed_marks!(parent, mark_name, raw)
        table = W299.attach(catalog, target, parent)

        ["sum(value)", "count()"].each do |column|
          [0_u64, 6_u64].each do |start|
            callbacks = 0
            expect_raises(CrystalClick::CorruptPartError, /grid|span|offset|mark/i) do
              table.scan_projection_typed_window(W299::NAME, [column], start, 1) do |_batch|
                callbacks += 1
              end
            end
            callbacks.should eq(0)
          end
        end
      end
    end
  end

  it "rejects a mixed genuine plain mark sidecar before Sum callbacks at row zero and EOF" do
    [false, true].each do |compact_parent|
      W299.with_catalog do |catalog, target|
        parent = W299.transform(catalog, W299.child, compact_parent)
        W299.switch_compressed_mark_to_plain!(parent, W299.mark_name("zone"))
        table = W299.attach(catalog, target, parent)
        [0_u64, 6_u64].each do |start|
          callbacks = 0
          expect_raises(CrystalClick::CorruptPartError, /mark|sidecar|format|mix/i) do
            table.scan_projection_typed_window(W299::NAME, ["sum(value)"], start, 1) do |_batch|
              callbacks += 1
            end
          end
          callbacks.should eq(0)
        end
      end
    end
  end

  it "rejects a rehashed impossible later Count span before callbacks through EOF" do
    [false, true].each do |compact_parent|
      W299.with_catalog do |catalog, target|
        parent = W299.transform(catalog, W299.child, compact_parent)
        mark_name = W299.mark_name("count()")
        child = File.join(parent, "#{W299::NAME}.proj")
        raw = CrystalClick::CompressedBlock.decode_all(File.read(File.join(child, mark_name)).to_slice).dup
        mark_start = 2 * CrystalClick::CompressedMarkWriter::MARK_RECORD_SIZE
        offset = mark_start + sizeof(UInt64)
        value = IO::ByteFormat::LittleEndian.decode(UInt64, raw[offset, sizeof(UInt64)])
        IO::ByteFormat::LittleEndian.encode(value + 1_u64, raw[offset, sizeof(UInt64)])
        W299.refresh_compressed_marks!(parent, mark_name, raw)
        table = W299.attach(catalog, target, parent)

        [0_u64, 6_u64].each do |start|
          callbacks = 0
          expect_raises(CrystalClick::CorruptPartError, /grid|span|offset|mark/i) do
            table.scan_projection_typed_window(W299::NAME, ["count()"], start, 1) do |_batch|
              callbacks += 1
            end
          end
          callbacks.should eq(0)
        end
      end
    end
  end
end
