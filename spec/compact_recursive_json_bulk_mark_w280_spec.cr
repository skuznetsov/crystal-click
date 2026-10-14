require "./spec_helper"
require "file_utils"
require "./support/compact_part_writer_w280_fixture"

class W280BulkMarkWorkspaceEstimatorProbe
  AMPLIFICATION = 1_000_000_u64

  @@enabled = false

  def self.enable! : Nil
    @@enabled = true
  end

  def self.disable! : Nil
    @@enabled = false
  end

  def self.enabled? : Bool
    @@enabled
  end
end

# Make an actual detached Bulk lane footprint conspicuous to the reader's
# normal workspace observer. The observer itself remains unmodified.
class CrystalClick::CompactRecursiveJsonColumnReader
  # Spec-only bridge to the private lane decoder, retaining the caller's
  # operation budget for cumulative metadata accounting.
  def w280_decode_uint64_lane_for_test(
    bytes : Bytes,
    count : UInt64,
    label : String,
    budget : BinaryCodecBudget,
  ) : Array(UInt64)
    decode_uint64_lane(bytes, count, label, budget)
  end

  private def binary_streams_workspace_bytes(streams : BinaryBulkStreams) : UInt64
    bytes = previous_def(streams)
    if W280BulkMarkWorkspaceEstimatorProbe.enabled? &&
       streams.has_role?("root.sizes") && streams.has_role?("root.elements.data")
      checked_add(bytes, W280BulkMarkWorkspaceEstimatorProbe::AMPLIFICATION)
    else
      bytes
    end
  end
end

private def w280b_write_empty_bulk_part : Tuple(String, String, CrystalClick::StorageColumnSchema)
  fixture = CompactPartWriterW280Fixture
  case_name = :positional_uint8
  schema = fixture.schema(case_name)
  parent = File.tempname("crystal-click-w280-bulk-mark-")
  part_path = File.join(parent, "all_1_1_0")
  Dir.mkdir(parent)
  begin
    column = fixture.column(case_name)
    CrystalClick::CompactPartWriter.write_uint64_columns(
      part_path,
      CompactPartWriterW280Fixture::KEY_NAME,
      fixture.keys,
      [column] of CrystalClick::CompactPartColumn,
      rows_per_mark: CompactPartWriterW280Fixture::ROWS_PER_MARK,
      frame_bytes: CompactPartWriterW280Fixture::FRAME_BYTES,
      mark_format: CrystalClick::CompactMarkFormat::Mrk3,
    ).should eq(part_path)

    {parent, part_path, schema}
  rescue ex
    FileUtils.rm_rf(parent)
    raise ex
  end
end

