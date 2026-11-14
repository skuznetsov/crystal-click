require "./spec_helper"
require "file_utils"
require "./support/offline_materialized_view_compact_transform_w286_fixture"

private module CompactCountProjectionW295Fixture
  extend self

  PROJECTION = "by_score"
  PARENT     = "all_8_8_0"
  KEYS       = Slice[0_u64, 10_u64, UInt64::MAX]
  COUNTS     = Slice[1_u64, 2_u64, 1_u64]

  def with_catalog(
    projection : String = "SELECT count() AS n, score GROUP BY score",
    & : CrystalClick::OfflineCatalog, String -> Nil
  )
    root = File.tempname("crystal-click-w295")
    _, database, target = CompactMaterializedViewTransformW286Fixture.catalog(root)
    table_ddl = File.join(database, "target.sql")
    table_sql = File.read(table_ddl).sub(
      "`id` UInt64, `value` String, `label` String",
      "`id` UInt64, `value` String, `label` String, `score` UInt64, " +
      "PROJECTION #{PROJECTION} (#{projection})"
    )
    File.write(table_ddl, table_sql)
    view_ddl = File.join(database, "view.sql")
    view_sql = File.read(view_ddl)
      .sub("`label` String", "`label` String, `score` UInt64")
      .sub("SELECT k, v, v FROM lab.source WHERE k > 1", "SELECT k, v, v, k FROM lab.source")
    File.write(view_ddl, view_sql)
    yield CrystalClick::OfflineCatalog.open(root), target
  ensure
    FileUtils.rm_rf(root) if root
  end

  def count_child(
    keys : Slice(UInt64) = KEYS,
    counts : Slice(UInt64) = COUNTS,
  ) : CrystalClick::CompactPartProjection
    CrystalClick::CompactPartProjection.precomputed_count(
      PROJECTION, "score", keys, counts, rows_per_mark: 2
    )
  end

  def transform(
    catalog : CrystalClick::OfflineCatalog,
    projection : CrystalClick::WidePartProjection | CrystalClick::CompactPartProjection,
    compact_parent : Bool,
    name : String = PARENT,
  ) : String
    if compact_parent
      catalog.transform_materialized_view_part(
        "lab", "view", "all_1_1_0", ["k", "v"], name,
        mark_format: CrystalClick::CompactMarkFormat::Mrk4, rows_per_mark: 2,
      ) do |input|
        keys, columns = transform_input(input)
        outputs = columns.map do |(name, type, granules)|
          CrystalClick::CompactPartColumn.binary_bulk(name, type, granules)
        end
        CrystalClick::CompactPartTransformOutput.new(
          keys.to_unsafe.to_slice(keys.size), outputs, projections: [projection]
        )
      end
    else
      catalog.transform_materialized_view_part(
        "lab", "view", "all_1_1_0", ["k", "v"], name, rows_per_mark: 2,
      ) do |input|
        keys, columns = transform_input(input)
        outputs = columns.map do |(name, type, granules)|
          CrystalClick::WidePartColumn.binary_bulk(name, type, granules)
        end
        CrystalClick::WidePartTransformOutput.new(
          keys.to_unsafe.to_slice(keys.size), outputs, projections: [projection]
        )
      end
    end
  end

  def activate(catalog : CrystalClick::OfflineCatalog, target : String, path : String) : CrystalClick::OfflineTable
    File.rename(path, File.join(target, File.basename(path)))
    CrystalClick::OfflineCatalog.open(catalog.root)["lab"]["target"]
  end

  private def transform_input(input : CrystalClick::OfflinePartTransformInput)
    keys = [] of UInt64
    labels = [] of CrystalClick::BinaryValue
    input.each_batch do |batch|
      batch.values_for("k").each { |key| keys << key }
      batch.strings_for("v").each { |value| labels << CrystalClick::BinaryValue.string(value) }
    end
    keys.should eq([1_u64, 2_u64, 3_u64, 4_u64])
    scores = [0_u64, 10_u64, 10_u64, UInt64::MAX].map { |value| CrystalClick::BinaryValue.uint64(value) }
    string = CrystalClick::BinaryDataType.primitive("String")
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    columns = [
      {"value", string, labels.each.each_slice(2).to_a},
      {"label", string, labels.each.each_slice(2).to_a},
      {"score", uint64, scores.each.each_slice(2).to_a},
    ]
    {keys, columns}
  end
