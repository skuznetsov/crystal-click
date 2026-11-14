require "./spec_helper"
require "./support/offline_materialized_view_compact_transform_w286_fixture"
require "./support/projection_checksum_fixture"

private module CompactTwoKeyProjectionW297Fixture
  extend self

  alias Aggregate = CrystalClick::WidePartProjectionAggregate
  alias Granules = Array(Array(CrystalClick::BinaryValue))
  alias Projection = CrystalClick::CompactPartProjection | CrystalClick::WidePartProjection

  NAME       = "by_pair"
  KEYS       = {"region", "day"}
  FIRST      = Slice[0_u64, 0_u64, 7_u64, 7_u64, UInt64::MAX]
  WORD       = 0x0102030405060708_u64
  SECOND     = Slice[5_u64, UInt64::MAX, 0_u64, WORD, 9_u64]
  COUNTS     = Slice[2_u64, 1_u64, 1_u64, 1_u64, 1_u64]
  COLUMNS    = ["region", "day", "max(value)", "count()", "sum(value)", "min(value)"]
  DDL        = "SELECT day, max(value) AS biggest, count(), region, sum(value), min(value) GROUP BY region, day"
  TYPE       = CrystalClick::BinaryDataType.primitive("UInt64")
  COUNT_TYPE = CrystalClick::BinaryDataType.aggregate_count

  def catalog(definition : String = DDL, & : CrystalClick::OfflineCatalog, String -> Nil)
    root = File.tempname("crystal-click-w297")
    _, metadata, target = CompactMaterializedViewTransformW286Fixture.catalog(root, target_value_declaration: "UInt64")
    table_file = File.join(metadata, "target.sql")
    table_ddl = File.read(table_file).sub(
      "`label` String\n)",
      "`label` String, `region` UInt64, `day` UInt64, PROJECTION #{NAME} (#{definition})\n)"
    )
    File.write(table_file, table_ddl)
    view_file = File.join(metadata, "view.sql")
    view_ddl = File.read(view_file)
      .sub("`label` String", "`label` String, `region` UInt64, `day` UInt64")
      .sub("AS SELECT k, v, v FROM lab.source WHERE k > 1", "AS SELECT k, k, v, k, k FROM lab.source")
    File.write(view_file, view_ddl)
    yield CrystalClick::OfflineCatalog.open(root), target
  ensure
    FileUtils.rm_rf(root) if root
  end

  def aggregates : Array(Aggregate)
    [
      Aggregate.max_uint64("value", Slice[UInt64::MAX, 0_u64, WORD, 3_u64, UInt64::MAX]),
      Aggregate.count(COUNTS),
      Aggregate.sum_uint64("value", Slice[1_u64, 0_u64, WORD, 3_u64, UInt64::MAX]),
      Aggregate.min_uint64("value", Slice[2_u64, 0_u64, WORD, 3_u64, UInt64::MAX]),
    ]
  end

  def child(
    first : Slice(UInt64) = FIRST,
    second : Slice(UInt64) = SECOND,
    states : Array(Aggregate) = aggregates,
    keys : Tuple(String, String) = KEYS,
    compress_marks : Bool = false,
  ) : CrystalClick::CompactPartProjection
    CrystalClick::CompactPartProjection.precomputed_aggregate(
      NAME, keys, {first, second}, states, rows_per_mark: 2, compress_marks: compress_marks
    )
  end

  def transform(
    catalog : CrystalClick::OfflineCatalog,
    child : Projection,
    compact : Bool = false,
    name : String = "all_8_8_0",
  ) : String
    if compact
      catalog.transform_materialized_view_part(
        "lab", "view", "all_1_1_0", ["k"], name, rows_per_mark: 2,
        mark_format: CrystalClick::CompactMarkFormat::Mrk4,
      ) do |input|
        ids, columns = output(input)
        prepared = columns.map { |column, type, values| CrystalClick::CompactPartColumn.binary_bulk(column, type, values) }
        CrystalClick::CompactPartTransformOutput.new(ids, prepared, projections: [child])
      end
    else
      catalog.transform_materialized_view_part(
        "lab", "view", "all_1_1_0", ["k"], name, rows_per_mark: 2,
      ) do |input|
        ids, columns = output(input)
        prepared = columns.map { |column, type, values| CrystalClick::WidePartColumn.binary_bulk(column, type, values) }
        CrystalClick::WidePartTransformOutput.new(ids, prepared, projections: [child])
      end
    end
  end

  def attach(catalog : CrystalClick::OfflineCatalog, target : String, path : String) : CrystalClick::OfflineTable
    File.rename(path, File.join(target, File.basename(path)))
    CrystalClick::OfflineCatalog.open(catalog.root)["lab"]["target"]
  end

  def sums_and_counts(table : CrystalClick::OfflineTable, start : UInt64, length : Int) : Array({String, UInt64})
    result = [] of {String, UInt64}
    table.scan_projection_typed_window(NAME, ["sum(value)", "count()"], start, length) do |batch|
      sums = batch.binary_bulk_values_for("sum(value)")
      counts = batch.aggregate_count_states_for("count()", COUNT_TYPE)
      sums.each_with_index { |sum, index| result << {sum.aggregate_function_state_bytes.hexstring, counts[index].count_state} }
    end
    result
  end

  def index_pairs(child_path : String) : Array({UInt64, UInt64})
    File.open(File.join(child_path, "primary.idx")) do |io|
      Array({UInt64, UInt64}).new(4) do
        {io.read_bytes(UInt64, IO::ByteFormat::LittleEndian), io.read_bytes(UInt64, IO::ByteFormat::LittleEndian)}
      end.tap { io.read_byte.should be_nil }
    end
  end

  def write_mismatched_wide_sibling(target : String) : Nil
    projection = CrystalClick::WidePartProjection.precomputed_aggregate(
      NAME, {"day", "region"}, {FIRST, SECOND}, aggregates, rows_per_mark: 2
    )
    values = [Array(CrystalClick::BinaryValue).new(6) { CrystalClick::BinaryValue.uint64(0_u64) }]
    column = CrystalClick::WidePartColumn.binary_bulk("day", TYPE, values)
    CrystalClick::WidePartWriter.write_uint64_columns(
      File.join(target, "all_9_9_0"), "id", Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64],
      [column], rows_per_mark: 6, projections: [projection])
  end

  def replace_index(parent : String, bytes : Bytes, compressed : Bool = false) : Nil
    child_path = File.join(parent, "#{NAME}.proj")
    write_bytes(child_path, "primary.idx", bytes)
    records = CrystalClick::PartChecksums.open(child_path).entries.map do |name, entry|
      if name == "primary.idx"
        hash = CrystalClick::CityHashV1.file_hash(bytes)
        CrystalClick::PartWriterInfrastructure::ChecksumRecord.new(
          name, bytes.size.to_u64, hash, compressed, compressed ? bytes.size.to_u64 : nil, compressed ? hash : nil
        )
      else
        CrystalClick::PartWriterInfrastructure::ChecksumRecord.new(
          name, entry.physical_size, entry.file_hash, entry.compressed,
          entry.uncompressed_size, entry.uncompressed_hash
        )
      end
    end
    CrystalClick::PartWriterInfrastructure::PartChecksumsWriter.write(child_path, records)
    ProjectionChecksumFixture.rebind!(parent, NAME)
  end

  private def output(input : CrystalClick::OfflinePartTransformInput) : {Slice(UInt64), Array({String, CrystalClick::BinaryDataType, Granules})}
    source_keys = [] of UInt64
    input.each_batch { |batch| source_keys.concat(batch.values_for("k")) }
    source_keys.should eq([1_u64, 2_u64, 3_u64, 4_u64])

    region = [0_u64, 0_u64, 0_u64, 7_u64, 7_u64, UInt64::MAX]
    day = [5_u64, 5_u64, UInt64::MAX, 0_u64, WORD, 9_u64]
    value = [UInt64::MAX, 2_u64, 0_u64, WORD, 3_u64, UInt64::MAX]
    columns = {"value" => value, "region" => region, "day" => day}.map do |name, integers|
      {name, TYPE, integers.each_slice(2).map { |slice| slice.map { |number| CrystalClick::BinaryValue.uint64(number) } }.to_a}
    end
    columns.insert(1, {"label", CrystalClick::BinaryDataType.primitive("String"),
                       Array(Array(CrystalClick::BinaryValue)).new(3) { [CrystalClick::BinaryValue.string("label"), CrystalClick::BinaryValue.string("label")] }})
    {Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64], columns}
  end