describe CrystalClick::CompactRecursiveJsonBulkMark do
  it "preflights the exact packaging owner and element census without charging wire bytes" do
    limits = CrystalClick::BinaryCodecLimits.new(
      max_depth: CrystalClick::BinaryCodecLimits::DEFAULT_MAX_DEPTH,
      max_nodes: 13,
      max_elements: 33,
      max_bytes: 0,
    )
    budget = CrystalClick::BinaryCodecBudget.new(limits)

    CrystalClick::CompactRecursiveJsonBulkMark.preflight_packaging!(2, 7_u64, 5_u64, budget)

    budget.node_count.should eq(13_i64)     # 3 fixed + 5 per role
    budget.element_count.should eq(33_i64)  # 8 per role + lane bytes + two copied key rosters
    budget.wire_byte_count.should eq(0_i64) # parent wire input is charged elsewhere
  end

  it "rejects a one-below node or edge budget before charging either dimension" do
    one_below_nodes = CrystalClick::BinaryCodecBudget.new(
      CrystalClick::BinaryCodecLimits.new(
        max_depth: CrystalClick::BinaryCodecLimits::DEFAULT_MAX_DEPTH,
        max_nodes: 12,
        max_elements: 33,
        max_bytes: 0,
      ),
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::CompactRecursiveJsonBulkMark.preflight_packaging!(2, 7_u64, 5_u64, one_below_nodes)
    end
    one_below_nodes.node_count.should eq(0_i64)
    one_below_nodes.element_count.should eq(0_i64)
    one_below_nodes.wire_byte_count.should eq(0_i64)

    one_below_edges = CrystalClick::BinaryCodecBudget.new(
      CrystalClick::BinaryCodecLimits.new(
        max_depth: CrystalClick::BinaryCodecLimits::DEFAULT_MAX_DEPTH,
        max_nodes: 13,
        max_elements: 32,
        max_bytes: 0,
      ),
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::CompactRecursiveJsonBulkMark.preflight_packaging!(2, 7_u64, 5_u64, one_below_edges)
    end
    one_below_edges.node_count.should eq(0_i64)
    one_below_edges.element_count.should eq(0_i64)
    one_below_edges.wire_byte_count.should eq(0_i64)
  end
end

describe CrystalClick::CompactRecursiveJsonColumnReader do
  it "charges every UInt64 metadata count cumulatively before allocating its lane" do
    parent, part_path, schema = w280b_write_empty_bulk_part
    begin
      reader = CrystalClick::CompactRecursiveJsonColumnReader.open(
        part_path,
        CompactPartWriterW280Fixture::COLUMN_NAME,
        schema,
      )
      limits = CrystalClick::BinaryCodecLimits.new(
        max_depth: CrystalClick::BinaryCodecLimits::DEFAULT_MAX_DEPTH,
        max_nodes: 4,
        max_elements: 4,
        max_bytes: CrystalClick::BinaryCodecLimits::DEFAULT_MAX_BYTES,
      )
      budget = CrystalClick::BinaryCodecBudget.new(limits)
      first = reader.w280_decode_uint64_lane_for_test(
        Bytes.new(16),
        2_u64,
        "W280 UInt64 metadata lane",
        budget,
      )

      first.should eq([0_u64, 0_u64])
      budget.node_count.should eq(2_i64)
      budget.element_count.should eq(2_i64)
      budget.wire_byte_count.should eq(0_i64)

      second = reader.w280_decode_uint64_lane_for_test(
        Bytes.new(16),
        2_u64,
        "W280 UInt64 metadata lane",
        budget,
      )
      second.should eq([0_u64, 0_u64])
      budget.node_count.should eq(4_i64)
      budget.element_count.should eq(4_i64)
      budget.wire_byte_count.should eq(0_i64)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a one-below node metadata budget before allocating or partially charging" do
    parent, part_path, schema = w280b_write_empty_bulk_part
    begin
      reader = CrystalClick::CompactRecursiveJsonColumnReader.open(
        part_path,
        CompactPartWriterW280Fixture::COLUMN_NAME,
        schema,
      )
      limits = CrystalClick::BinaryCodecLimits.new(
        max_depth: CrystalClick::BinaryCodecLimits::DEFAULT_MAX_DEPTH,
        max_nodes: 1,
        max_elements: 2,
        max_bytes: CrystalClick::BinaryCodecLimits::DEFAULT_MAX_BYTES,
      )
      budget = CrystalClick::BinaryCodecBudget.new(limits)

      expect_raises(CrystalClick::CorruptPartError) do
        reader.w280_decode_uint64_lane_for_test(
          Bytes.new(16),
          2_u64,
          "W280 UInt64 metadata lane",
          budget,
        )
      end
      budget.node_count.should eq(0_i64)
      budget.element_count.should eq(0_i64)
      budget.wire_byte_count.should eq(0_i64)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a one-below element metadata budget before allocating or partially charging" do
    parent, part_path, schema = w280b_write_empty_bulk_part
    begin
      reader = CrystalClick::CompactRecursiveJsonColumnReader.open(
        part_path,
        CompactPartWriterW280Fixture::COLUMN_NAME,
        schema,
      )
      limits = CrystalClick::BinaryCodecLimits.new(
        max_depth: CrystalClick::BinaryCodecLimits::DEFAULT_MAX_DEPTH,
        max_nodes: 2,
        max_elements: 1,
        max_bytes: CrystalClick::BinaryCodecLimits::DEFAULT_MAX_BYTES,
      )
      budget = CrystalClick::BinaryCodecBudget.new(limits)

      expect_raises(CrystalClick::CorruptPartError) do
        reader.w280_decode_uint64_lane_for_test(
          Bytes.new(16),
          2_u64,
          "W280 UInt64 metadata lane",
          budget,
        )
      end
      budget.node_count.should eq(0_i64)
      budget.element_count.should eq(0_i64)
      budget.wire_byte_count.should eq(0_i64)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "observes staged Bulk streams and decoded values before stream release" do
    parent, part_path, schema = w280b_write_empty_bulk_part
    begin
      reader = CrystalClick::CompactRecursiveJsonColumnReader.open(
        part_path,
        CompactPartWriterW280Fixture::COLUMN_NAME,
        schema,
      )
      observations = [] of UInt64
      observer = ->(bytes : UInt64) do
        observations << bytes
        nil
      end

      W280BulkMarkWorkspaceEstimatorProbe.enable!
      reader.validate_complete_schedule(observer)

      # Existing callbacks: initial retained state, physical window, one
      # post-mark snapshot per mark, and final prepared state. The new paired
      # callbacks add stream-only and pre-clear stream+decoded-tree snapshots.
      mark_count = CompactPartWriterW280Fixture::MARK_COUNT
      observations.size.should eq(2 + 3 * mark_count + 1)
      mark_count.times do |mark_index|
        stream_only = observations[2 + mark_index * 3]
        streams_and_values = observations[3 + mark_index * 3]
        after_release = observations[4 + mark_index * 3]

        stream_only.should be > W280BulkMarkWorkspaceEstimatorProbe::AMPLIFICATION
        streams_and_values.should be > stream_only
        stream_only.should be > after_release
      end
    ensure
      W280BulkMarkWorkspaceEstimatorProbe.disable!
      FileUtils.rm_rf(parent)
    end
  end
end
