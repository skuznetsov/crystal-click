require "./spec_helper"
require "./support/offline_materialized_view_compact_transform_w286_fixture"
require "./support/projection_checksum_fixture"

private module CompoundProjectionW298Fixture
  extend self

  alias Aggregate = CrystalClick::WidePartProjectionAggregate
  alias Projection = CrystalClick::WidePartProjection | CrystalClick::CompactPartProjection
  alias IndexWriter = CrystalClick::PartWriterInfrastructure::PrimaryIndexWriter
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
  IDS        = Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64]
  COUNT_TYPE = CrystalClick::BinaryDataType.aggregate_count
  UINT64     = CrystalClick::BinaryDataType.primitive("UInt64")
  STRING     = CrystalClick::BinaryDataType.primitive("String")
  STATES     = ["max(value)", "count()", "sum(value)", "min(value)"]
  DDL        = "SELECT zone, max(value) AS mx, day, count(), sum(value), region, min(value) GROUP BY region, day, bucket, zone"

  def catalog(& : CrystalClick::OfflineCatalog, String -> Nil)
    root = File.tempname("crystal-click-w298")
    _, metadata, target = CompactMaterializedViewTransformW286Fixture.catalog(root, target_value_declaration: "UInt64")
    keys = KEY_NAMES.map { |key| "`#{key}` UInt64" }.join(", ")
    table = File.join(metadata, "target.sql")
    File.write(table, File.read(table).sub("`label` String\n)", "`label` String, #{keys}, PROJECTION #{NAME} (#{DDL})\n)"))
    view = File.join(metadata, "view.sql")
    File.write(view, File.read(view).sub("`label` String", "`label` String, #{keys}")
      .sub("AS SELECT k, v, v FROM lab.source WHERE k > 1", "AS SELECT k, k, v, k, k, k, k FROM lab.source"))
    yield CrystalClick::OfflineCatalog.open(root), target
  ensure
    FileUtils.rm_rf(root) if root
  end

  def states : Array(Aggregate)
    [
      Aggregate.max_uint64("value", Slice[UInt64::MAX, 0_u64, WORD, 3_u64, UInt64::MAX, 9_u64]),
      Aggregate.count(Slice[2_u64, 1_u64, 1_u64, 1_u64, 1_u64, 1_u64]),
      Aggregate.sum_uint64("value", Slice[1_u64, 0_u64, WORD, 3_u64, UInt64::MAX, 9_u64]),
      Aggregate.min_uint64("value", Slice[2_u64, 0_u64, WORD, 3_u64, UInt64::MAX, 9_u64]),
    ]
  end

  def child(compact : Bool, key_names : Array(String) = KEY_NAMES, keys : Array(Slice(UInt64)) = KEYS) : Projection
    if compact
      CrystalClick::CompactPartProjection.precomputed_aggregate(NAME, key_names, keys, states, rows_per_mark: 2)
    else
      CrystalClick::WidePartProjection.precomputed_aggregate(NAME, key_names, keys, states, rows_per_mark: 2)
    end
  end

  def transform(catalog : CrystalClick::OfflineCatalog, projection : Projection, compact : Bool) : String
    if compact
      catalog.transform_materialized_view_part(
        "lab", "view", "all_1_1_0", ["k"], "all_8_8_0", rows_per_mark: 2,
        mark_format: CrystalClick::CompactMarkFormat::Mrk4,
      ) do |input|
        columns = output(input).map { |name, type, values| CrystalClick::CompactPartColumn.binary_bulk(name, type, values) }
        CrystalClick::CompactPartTransformOutput.new(IDS, columns, projections: [projection])
      end
    else
      catalog.transform_materialized_view_part("lab", "view", "all_1_1_0", ["k"], "all_8_8_0", rows_per_mark: 2) do |input|
        columns = output(input).map { |name, type, values| CrystalClick::WidePartColumn.binary_bulk(name, type, values) }
        CrystalClick::WidePartTransformOutput.new(IDS, columns, projections: [projection])
      end
    end
  end

  def attach(catalog : CrystalClick::OfflineCatalog, target : String, parent : String) : CrystalClick::OfflineTable
    File.rename(parent, File.join(target, File.basename(parent)))
    CrystalClick::OfflineCatalog.open(catalog.root)["lab"]["target"]
  end

  def check_index(path : String) : Nil
    File.open(path) do |io|
      cells = Array(UInt64).new(16) { io.read_bytes(UInt64, IO::ByteFormat::LittleEndian) }
      cells.should eq([
        0_u64, 8_u64, 0_u64, 2_u64,
        0_u64, 8_u64, 2_u64, 0_u64,
        0_u64, 9_u64, 0_u64, 1_u64,
        10_u64, 0_u64, 0_u64, 4_u64,
      ])
      io.read_byte.should be_nil
    end
  end

  def rehash_file!(directory : String, file : String) : Nil
    data = writable_file_bytes(File.join(directory, file))
    records = CrystalClick::PartChecksums.open(directory).entries.map do |name, entry|
      if name == file
        ChecksumRecord.new(name, data.size.to_u64, CrystalClick::CityHashV1.file_hash(data), false)
      else
        ChecksumRecord.new(name, entry.physical_size, entry.file_hash, entry.compressed, entry.uncompressed_size, entry.uncompressed_hash)
      end
    end
    ChecksumsWriter.write(directory, records)
  end

  private def output(input : CrystalClick::OfflinePartTransformInput)
    source = [] of UInt64
    input.each_batch { |batch| source.concat(batch.values_for("k")) }
    source.should eq([1_u64, 2_u64, 3_u64, 4_u64])
    columns = [
      {"value", UINT64, [UInt64::MAX, 2_u64, 0_u64, WORD, 3_u64, UInt64::MAX, 9_u64].map { |value| CrystalClick::BinaryValue.uint64(value) }},
      {"label", STRING, Array(CrystalClick::BinaryValue).new(IDS.size) { CrystalClick::BinaryValue.string("row") }},
    ]
    KEY_NAMES.zip(KEYS).each do |name, lane|
      rows = [lane[0]] + lane.to_a
      columns << {name, UINT64, rows.map { |value| CrystalClick::BinaryValue.uint64(value) }}
    end
    columns.map { |name, type, values| {name, type, values.each_slice(2).to_a} }
  end