end

private alias W297 = CompactTwoKeyProjectionW297Fixture

describe "W297 caller-run Compact projections with two UInt64 group keys" do
  it "writes both detached key lanes and the mark-start and terminal pairs under either parent layout" do
    [false, true].each do |compact|
      W297.catalog do |catalog, target|
        first = W297::FIRST.dup
        second = W297::SECOND.dup
        states = W297.aggregates
        child = W297.child(first, second, states, compress_marks: compact)
        first.fill(99_u64)
        second.fill(0_u64)
        states.clear
        parent = W297.transform(catalog, child, compact)
        path = File.join(parent, "#{W297::NAME}.proj")
        File.file?(File.join(path, compact ? "data.cmrk4" : "data.mrk4")).should be_true
        File.read_lines(File.join(path, "columns.txt"))[2..].map { |line| line.split('`')[1] }.should eq(W297::COLUMNS)
        W297.index_pairs(path).should eq([
          {0_u64, 5_u64}, {7_u64, 0_u64}, {UInt64::MAX, 9_u64}, {UInt64::MAX, 9_u64},
        ])

        table = W297.attach(catalog, target, parent)
        pairs = [] of {UInt64, UInt64}
        table.scan_projection_typed(W297::NAME, ["region", "day"]) do |batch|
          pairs.concat(batch.values_for("region").zip(batch.values_for("day")))
        end
        pairs.should eq(W297::FIRST.zip(W297::SECOND))
        W297.sums_and_counts(table, 0_u64, 5).should eq([
          {"0100000000000000", 2_u64}, {"0000000000000000", 1_u64}, {"0807060504030201", 1_u64},
          {"0300000000000000", 1_u64}, {"ffffffffffffffff", 1_u64},
        ])
        W297.sums_and_counts(table, 1_u64, 3).map(&.[0]).should eq([
          "0000000000000000", "0807060504030201", "0300000000000000",
        ])
      end
    end
  end

  it "rejects unequal key sizes and non-increasing pairs" do
    expect_raises(ArgumentError, /length/i) { W297.child(second: W297::SECOND[0, 4]) }
    expect_raises(ArgumentError, /distinct/i) { W297.child(keys: {"region", "region"}) }
    second = W297::SECOND.dup
    second[1] = second[0]
    expect_raises(ArgumentError, /lexicograph|increas/i) { W297.child(second: second) }
    second[1] = 0_u64
    expect_raises(ArgumentError, /lexicograph|increas/i) { W297.child(second: second) }
  end

  it "publishes a standalone two-key Count projection" do
    W297.catalog("SELECT count() GROUP BY region, day") do |catalog, target|
      child = CrystalClick::CompactPartProjection.precomputed_count(
        W297::NAME, W297::KEYS, {W297::FIRST, W297::SECOND}, W297::COUNTS, rows_per_mark: 2
      )
      table = W297.attach(catalog, target, W297.transform(catalog, child, compact: true))
      counts = [] of UInt64
      table.scan_projection_typed(W297::NAME, ["count()"]) do |batch|
        counts.concat(batch.aggregate_count_states_for("count()", W297::COUNT_TYPE).map(&.count_state))
      end
      counts.should eq(W297::COUNTS.to_a)
    end
  end

  it "refuses reversed key names, altered state order, and Count loss before publication" do
    W297.catalog do |catalog, target|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        W297.transform(catalog, W297.child(keys: {"day", "region"}))
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        W297.transform(catalog, W297.child(states: W297.aggregates.reverse), compact: true)
      end
      states = W297.aggregates
      states[1] = W297::Aggregate.count(Slice[1_u64, 1_u64, 1_u64, 1_u64, 1_u64])
      expect_raises(ArgumentError, /count.*total/i) { W297.transform(catalog, W297.child(states: states)) }
      Dir.children(File.join(target, "detached")).should be_empty
    end
  end

  it "preflights a hidden second-key span in a later mark before yielding any state" do
    W297.catalog do |catalog, target|
      parent = W297.transform(catalog, W297.child)
      path = File.join(parent, "#{W297::NAME}.proj")
      mutate_fixture_file(path, "data.mrk4") do |marks|
        slot_width = 2 * sizeof(UInt64)
        mark_width = W297::COLUMNS.size * slot_width + sizeof(UInt64)
        marks.size.should eq(4 * mark_width)
        second_key_slot = mark_width + slot_width
        first_state_slot = second_key_slot + slot_width
        marks[first_state_slot, slot_width].copy_from(marks[second_key_slot, slot_width])
      end
      table = W297.attach(catalog, target, parent)
      ["sum(value)", "count()"].each do |column|
        expect_raises(CrystalClick::CorruptPartError, /(width|span)/i) do
          table.scan_projection_typed_window(W297::NAME, [column], 0_u64, 1) { fail "yielded an invalid child" }
        end
      end
    end
  end

  it "rejects a checksum-bound scalar-width index or compressed declaration" do
    [false, true].each do |compressed|
      W297.catalog do |catalog, target|
        parent = W297.transform(catalog, W297.child)
        path = File.join(parent, "#{W297::NAME}.proj", "primary.idx")
        bytes = writable_file_bytes(path)
        bytes.size.should eq(64)
        W297.replace_index(parent, compressed ? bytes : bytes[0, 32], compressed: compressed)
        table = W297.attach(catalog, target, parent)
        expect_raises(CrystalClick::CorruptPartError, /primary.idx|primary index/i) do
          table.scan_projection_typed_window(W297::NAME, ["sum(value)"], 0_u64, 1) { fail "yielded an invalid index" }
        end
      end
    end
  end

  it "reads matching compound Compact and Wide children in a state-only window" do
    W297.catalog do |catalog, target|
      W297.attach(catalog, target, W297.transform(catalog, W297.child))
      wide = CrystalClick::WidePartProjection.precomputed_aggregate(
        W297::NAME, W297::KEYS, {W297::FIRST, W297::SECOND}, W297.aggregates, rows_per_mark: 3
      )
      sibling = W297.transform(catalog, wide, compact: true, name: "all_9_9_0")
      table = W297.attach(catalog, target, sibling)
      W297.sums_and_counts(table, 4_u64, 3).should eq([
        {"ffffffffffffffff", 1_u64}, {"0100000000000000", 2_u64}, {"0000000000000000", 1_u64},
      ])
      sums = [] of String
      table.scan_projection_typed_window(W297::NAME, ["sum(value)"], 4_u64, 3) do |batch|
        sums.concat(batch.binary_bulk_values_for("sum(value)").map(&.aggregate_function_state_bytes.hexstring))
      end
      sums.should eq(["ffffffffffffffff", "0100000000000000", "0000000000000000"])
    end
  end

  it "rejects an incompatible ordered sibling roster even for short and EOF state-only windows" do
    W297.catalog do |catalog, target|
      W297.attach(catalog, target, W297.transform(catalog, W297.child))
      W297.write_mismatched_wide_sibling(target)
      table = CrystalClick::OfflineCatalog.open(catalog.root)["lab"]["target"]
      ["sum(value)", "count()"].each do |column|
        [0_u64, 10_u64].each do |start|
          expect_raises(CrystalClick::CorruptPartError, /sibling|group key/i) do
            table.scan_projection_typed_window(W297::NAME, [column], start, 1) { fail "yielded incompatible children" }
          end
        end
      end
    end
  end
end
