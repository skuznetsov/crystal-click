require "./spec_helper"
require "./support/offline_materialized_view_compact_transform_w286_fixture"

private module CompactAggregateProjectionW296Fixture
  extend self

  alias Aggregate = CrystalClick::WidePartProjectionAggregate
  alias ColumnValues = Tuple(String, CrystalClick::BinaryDataType, Array(Array(CrystalClick::BinaryValue)))

  PROJECTION = "by_score"
  PARENT     = "all_8_8_0"
  GROUP_KEYS = Slice[0_u64, 10_u64, UInt64::MAX]
  WORD       = 0x0102030405060708_u64
  COLUMNS    = ["max(value)", "sum(value)", "min(value)"]
  DEFINITION = "SELECT max(value), sum(value), min(value) GROUP BY score"
  STATES     = [
    ["01ffffffffffffffff", "0100000000000000", "010200000000000000"],
    ["010000000000000000", "0000000000000000", "010000000000000000"],
    ["010807060504030201", "0807060504030201", "010807060504030201"],
  ]

  def with_catalog(definition : String = DEFINITION, & : CrystalClick::OfflineCatalog, String -> Nil)
    root = File.tempname("crystal-click-w296")
    _, database, target = CompactMaterializedViewTransformW286Fixture.catalog(root, target_value_declaration: "UInt64")
    table_path = File.join(database, "target.sql")
    table_ddl = File.read(table_path).sub(
      "`label` String\n)",
      "`label` String, `score` UInt64, PROJECTION #{PROJECTION} (#{definition})\n)"
    )
    File.write(table_path, table_ddl)
    view_path = File.join(database, "view.sql")
    view_ddl = File.read(view_path)
      .sub("`label` String", "`label` String, `score` UInt64")
      .sub("AS SELECT k, v, v FROM lab.source WHERE k > 1", "AS SELECT k, k, v, k FROM lab.source")
    File.write(view_path, view_ddl)
    yield CrystalClick::OfflineCatalog.open(root), target
  ensure
    FileUtils.rm_rf(root) if root
  end

  def aggregates : Array(Aggregate)
    [
      Aggregate.max_uint64("value", Slice[UInt64::MAX, 0_u64, WORD]),
      Aggregate.sum_uint64("value", Slice[1_u64, 0_u64, WORD]),
      Aggregate.min_uint64("value", Slice[2_u64, 0_u64, WORD]),
    ]
  end

  def child(
    keys : Slice(UInt64) = GROUP_KEYS,
    states : Array(Aggregate) = aggregates,
    compress_marks : Bool = false,
  ) : CrystalClick::CompactPartProjection
    CrystalClick::CompactPartProjection.precomputed_aggregate(
      PROJECTION, "score", keys, states, rows_per_mark: 2, compress_marks: compress_marks)
  end

  def transform(
    catalog : CrystalClick::OfflineCatalog,
    child : CrystalClick::CompactPartProjection | CrystalClick::WidePartProjection,
    compact : Bool = false,
    name : String = PARENT,
  ) : String
    if compact
      catalog.transform_materialized_view_part(
        "lab", "view", "all_1_1_0", ["k", "v"], name,
        rows_per_mark: 2, mark_format: CrystalClick::CompactMarkFormat::Mrk4,
      ) do |input|
        ids, columns = output_values(input)
        prepared = columns.map { |column, type, granules| CrystalClick::CompactPartColumn.binary_bulk(column, type, granules) }
        CrystalClick::CompactPartTransformOutput.new(ids.to_unsafe.to_slice(ids.size), prepared, projections: [child])
      end
    else
      catalog.transform_materialized_view_part(
        "lab", "view", "all_1_1_0", ["k", "v"], name, rows_per_mark: 2,
      ) do |input|
        ids, columns = output_values(input)
        prepared = columns.map { |column, type, granules| CrystalClick::WidePartColumn.binary_bulk(column, type, granules) }
        CrystalClick::WidePartTransformOutput.new(ids.to_unsafe.to_slice(ids.size), prepared, projections: [child])
      end
    end
  end

  def attach(catalog : CrystalClick::OfflineCatalog, target : String, part : String) : CrystalClick::OfflineTable
    File.rename(part, File.join(target, File.basename(part)))
    CrystalClick::OfflineCatalog.open(catalog.root)["lab"]["target"]
  end

  def read_window(table : CrystalClick::OfflineTable, start_row : UInt64, length : Int) : Array(Array(String))
    rows = [] of Array(String)
    table.scan_projection_typed_window(PROJECTION, COLUMNS, start_row, length) do |batch|
      batch.column_names.should eq(COLUMNS)
      max, sum, min = COLUMNS.map { |column| batch.binary_bulk_values_for(column) }
      sum.each_with_index do |value, index|
        rows << [max[index], value, min[index]].map(&.aggregate_function_state_bytes.hexstring)
      end
    end
    rows
  end

  private def output_values(input : CrystalClick::OfflinePartTransformInput) : Tuple(Array(UInt64), Array(ColumnValues))
    ids = [] of UInt64
    labels = [] of CrystalClick::BinaryValue
    input.each_batch do |batch|
      ids.concat(batch.values_for("k"))
      batch.strings_for("v").each { |value| labels << CrystalClick::BinaryValue.string(value) }
    end
    ids.should eq([1_u64, 2_u64, 3_u64, 4_u64])
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    string = CrystalClick::BinaryDataType.primitive("String")
    scores = [0_u64, 10_u64, 0_u64, UInt64::MAX].map { |value| CrystalClick::BinaryValue.uint64(value) }
    values = [2_u64, 0_u64, UInt64::MAX, WORD].map { |value| CrystalClick::BinaryValue.uint64(value) }
    columns = [
      {"value", uint64, values.each.each_slice(2).to_a},
      {"label", string, labels.each.each_slice(2).to_a},
      {"score", uint64, scores.each.each_slice(2).to_a},
    ]
    {ids, columns}
  end