end

private alias W298 = CompoundProjectionW298Fixture

describe "W298 caller-run projections with ordered UInt64 group keys" do
  it "publishes detached four-lane snapshots and scans their states under both layouts" do
    [false, true].each do |compact_parent|
      [false, true].each do |compact_child|
        W298.catalog do |catalog, target|
          names = W298::KEY_NAMES.dup
          lanes = W298::KEYS.map(&.dup)
          child = W298.child(compact_child, names, lanes)
          names.reverse!
          lanes[3].fill(99_u64)
          child.additional_key_columns.last.fill(88_u64)

          parent = W298.transform(catalog, child, compact_parent)
          path = File.join(parent, "#{W298::NAME}.proj")
          File.read_lines(File.join(path, "columns.txt"))[2..].map { |line| line.split('`')[1] }.should eq(W298::KEY_NAMES + W298::STATES)
          W298.check_index(File.join(path, "primary.idx"))

          table = W298.attach(catalog, target, parent)
          values = [] of {String, UInt64}
          table.scan_projection_typed_window(W298::NAME, ["sum(value)", "count()"], 1_u64, 4) do |batch|
            sums = batch.binary_bulk_values_for("sum(value)")
            counts = batch.aggregate_count_states_for("count()", W298::COUNT_TYPE)
            sums.each_with_index { |sum, index| values << {sum.aggregate_function_state_bytes.hexstring, counts[index].count_state} }
          end
          values.should eq([
            {"0000000000000000", 1_u64}, {"0807060504030201", 1_u64},
            {"0300000000000000", 1_u64}, {"ffffffffffffffff", 1_u64},
          ])
        end
      end
    end
  end

  it "rejects duplicate or descending tuples distinguished only by their last key" do
    [false, true].each do |compact|
      [1_u64, 2_u64].each do |second_zone|
        lanes = W298::KEYS.map(&.dup)
        lanes.last[1] = second_zone
        expect_raises(ArgumentError, /lexicograph|increas/i) { W298.child(compact, keys: lanes) }
      end
      lanes = W298::KEYS.dup
      lanes[-1] = lanes.last[0, 5]
      expect_raises(ArgumentError, /length|grid/i) { W298.child(compact, keys: lanes) }
    end
  end

  it "rejects later keys in a different order than the DDL before publication" do
    W298.catalog do |catalog, target|
      swapped = ["region", "day", "zone", "bucket"]
      [false, true].each do |compact|
        child = W298.child(compact, swapped)
        expect_raises(CrystalClick::UnsupportedFormatError, /projection|schema/i) { W298.transform(catalog, child, compact) }
        Dir.children(File.join(target, "detached")).should be_empty
      end
    end
  end

  it "charges Wide key preparation to the shared write budget before encoding" do
    context = CrystalClick::WidePartWriter::WidePartOperationContext.new(
      2,
      CrystalClick::BinaryBulkProfile.single_stream,
      CrystalClick::BinaryBulkProfile.single_stream,
      CrystalClick::ObjectDocumentCodec::DEFAULT_MODE,
      4096,
      0_i64,
      CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
      CrystalClick::CompressedStreamLimits.new(max_result_bytes: 512),
    )
    context.transport_budget.reserve_result_bytes(256_i64)
    child = W298.child(false).as(CrystalClick::WidePartProjection)
    expect_raises(CrystalClick::UnsupportedFormatError, /compressed stream result-byte limit exceeded/) do
      CrystalClick::WidePartWriter::WidePartPreparedProjection.prepare(
        "/unused/parent", child, context, parent_row_count: W298::IDS.size.to_u64)
    end
    context.transport_budget.result_byte_count.should eq(256_i64)
  end

  it "preflights the hidden fourth-key span in an unselected later mark" do
    W298.catalog do |catalog, target|
      parent = W298.transform(catalog, W298.child(true), false)
      path = File.join(parent, "#{W298::NAME}.proj")
      mutate_fixture_file(path, "data.mrk4") do |marks|
        slot_width = 2 * sizeof(UInt64)
        mark_width = (W298::KEY_NAMES.size + W298::STATES.size) * slot_width + sizeof(UInt64)
        fourth_key = mark_width + 3 * slot_width
        marks[fourth_key + slot_width, slot_width].copy_from(marks[fourth_key, slot_width])
      end
      W298.rehash_file!(path, "data.mrk4")
      ProjectionChecksumFixture.rebind!(parent, W298::NAME)
      table = W298.attach(catalog, target, parent)
      ["sum(value)", "count()"].each do |column|
        expect_raises(CrystalClick::CorruptPartError, /width|span/i) do
          table.scan_projection_typed_window(W298::NAME, [column], 0_u64, 1) { fail "yielded an invalid child" }
        end
      end
    end
  end

  it "rejects a compressed index alongside the exact raw tuple index" do
    W298.catalog do |catalog, target|
      parent = W298.transform(catalog, W298.child(true), false)
      path = File.join(parent, "#{W298::NAME}.proj")
      File.write(File.join(path, "primary.cidx"), "")
      table = W298.attach(catalog, target, parent)
      expect_raises(CrystalClick::CorruptPartError, /compressed primary index/) do
        table.scan_projection_typed_window(W298::NAME, ["sum(value)"], 0_u64, 1) { fail "yielded an ambiguous child" }
      end
    end
  end

  it "rejects mismatched hidden Wide and Compact key rosters even at EOF" do
    W298.catalog do |catalog, target|
      W298.attach(catalog, target, W298.transform(catalog, W298.child(true), false))
      swapped = W298.child(false, ["region", "day", "zone", "bucket"]).as(CrystalClick::WidePartProjection)
      dummy = CrystalClick::WidePartColumn.binary_bulk("dummy", W298::UINT64,
        [Array(CrystalClick::BinaryValue).new(W298::IDS.size) { CrystalClick::BinaryValue.uint64(0_u64) }])
      CrystalClick::WidePartWriter.write_uint64_columns(
        File.join(target, "all_9_9_0"), "id", W298::IDS, [dummy], rows_per_mark: W298::IDS.size, projections: [swapped])
      table = CrystalClick::OfflineCatalog.open(catalog.root)["lab"]["target"]
      ["sum(value)", "count()"].each do |column|
        [0_u64, 12_u64].each do |start|
          expect_raises(CrystalClick::CorruptPartError, /sibling|group key/i) do
            table.scan_projection_typed_window(W298::NAME, [column], start, 1) { fail "yielded mismatched siblings" }
          end
        end
      end
    end
  end

  it "validates later index lanes against key values even after the index has been rehashed" do
    with_fixture_copy do |path|
      record = W298::IndexWriter.write_compound(path, W298::KEYS, 2)
      W298::ChecksumsWriter.write(path, [record])
      rows = [2_u64, 2_u64, 2_u64]
      W298::IndexWriter.validate_compound!(path, rows, W298::KEYS, CrystalClick::PartChecksums.open(path))
      [7, 15].each do |cell|
        W298::IndexWriter.write_compound(path, W298::KEYS, 2)
        mutate_fixture_file(path, "primary.idx") { |bytes| bytes[cell * sizeof(UInt64)] ^= 0x1_u8 }
        W298.rehash_file!(path, "primary.idx")
        expect_raises(CrystalClick::CorruptPartError, /ordered key marks|terminal/i) do
          W298::IndexWriter.validate_compound!(path, rows, W298::KEYS, CrystalClick::PartChecksums.open(path))
        end
      end
    end
  end
end