end

private alias W295Count = CompactCountProjectionW295Fixture

describe "W295 Compact Count projection publication and reads" do
  it "publishes MRK4 Count children of both parent layouts and scans their nominal states" do
    [false, true].each do |compact_parent|
      W295Count.with_catalog do |catalog, target|
        keys = W295Count::KEYS.dup
        counts = W295Count::COUNTS.dup
        projection = W295Count.count_child(keys, counts)
        keys[1] = 99_u64
        counts[1] = 99_u64
        path = W295Count.transform(catalog, projection, compact_parent)
        child = File.join(path, "#{W295Count::PROJECTION}.proj")
        File.exists?(File.join(child, "data.mrk4")).should be_true
        File.read(File.join(child, "columns.txt")).should contain("`count()` AggregateFunction(count)")
        File.read(File.join(child, "columns_substreams.txt")).should contain("\tcount%28%29\n")

        table = W295Count.activate(catalog, target, path)
        type = CrystalClick::BinaryDataType.aggregate_count
        all = [] of {UInt64, UInt64}
        table.scan_projection_typed(W295Count::PROJECTION, ["score", "count()"], batch_rows: 1) do |batch|
          batch.part_name.should eq(W295Count::PARENT)
          all << {batch.values_for("score")[0], batch.aggregate_count_states_for("count()", type)[0].count_state}
        end
        all.should eq([{0_u64, 1_u64}, {10_u64, 2_u64}, {UInt64::MAX, 1_u64}])

        window = [] of UInt64
        table.scan_projection_typed_window(W295Count::PROJECTION, ["count()"], 1_u64, 2) do |batch|
          batch.column_names.should eq(["count()"])
          batch.aggregate_count_states_for("count()", type).each { |state| window << state.count_state }
        end
        window.should eq([2_u64, 1_u64])
      end
    end
  end

  it "rejects zero counts, unequal lengths, duplicate keys, and descending keys at construction" do
    expect_raises(ArgumentError) { W295Count.count_child(counts: Slice[1_u64, 0_u64, 1_u64]) }
    expect_raises(ArgumentError) { W295Count.count_child(counts: Slice[1_u64, 2_u64]) }
    expect_raises(ArgumentError) { W295Count.count_child(keys: Slice[0_u64, 10_u64, 10_u64]) }
    expect_raises(ArgumentError) { W295Count.count_child(keys: Slice[0_u64, 10_u64, 9_u64]) }
  end

  it "refuses a Count total different from the parent row count for both parent layouts" do
    [false, true].each do |compact_parent|
      W295Count.with_catalog do |catalog, target|
        bad_total = W295Count.count_child(counts: Slice[1_u64, 2_u64, 2_u64])
        expect_raises(ArgumentError, /count.*(total|row count)/i) do
          W295Count.transform(catalog, bad_total, compact_parent)
        end
        Dir.children(File.join(target, "detached")).should be_empty
      end
    end
  end

  it "refuses the Compact Count owner for plain, mixed-aggregate, and two-key declarations" do
    [
      "SELECT score, label ORDER BY score",
      "SELECT score, count(), sum(id) GROUP BY score",
      "SELECT count() GROUP BY score, id",
    ].each do |definition|
      W295Count.with_catalog(definition) do |catalog, target|
        expect_raises(CrystalClick::UnsupportedFormatError) do
          W295Count.transform(catalog, W295Count.count_child, compact_parent: false)
        end
        Dir.children(File.join(target, "detached")).should be_empty
      end
    end
  end

  it "keeps ordinary Compact Count inputs outside the projection profile" do
    W295Count.with_catalog do |_, target|
      type = CrystalClick::BinaryDataType.aggregate_count
      state = CrystalClick::BinaryValue.aggregate_count_state(type, 1_u64)
      path = File.join(target, "all_10_10_0")
      expect_raises(CrystalClick::UnsupportedFormatError) do
        count = CrystalClick::CompactPartColumn.binary_bulk("n", type, [[state]])
        CrystalClick::CompactPartWriter.write_uint64_columns(
          path, "score", Slice[0_u64], [count], mark_format: CrystalClick::CompactMarkFormat::Mrk4)
      end
      File.exists?(path).should be_false
    end
  end

  it "rejects a malformed hidden key callback roster before yielding Count-only rows" do
    W295Count.with_catalog do |catalog, target|
      parent = W295Count.transform(catalog, W295Count.count_child, compact_parent: false)
      sidecar = File.join(parent, "#{W295Count::PROJECTION}.proj", "columns_substreams.txt")
      original = File.read(sidecar)
      original.should contain("\tscore\n")
      File.write(sidecar, original.sub("\tscore\n", "\tforged\n"))
      table = W295Count.activate(catalog, target, parent)
      yielded = false
      expect_raises(CrystalClick::CorruptPartError) do
        table.scan_projection_typed(W295Count::PROJECTION, ["count()"]) do |_batch|
          yielded = true
        end
      end
      yielded.should be_false
    end
  end

  it "rejects a truncated hidden key in a later mark before yielding a short Count-only window" do
    W295Count.with_catalog do |catalog, target|
      parent = W295Count.transform(catalog, W295Count.count_child, compact_parent: false)
      marks_path = File.join(parent, "#{W295Count::PROJECTION}.proj", "data.mrk4")
      marks = File.read(marks_path).to_slice.dup
      slot_bytes = 2 * sizeof(UInt64)
      mark_bytes = 2 * slot_bytes + sizeof(UInt64)
      marks.size.should eq(3 * mark_bytes)
      # Make the second mark's leading key interval empty without changing
      # the global axis, file size, or first mark's Count bytes.
      marks[mark_bytes + slot_bytes, slot_bytes].copy_from(marks[mark_bytes, slot_bytes])
      File.write(marks_path, marks)
      table = W295Count.activate(catalog, target, parent)
      yielded = false
      expect_raises(CrystalClick::CorruptPartError, /UInt64 key.*(width|span)/i) do
        table.scan_projection_typed_window(W295Count::PROJECTION, ["count()"], 0_u64, 1) do |_batch|
          yielded = true
        end
      end
      yielded.should be_false
    end
  end

  it "reads a Count-only window across Compact and Wide children with the same group key" do
    W295Count.with_catalog do |catalog, target|
      compact = W295Count.transform(catalog, W295Count.count_child, compact_parent: false)
      wide_child = CrystalClick::WidePartProjection.precomputed_count(
        W295Count::PROJECTION, "score", W295Count::KEYS, W295Count::COUNTS, rows_per_mark: 1
      )
      wide_name = "all_9_9_0"
      wide = W295Count.transform(catalog, wide_child, compact_parent: true, name: wide_name)
      W295Count.activate(catalog, target, compact)
      table = W295Count.activate(catalog, target, wide)

      count = CrystalClick::BinaryDataType.aggregate_count
      rows = [] of {String, UInt64}
      table.scan_projection_typed_window(W295Count::PROJECTION, ["count()"], 2_u64, 3) do |batch|
        batch.aggregate_count_states_for("count()", count).each do |state|
          rows << {batch.part_name, state.count_state}
        end
      end
      rows.should eq([{W295Count::PARENT, 1_u64}, {wide_name, 1_u64}, {wide_name, 2_u64}])
    end
  end

  it "preflights the hidden group key across mixed children before any Count callback" do
    W295Count.with_catalog do |catalog, target|
      compact = W295Count.transform(catalog, W295Count.count_child, compact_parent: false)
      W295Count.activate(catalog, target, compact)

      keys = Slice[1_u64, 2_u64, 3_u64, 4_u64]
      wide_child = CrystalClick::WidePartProjection.precomputed_count(
        W295Count::PROJECTION, "id", keys, Slice[1_u64, 1_u64, 1_u64, 1_u64]
      )
      score = CrystalClick::WidePartColumn.binary_bulk(
        "score", CrystalClick::BinaryDataType.primitive("UInt64"),
        [[0_u64, 10_u64, 10_u64, UInt64::MAX].map { |value| CrystalClick::BinaryValue.uint64(value) }],
      )
      CrystalClick::WidePartWriter.write_uint64_columns(
        File.join(target, "all_9_9_0"), "id", keys, [score],
        projections: [wide_child],
      )
      table = CrystalClick::OfflineCatalog.open(catalog.root)["lab"]["target"]
      yielded = false
      expect_raises(CrystalClick::CorruptPartError, /sibling|group key/i) do
        table.scan_projection_typed_window(W295Count::PROJECTION, ["count()"], 0_u64, 1) do |_batch|
          yielded = true
        end
      end
      yielded.should be_false
    end
  end
end