end

private alias W296 = CompactAggregateProjectionW296Fixture

describe "W296 Compact UInt64 aggregate projection states" do
  it "writes detached snapshots and reads exact states across marks with either parent layout" do
    [false, true].each do |compact|
      W296.with_catalog do |catalog, target|
        keys = W296::GROUP_KEYS.dup
        states = W296.aggregates
        child = W296.child(keys, states, compress_marks: compact)
        keys.fill(99_u64)
        states.clear
        part = W296.transform(catalog, child, compact)
        projection = File.join(part, "#{W296::PROJECTION}.proj")
        marks = compact ? "data.cmrk4" : "data.mrk4"
        File.file?(File.join(projection, marks)).should be_true
        File.read_lines(File.join(projection, "columns.txt"))[2..].should eq([
          "`score` UInt64",
          "`max(value)` AggregateFunction(max, UInt64)",
          "`sum(value)` AggregateFunction(sum, UInt64)",
          "`min(value)` AggregateFunction(min, UInt64)",
        ])
        table = W296.attach(catalog, target, part)
        W296.read_window(table, 0_u64, 3).should eq(W296::STATES)
        W296.read_window(table, 1_u64, 2).should eq(W296::STATES[1..])
      end
    end
  end

  it "supports a standalone min and rejects wrong arguments, reordered states and excess groups" do
    W296.with_catalog("SELECT min(value) GROUP BY score") do |catalog, target|
      groups = Slice[0_u64, 1_u64, 2_u64, 3_u64, 4_u64]
      minimum = W296.aggregates.last
      invalid = [
        W296.child(states: [W296::Aggregate.min_uint64("id", Slice[2_u64, 0_u64, W296::WORD])]),
        W296.child(groups, [W296::Aggregate.min_uint64("value", groups)]),
      ]
      invalid.each do |child|
        expect_raises(CrystalClick::UnsupportedFormatError) { W296.transform(catalog, child) }
        Dir.children(File.join(target, "detached")).should be_empty
      end
      part = W296.transform(catalog, W296.child(states: [minimum]), compact: true)
      table = W296.attach(catalog, target, part)
      actual = [] of String
      table.scan_projection_typed(W296::PROJECTION, ["min(value)"]) do |batch|
        batch.binary_bulk_values_for("min(value)").each { |state| actual << state.aggregate_function_state_bytes.hexstring }
      end
      actual.should eq(W296::STATES.map(&.[2]))
    end
    W296.with_catalog do |catalog, target|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        W296.transform(catalog, W296.child(states: W296.aggregates.reverse))
      end
      Dir.children(File.join(target, "detached")).should be_empty
    end
  end

  it "enforces Count conservation in a mixed aggregate roster" do
    definition = "SELECT max(value), sum(value), min(value), count() GROUP BY score"
    W296.with_catalog(definition) do |catalog, target|
      states = W296.aggregates << W296::Aggregate.count(Slice[1_u64, 1_u64, 1_u64])
      [false, true].each do |compact|
        expect_raises(ArgumentError, /count.*total/i) do
          W296.transform(catalog, W296.child(states: states), compact)
        end
        Dir.children(File.join(target, "detached")).should be_empty
      end
    end
  end

  it "preflights a hidden aggregate's later-mark extent before a one-row Sum callback" do
    W296.with_catalog do |catalog, target|
      part = W296.transform(catalog, W296.child)
      projection = File.join(part, "#{W296::PROJECTION}.proj")
      mutate_fixture_file(projection, "data.mrk4") do |marks|
        slot_bytes = 2 * sizeof(UInt64)
        mark_bytes = 4 * slot_bytes + sizeof(UInt64)
        marks.size.should eq(3 * mark_bytes)
        # Empty the hidden max callback in the second data mark.
        max_pos = mark_bytes + slot_bytes
        sum_pos = max_pos + slot_bytes
        marks[sum_pos, slot_bytes].copy_from(marks[max_pos, slot_bytes])
      end
      table = W296.attach(catalog, target, part)
      yielded = false
      expect_raises(CrystalClick::CorruptPartError, /(width|span)/i) do
        table.scan_projection_typed_window(W296::PROJECTION, ["sum(value)"], 0_u64, 1) { yielded = true }
      end
      yielded.should be_false
    end
  end

  it "rejects an absent selected extremum with the expected physical width" do
    W296.with_catalog do |catalog, target|
      part = W296.transform(catalog, W296.child)
      child = File.join(part, "#{W296::PROJECTION}.proj")
      data = writable_file_bytes(File.join(child, "data.bin"))
      marks = writable_file_bytes(File.join(child, "data.mrk4"))
      max_pos = 2 * sizeof(UInt64)
      byte_order = IO::ByteFormat::LittleEndian
      frame = byte_order.decode(UInt64, marks[max_pos, sizeof(UInt64)])
      offset = byte_order.decode(UInt64, marks[max_pos + sizeof(UInt64), sizeof(UInt64)])
      frame.should eq(0_u64)
      decoded = CrystalClick::CompressedBlock.decode_frame(data, 0_i64)
      decoded.output[offset.to_i].should eq(1_u8)
      decoded.output[offset.to_i] = 0_u8
      mutated_frame = CrystalClick::CompressedMarkWriter.encode_all(decoded.output, frame_bytes: 4096)
      mutated_frame.size.should eq(decoded.end_offset)
      data[0, mutated_frame.size].copy_from(mutated_frame)
      write_bytes(child, "data.bin", data)
      table = W296.attach(catalog, target, part)
      yielded = false
      expect_raises(CrystalClick::CorruptPartError) do
        table.scan_projection_typed_window(W296::PROJECTION, ["max(value)"], 0_u64, 1) { yielded = true }
      end
      yielded.should be_false
    end
  end

  it "reads aggregate-only windows across Wide and Compact children without Count" do
    W296.with_catalog do |catalog, target|
      part = W296.transform(catalog, W296.child)
      W296.attach(catalog, target, part)
      wide = CrystalClick::WidePartProjection.precomputed_aggregate(
        W296::PROJECTION, "score", W296::GROUP_KEYS, W296.aggregates, rows_per_mark: 1)
      sibling = W296.transform(catalog, wide, compact: true, name: "all_9_9_0")
      table = W296.attach(catalog, target, sibling)
      W296.read_window(table, 2_u64, 3).should eq([W296::STATES[2], W296::STATES[0], W296::STATES[1]])
    end
  end

  it "rejects a different hidden group key in a Wide sibling before a Sum-only callback" do
    W296.with_catalog do |catalog, target|
      part = W296.transform(catalog, W296.child)
      W296.attach(catalog, target, part)
      wide = CrystalClick::WidePartProjection.precomputed_aggregate(
        W296::PROJECTION, "id", W296::GROUP_KEYS, W296.aggregates,
      )
      score = CrystalClick::WidePartColumn.binary_bulk(
        "score", CrystalClick::BinaryDataType.primitive("UInt64"),
        [W296::GROUP_KEYS.map { |key| CrystalClick::BinaryValue.uint64(key) }.to_a],
      )
      CrystalClick::WidePartWriter.write_uint64_columns(
        File.join(target, "all_7_7_0"), "id", W296::GROUP_KEYS, [score], projections: [wide])
      table = CrystalClick::OfflineCatalog.open(catalog.root)["lab"]["target"]
      yielded = false
      expect_raises(CrystalClick::CorruptPartError, /sibling|group key/i) do
        table.scan_projection_typed_window(W296::PROJECTION, ["sum(value)"], 0_u64, 1) { yielded = true }
      end
      yielded.should be_false
    end
  end
end
