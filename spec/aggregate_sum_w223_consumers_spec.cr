require "./spec_helper"
require "./support/projection_checksum_fixture"
require "file_utils"

private def w223c_type : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.aggregate_function(
    "sum",
    CrystalClick::BinaryDataType.primitive("UInt64")
  )
end

private def w223c_u64_bytes(value : UInt64) : Bytes
  bytes = Bytes.new(8, 0_u8)
  8.times { |index| bytes[index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
  bytes
end

private def w223c_granules(
  type : CrystalClick::BinaryDataType,
  state_values : Array(UInt64),
  rows_per_mark : Int32 = 2,
) : Array(Array(CrystalClick::BinaryValue))
  values = state_values.map do |state|
    CrystalClick::BinaryValue.aggregate_function_state(type, w223c_u64_bytes(state))
  end
  granules = [] of Array(CrystalClick::BinaryValue)
  start = 0
  while start < values.size
    count = {rows_per_mark, values.size - start}.min
    granule = [] of CrystalClick::BinaryValue
    count.times { |offset| granule << values[start + offset] }
    granules << granule
    start += count
  end
  granules
end

private def w223c_write_part(
  destination : String,
  type : CrystalClick::BinaryDataType,
  state_values : Array(UInt64),
  rows_per_mark : Int32 = 2,
) : String
  keys = Array(UInt64).new(state_values.size) { |index| 7_u64 + index.to_u64 * 11_u64 }
  CrystalClick::WidePartWriter.write_uint64_and_aggregate_function_part(
    destination,
    "pk",
    keys.to_unsafe.to_slice(keys.size),
    "v",
    type,
    w223c_granules(type, state_values, rows_per_mark),
    rows_per_mark: rows_per_mark
  )
end

private def w223c_part_candidate(path : String, rows : UInt64) : CrystalClick::OfflinePartCandidate
  name = "all_1_1_0"
  info = CrystalClick::MergeTreePartInfo.parse(name).not_nil!
  CrystalClick::OfflinePartCandidate.new(name, path, info, rows)
end

private def w223c_offline_table(
  type_name : String,
  path : String,
  rows : UInt64,
) : CrystalClick::OfflineTable
  CrystalClick::OfflineTable.new(
    "w223_sum_events",
    "w223-sum-fixture",
    "MergeTree",
    [
      CrystalClick::OfflineColumn.new("pk", "UInt64"),
      CrystalClick::OfflineColumn.new("v", type_name),
    ] of CrystalClick::OfflineColumn,
    [w223c_part_candidate(path, rows)] of CrystalClick::OfflinePartCandidate
  )
end

private def w223c_state_bytes(values : Array(CrystalClick::BinaryValue)) : Array(Bytes)
  values.map(&.aggregate_function_state_bytes)
end

private def w223c_parent(&)
  parent = File.tempname("crystal-click-w223-aggregate-consumer-")
  Dir.mkdir(parent)
  begin
    yield parent
  ensure
    FileUtils.rm_rf(parent)
  end
end

describe "W223 AggregateFunction root consumers" do
  it "returns exact Sum BinaryValues from borrowed table batches and owned offline values" do
    type = w223c_type
    type.name.should eq("AggregateFunction(sum, UInt64)")
    states = [0_u64, 42_u64, 128_u64, 16_384_u64, UInt64::MAX]
    expected = states.map { |state| w223c_u64_bytes(state) }

    w223c_parent do |parent|
      part_path = File.join(parent, "all_1_1_0")
      w223c_write_part(part_path, type, states).should eq(part_path)

      table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["pk", "v"])
      table.column_types.should eq([{"pk", "UInt64"}, {"v", type.name}])
      table.total_row_count.should eq(5_u64)

      observed = [] of CrystalClick::BinaryValue
      observed_keys = [] of UInt64
      table.scan_typed(batch_rows: 2) do |batch|
        batch.column_type_for("v").should eq(type.name)
        values = batch.binary_bulk_values_for("v")
        values.size.should eq(batch.values_for("pk").size)
        observed.concat(values.to_a)
        observed_keys.concat(batch.values_for("pk").to_a)

        # AggregateFunction uses the generic BinaryValue path. The legacy
        # Count accessor must not reinterpret the same eight state bytes.
        expect_raises(CrystalClick::UnsupportedFormatError) do
          batch.aggregate_count_states_for("v", CrystalClick::BinaryDataType.aggregate_count)
        end
      end

      observed.size.should eq(states.size)
      observed.map(&.type).should eq(Array.new(states.size, type))
      w223c_state_bytes(observed).should eq(expected)
      observed_keys.size.should eq(states.size)

      offline = w223c_offline_table(type.name, part_path, states.size.to_u64)
      owned = offline["v"].values(max_rows: states.size.to_u64).map do |value|
        value.as(CrystalClick::BinaryValue)
      end
      owned.map(&.type).should eq(Array.new(states.size, type))
      w223c_state_bytes(owned).should eq(expected)

      copy = owned[1].aggregate_function_state_bytes
      copy.fill(0_u8)
      owned[1].aggregate_function_state_bytes.should eq(expected[1])
      expect_raises(CrystalClick::BoundsError) do
        offline["v"].values(max_rows: states.size.to_u64 - 1_u64)
      end
    end
  end

  it "binds a synthetic projection read to the selected child path and its own row grid" do
    type = w223c_type
    parent_states = [11_u64, 22_u64]
    projection_states = [101_u64, 202_u64, 303_u64]

    w223c_parent do |root|
      parent_part = File.join(root, "all_1_1_0")
      w223c_write_part(parent_part, type, parent_states).should eq(parent_part)
      projection_path = File.join(parent_part, "selected.proj")
      w223c_write_part(projection_path, type, projection_states).should eq(projection_path)
      ProjectionChecksumFixture.rebind!(parent_part, "selected")

      table = CrystalClick::WidePartTable.open_selected_projection_typed(
        [parent_part],
        "selected",
        ["v"]
      )
      table.total_row_count.should eq(3_u64)
      table.part_mark_row_counts.should eq([[2_u64, 1_u64]])

      selected = [] of CrystalClick::BinaryValue
      table.scan_typed(batch_rows: 2) do |batch|
        selected.concat(batch.binary_bulk_values_for("v").to_a)
      end
      selected.map(&.type).should eq(Array.new(projection_states.size, type))
      w223c_state_bytes(selected).should eq(projection_states.map { |state| w223c_u64_bytes(state) })
      w223c_state_bytes(selected).should_not eq(parent_states.map { |state| w223c_u64_bytes(state) })
    end
  end
end
