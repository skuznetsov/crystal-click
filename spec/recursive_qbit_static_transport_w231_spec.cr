require "./spec_helper"
require "file_utils"

private class W231CountingPartStreamSource < CrystalClick::PartStreamSource
  @window_reads : Array(Tuple(String, Int32, Int32))

  def initialize(part_path : String)
    super(part_path)
    @window_reads = [] of Tuple(String, Int32, Int32)
  end

  def read_window(
    data_name : String,
    marks_name : String,
    first_mark : Int,
    mark_count : Int,
    prefix_size : Int = 0,
    budget : CrystalClick::CompressedStreamBudget = CrystalClick::CompressedStreamBudget.read_default,
  ) : CrystalClick::CompressedMarkWindow
    @window_reads << {data_name, first_mark.to_i32, mark_count.to_i32}
    super
  end

  def window_reads : Array(Tuple(String, Int32, Int32))
    @window_reads.dup
  end
end

private def w231_transport_qbit_value(
  type : CrystalClick::QBitType,
  seed : UInt8,
) : CrystalClick::BinaryValue
  raw = Bytes.new(type.raw_row_bytes) { |index| (seed.to_i + index).to_u8 }
  CrystalClick::BinaryValue.qbit(CrystalClick::QBitValue.new(type, raw))
end

private def w231_transport_array(
  type : CrystalClick::BinaryDataType,
  children : Array(CrystalClick::BinaryValue),
) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.array(type, children)
end

private class W231StaticScheduleFixture
  getter scratch : String
  getter part : String
  getter type : CrystalClick::BinaryDataType
  getter physical : CrystalClick::BinaryBulkPhysicalPlan
  getter sites : Array(CrystalClick::BinaryQBitRecursiveAdmission::StaticSite)
  getter source : W231CountingPartStreamSource
  getter grids : Hash(String, CrystalClick::CompressedMarkGrid)
  getter parent_rows : Array(UInt64)

  def initialize(
    @scratch : String,
    @part : String,
    @type : CrystalClick::BinaryDataType,
    @physical : CrystalClick::BinaryBulkPhysicalPlan,
    @sites : Array(CrystalClick::BinaryQBitRecursiveAdmission::StaticSite),
    @source : W231CountingPartStreamSource,
    @grids : Hash(String, CrystalClick::CompressedMarkGrid),
    @parent_rows : Array(UInt64),
  )
  end

  def validate!(
    codec_limits : CrystalClick::BinaryCodecLimits = CrystalClick::BinaryCodecLimits.default,
    transport_limits : CrystalClick::CompressedStreamLimits = CrystalClick::CompressedStreamLimits.new,
  ) : Nil
    CrystalClick::BinaryQBitStaticOccurrenceSchedule.validate!(
      @type,
      @sites,
      @physical,
      @source,
      @grids,
      @parent_rows,
      codec_limits,
      CrystalClick::CompressedStreamBudget.new(transport_limits),
    )
  end

  def cleanup : Nil
    FileUtils.rm_rf(@scratch)
  end
end

private def w231_static_schedule_fixture(
  prefix : String,
  type : CrystalClick::BinaryDataType,
  rows_by_mark : Array(Array(CrystalClick::BinaryValue)),
) : W231StaticScheduleFixture
  scratch = File.tempname(prefix)
  Dir.mkdir(scratch)
  begin
    part = File.join(scratch, "all_1_1_0")
    CrystalClick::WidePartWriter.write_uint64_qbit_bulk_part(
      part,
      "k",
      Slice[11_u64, 22_u64, 33_u64, 44_u64, 55_u64, 66_u64],
      "v",
      type,
      rows_by_mark,
      rows_per_mark: 2,
    )

    physical = CrystalClick::BinaryBulkPhysicalPlan.new(
      type,
      "v",
      CrystalClick::BinaryBulkProfile.single_stream,
    )
    sites = CrystalClick::BinaryBulkTypePlan.new(
      type,
      CrystalClick::BinaryBulkProfile.single_stream,
    ).qbit_static_sites
    source = W231CountingPartStreamSource.new(part)
    grids = Hash(String, CrystalClick::CompressedMarkGrid).new
    physical.stream_names.each do |role, _name|
      grids[role] = source.inspect_grid(
        physical.data_file_for(role, true),
        physical.marks_file_for(role, true),
        physical.prefix_size_for(role),
      )
    end
    parent_rows = grids.values.first?.try(&.rows_per_mark) ||
                  raise CrystalClick::CorruptPartError.new("fixture has no physical mark grid")
    parent_rows.should eq([2_u64, 2_u64, 2_u64])
    W231StaticScheduleFixture.new(scratch, part, type, physical, sites, source, grids, parent_rows)
  rescue ex
    FileUtils.rm_rf(scratch)
    raise ex
  end
end

private def w231_shared_array_tuple_fixture(prefix : String) : W231StaticScheduleFixture
  qbit_type = CrystalClick::QBitType.new("Int8", 3_u64)
  qbit = CrystalClick::BinaryDataType.qbit(qbit_type)
  tuple = CrystalClick::BinaryDataType.tuple(
    [qbit, qbit] of CrystalClick::BinaryDataType,
    ["left", "right"] of String,
  )
  array = CrystalClick::BinaryDataType.array(tuple)
  rows = [] of CrystalClick::BinaryValue
  child_counts = [2, 0, 3, 1, 0, 2]
  6.times do |row|
    children = [] of CrystalClick::BinaryValue
    child_counts[row].times do |child|
      children << CrystalClick::BinaryValue.tuple(
        tuple,
        [
          w231_transport_qbit_value(qbit_type, (0x10 + row * 7 + child).to_u8),
          w231_transport_qbit_value(qbit_type, (0x40 + row * 11 + child).to_u8),
        ] of CrystalClick::BinaryValue,
      )
    end
    rows << w231_transport_array(array, children)
  end
  rows_by_mark = [rows[0, 2], rows[2, 2], rows[4, 2]] of Array(CrystalClick::BinaryValue)
  w231_static_schedule_fixture(prefix, array, rows_by_mark)
