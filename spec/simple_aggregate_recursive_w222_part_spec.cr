require "./spec_helper"
require "file_utils"
require "./support/simple_aggregate_recursive_w222_values"

private def w222_recursive_write_part(
  destination : String,
  type : CrystalClick::BinaryDataType,
  granules : Array(Array(CrystalClick::BinaryValue)),
) : String
  CrystalClick::WidePartWriter.write_uint64_simple_aggregate_bulk_part(
    destination,
    "pk",
    Slice[101_u64, 102_u64, 103_u64, 104_u64, 105_u64],
    "v",
    type,
    granules,
    rows_per_mark: 2,
    frame_bytes: 64,
  )
end

private def with_w222_recursive_part_directory(& : String ->)
  root = File.tempname("crystal-click-w222-recursive-saf-part-")
  Dir.mkdir(root)
  yield root
ensure
  FileUtils.rm_rf(root) if root && Dir.exists?(root)
end

describe "W222 SimpleAggregateFunction recursive static paired parts" do
  CrystalClick::SimpleAggregateRecursiveW222Values::SOURCES.each do |source|
    it "round-trips #{source} through generic staged writer and mark windows" do
      type = CrystalClick::SimpleAggregateRecursiveW222Values.type(source)
      type.name.should eq(source)
      granules = CrystalClick::SimpleAggregateRecursiveW222Values.granules(type)
      expected = CrystalClick::SimpleAggregateRecursiveW222Values.signature_grid(granules)

      with_w222_recursive_part_directory do |parent|
        part = File.join(parent, "part")
        w222_recursive_write_part(part, type, granules).should eq(part)

        reader = CrystalClick::BinaryBulkColumnReader.open(part, "v", type)
        reader.schema_declaration.should eq(source)
        reader.source_declaration.should eq(source)
        reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
        reader.physical_stream_names.sort.should eq(
          CrystalClick::BinaryBulkPhysicalPlan.new(type, "v").stream_names.values.sort
        )
        # SAF is nominal, but its physical role roster must be the exact
        # already-owned child roster rather than a per-product lane scheme.
        reader.physical_stream_names.sort.should eq(
          CrystalClick::BinaryBulkPhysicalPlan.new(type.child_at(0), "v").stream_names.values.sort
        )
        reader.read_marks(0, 0).should be_empty
        reader.read_marks(0, 3).map do |mark|
          mark.map { |row| CrystalClick::SimpleAggregateRecursiveW222Values.signature(row) }
        end.should eq(expected)
        reader.read_marks(1, 1).map do |mark|
          mark.map { |row| CrystalClick::SimpleAggregateRecursiveW222Values.signature(row) }
        end.should eq([expected[1]])
        reader.read_marks(2, 1).map do |mark|
          mark.map { |row| CrystalClick::SimpleAggregateRecursiveW222Values.signature(row) }
        end.should eq([expected[2]])
        reader.read_marks(reader.mark_count, 0).should be_empty
      end
    end
  end

  it "rejects a different SAF function with identical Tuple-child lanes before decode" do
    left_source = "SimpleAggregateFunction(sumMap, Tuple(Array(Int32), Array(Int64)))"
    right_source = "SimpleAggregateFunction(minMap, Tuple(Array(Int32), Array(Int64)))"
    left_type = CrystalClick::SimpleAggregateRecursiveW222Values.type(left_source)
    right_type = CrystalClick::SimpleAggregateRecursiveW222Values.type(right_source)
    left_lanes = CrystalClick::BinaryBulkPhysicalPlan.new(left_type, "v").stream_names.values.sort
    right_lanes = CrystalClick::BinaryBulkPhysicalPlan.new(right_type, "v").stream_names.values.sort
    left_lanes.should eq(right_lanes)

    granules = CrystalClick::SimpleAggregateRecursiveW222Values.granules(left_type)
    with_w222_recursive_part_directory do |parent|
      part = File.join(parent, "sum-map")
      w222_recursive_write_part(part, left_type, granules)
      expect_raises(CrystalClick::CorruptPartError, /source declaration differs/) do
        CrystalClick::BinaryBulkColumnReader.open(part, "v", right_type)
      end
    end
  end

  it "rejects a different canonical SAF parameter with identical Array-child lanes" do
    left_source = "SimpleAggregateFunction(groupArrayLastArray(5), Array(UInt64))"
    right_source = "SimpleAggregateFunction(groupArrayLastArray(6), Array(UInt64))"
    left_type = CrystalClick::SimpleAggregateRecursiveW222Values.type(left_source)
    right_type = CrystalClick::SimpleAggregateRecursiveW222Values.type(right_source)
    left_type.name.should eq(left_source)
    right_type.name.should eq(right_source)
    CrystalClick::BinaryBulkPhysicalPlan.new(left_type, "v").stream_names.values.sort.should eq(
      CrystalClick::BinaryBulkPhysicalPlan.new(right_type, "v").stream_names.values.sort
    )

    granules = CrystalClick::SimpleAggregateRecursiveW222Values.granules(left_type)
    with_w222_recursive_part_directory do |parent|
      part = File.join(parent, "group-array-last")
      w222_recursive_write_part(part, left_type, granules)
      expect_raises(CrystalClick::CorruptPartError, /source declaration differs/) do
        CrystalClick::BinaryBulkColumnReader.open(part, "v", right_type)
      end
    end
  end

  it "keeps unqualified recursive stop-sites and outer Nullable composites outside the static route" do
    blocked = [
      "SimpleAggregateFunction(anyLast, Array(Nullable(Int32)))",
      "SimpleAggregateFunction(anyLast, Array(LowCardinality(Int32)))",
      "SimpleAggregateFunction(anyLast, Array(Dynamic))",
      "SimpleAggregateFunction(anyLast, Array(Variant(UInt64, String)))",
      "SimpleAggregateFunction(anyLast, Array(JSON))",
      "SimpleAggregateFunction(anyLast, Array(QBit(UInt8, 2)))",
      "SimpleAggregateFunction(anyLast, Nested(x UInt64))",
      "Nullable(SimpleAggregateFunction(groupArrayArray, Array(Int32)))",
    ]
    blocked.each do |source|
      CrystalClick::WidePart.supports_simple_aggregate_bulk_type?(source).should be_false
    end
  end

  it "rejects a source-admitted recursive Nullable stop-site at declaration, reader, and writer boundaries" do
    source = "SimpleAggregateFunction(anyLast, Array(Nullable(Int32)))"
    logical_type = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(source)
    logical_type.should_not be_nil
    if type = logical_type
      CrystalClick::SimpleAggregateBulkColumnDeclaration.parse(source).should be_nil
      expect_raises(CrystalClick::UnsupportedFormatError, /static physical profile/) do
        CrystalClick::SimpleAggregateBulkColumnDeclaration.new(type)
      end

      with_w222_recursive_part_directory do |parent|
        destination = File.join(parent, "rejected")
        one_empty_granule = [] of CrystalClick::BinaryValue
        expect_raises(CrystalClick::UnsupportedFormatError, /static physical profile/) do
          CrystalClick::WidePartWriter.write_uint64_simple_aggregate_bulk_part(
            destination,
            "pk",
            Slice[101_u64],
            "v",
            type,
            [one_empty_granule] of Array(CrystalClick::BinaryValue),
            rows_per_mark: 1,
          )
        end
        File.exists?(destination).should be_false
        Dir.children(parent).should be_empty

        # Direct BinaryBulk reader callers bypass the public table adapter;
        # the shared root-SAF policy must reject before touching the path.
        expect_raises(CrystalClick::UnsupportedFormatError, /static physical profile/) do
          CrystalClick::BinaryBulkColumnReader.open(
            File.join(parent, "missing-invalid"), "v", type
          )
        end

        scalar_controls = [
          "SimpleAggregateFunction(anyLast_respect_nulls, UInt8)",
          "SimpleAggregateFunction(any_respect_nulls, Nullable(UInt8))",
          "Nullable(SimpleAggregateFunction(anyLast_respect_nulls, UInt8))",
        ] of String
        scalar_controls.each_with_index do |control, index|
          control_type = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(control).not_nil!
          expect_raises(CrystalClick::CorruptPartError, /part path is not a directory/) do
            CrystalClick::BinaryBulkColumnReader.open(
              File.join(parent, "missing-scalar-#{index}"), "v", control_type
            )
          end
        end
      end
    end
  end

  it "exposes recursively stored values through selected public table batches" do
    source = CrystalClick::SimpleAggregateRecursiveW222Values::SOURCES[0]
    type = CrystalClick::SimpleAggregateRecursiveW222Values.type(source)
    granules = CrystalClick::SimpleAggregateRecursiveW222Values.granules(type)
    expected = granules.flatten.map do |row|
      CrystalClick::SimpleAggregateRecursiveW222Values.signature(row)
    end

    with_w222_recursive_part_directory do |parent|
      part = File.join(parent, "all_1_1_0")
      w222_recursive_write_part(part, type, granules)

      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "v"])
      observed = [] of String
      observed_schedule = [] of Tuple(Int32, UInt64, Int32)
      table.scan_typed(batch_rows: 2) do |batch|
        rows = batch.binary_bulk_values_for("v")
        observed_schedule << {batch.mark_index, batch.part_row_offset, rows.size}
        rows.each do |row|
          observed << CrystalClick::SimpleAggregateRecursiveW222Values.signature(row)
        end
      end
      observed.should eq(expected)
      observed_schedule.should eq([
        {0, 0_u64, 2},
        {1, 2_u64, 2},
        {2, 4_u64, 1},
      ])
    end
  end

  it "materializes a recursive SAF Map through OfflineColumn.values" do
    source = CrystalClick::SimpleAggregateRecursiveW222Values::SOURCES[4]
    type = CrystalClick::SimpleAggregateRecursiveW222Values.type(source)
    granules = CrystalClick::SimpleAggregateRecursiveW222Values.granules(type)
    expected = granules.flatten.map do |row|
      CrystalClick::SimpleAggregateRecursiveW222Values.signature(row)
    end

    with_w222_recursive_part_directory do |parent|
      part = File.join(parent, "all_1_1_0")
      w222_recursive_write_part(part, type, granules)
      info = CrystalClick::MergeTreePartInfo.parse("all_1_1_0").not_nil!
      candidate = CrystalClick::OfflinePartCandidate.new("all_1_1_0", part, info, 5_u64)
      table = CrystalClick::OfflineTable.new(
        "w222_events",
        "w222-recursive-fixture",
        "MergeTree",
        [
          CrystalClick::OfflineColumn.new("pk", "UInt64"),
          CrystalClick::OfflineColumn.new("v", source),
        ] of CrystalClick::OfflineColumn,
        [candidate] of CrystalClick::OfflinePartCandidate
      )
      observed = table["v"].values(max_rows: 5_u64).map do |value|
        value.as(CrystalClick::BinaryValue)
      end
      observed.map do |row|
        CrystalClick::SimpleAggregateRecursiveW222Values.signature(row)
      end.should eq(expected)
    end
  end
end