end

private def w231_independent_array_tuple_fixture(prefix : String) : W231StaticScheduleFixture
  left_qbit_type = CrystalClick::QBitType.new("Int8", 3_u64)
  right_qbit_type = CrystalClick::QBitType.new("Float32", 3_u64)
  left_qbit = CrystalClick::BinaryDataType.qbit(left_qbit_type)
  right_qbit = CrystalClick::BinaryDataType.qbit(right_qbit_type)
  left_array = CrystalClick::BinaryDataType.array(left_qbit)
  right_array = CrystalClick::BinaryDataType.array(right_qbit)
  tuple = CrystalClick::BinaryDataType.tuple(
    [left_array, right_array] of CrystalClick::BinaryDataType,
    ["left", "right"] of String,
  )
  left_counts = [2, 0, 1, 3, 0, 0]
  right_counts = [0, 2, 0, 1, 1, 2]
  rows = [] of CrystalClick::BinaryValue
  6.times do |row|
    rows << CrystalClick::BinaryValue.tuple(
      tuple,
      [
        w231_transport_array(
          left_array,
          Array(CrystalClick::BinaryValue).new(left_counts[row]) do |child|
            w231_transport_qbit_value(left_qbit_type, (0x20 + row * 5 + child).to_u8)
          end,
        ),
        w231_transport_array(
          right_array,
          Array(CrystalClick::BinaryValue).new(right_counts[row]) do |child|
            w231_transport_qbit_value(right_qbit_type, (0x60 + row * 9 + child).to_u8)
          end,
        ),
      ] of CrystalClick::BinaryValue,
    )
  end
  rows_by_mark = [rows[0, 2], rows[2, 2], rows[4, 2]] of Array(CrystalClick::BinaryValue)
  w231_static_schedule_fixture(prefix, tuple, rows_by_mark)
end

describe "W231 static QBit occurrence-schedule transport" do
  it "bounds a direct schedule call's recursive type before any lane reads" do
    fixture = w231_shared_array_tuple_fixture("crystal-click-w231-qbit-type-guard-")
    begin
      qbit = CrystalClick::BinaryDataType.qbit(CrystalClick::QBitType.new("Int8", 3_u64))
      deep_type = qbit
      80.times { deep_type = CrystalClick::BinaryDataType.array(deep_type) }
      limits = CrystalClick::BinaryCodecLimits.new(
        max_depth: 64,
        max_nodes: 4_096,
        max_elements: 1_000_000,
        max_bytes: 1_048_576,
      )

      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryQBitStaticOccurrenceSchedule.validate!(
          deep_type,
          fixture.sites,
          fixture.physical,
          fixture.source,
          fixture.grids,
          fixture.parent_rows,
          limits,
          CrystalClick::CompressedStreamBudget.new(CrystalClick::CompressedStreamLimits.new),
        )
      end
      fixture.source.window_reads.should be_empty
    ensure
      fixture.cleanup
    end
  end

  it "reads one shared Array size lane once for two distinct leaf sites" do
    fixture = w231_shared_array_tuple_fixture("crystal-click-w231-shared-qbit-size-")
    begin
      fixture.sites.size.should eq(2)
      fixture.sites[0].size_roles.should eq(["root.sizes"])
      fixture.sites[1].size_roles.should eq(["root.sizes"])

      fixture.validate!

      reads = fixture.source.window_reads
      reads.size.should eq(1)
      reads[0][0].should eq(fixture.physical.data_file_for("root.sizes", true))
      reads[0][1].should eq(0)
      reads[0][2].should eq(fixture.parent_rows.size)
    ensure
      fixture.cleanup
    end
  end

  it "reads independent sibling size lanes once each and charges aggregate result bytes" do
    fixture = w231_independent_array_tuple_fixture("crystal-click-w231-independent-qbit-sizes-")
    begin
      fixture.sites.size.should eq(2)
      fixture.sites.map(&.size_roles).should eq([
        ["root.field.0.sizes"],
        ["root.field.1.sizes"],
      ])

      error = expect_raises(CrystalClick::CorruptPartError) do
        fixture.validate!(
          transport_limits: CrystalClick::CompressedStreamLimits.new(max_result_bytes: 95),
        )
      end
      error.message.not_nil!.should contain("result-byte")
      reads = fixture.source.window_reads
      reads.size.should eq(1)
      reads[0][1].should eq(0)
      reads[0][2].should eq(fixture.parent_rows.size)
    ensure
      fixture.cleanup
    end
  end

  it "preflights aggregate multi-site schedule workspace before reading size lanes" do
    fixture = w231_independent_array_tuple_fixture("crystal-click-w231-qbit-workspace-")
    begin
      # Two unique size lanes plus the two per-mark accumulators require
      # (2 + 2) * 3 * 8 = 96 logical bytes before any lane read.
      limits = CrystalClick::BinaryCodecLimits.new(
        max_depth: 64,
        max_nodes: 4_096,
        max_elements: 1_000_000,
        max_bytes: 95,
      )
      error = expect_raises(CrystalClick::CorruptPartError) do
        fixture.validate!(codec_limits: limits)
      end
      error.message.not_nil!.should contain("schedule workspace")
      fixture.source.window_reads.should be_empty
    ensure
      fixture.cleanup
    end
  end
end
