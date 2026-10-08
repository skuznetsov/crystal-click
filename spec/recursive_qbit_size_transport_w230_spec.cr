require "./spec_helper"
require "file_utils"

private class W230CountingPartStreamSource < CrystalClick::PartStreamSource
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

private def w230_size_transport_qbit_value(
  type : CrystalClick::QBitType,
  seed : UInt8,
) : CrystalClick::BinaryValue
  raw = Bytes.new(type.raw_row_bytes) { |index| (seed.to_i + index).to_u8 }
  CrystalClick::BinaryValue.qbit(CrystalClick::QBitValue.new(type, raw))
end

private def w230_size_transport_array(
  type : CrystalClick::BinaryDataType,
  children : Array(CrystalClick::BinaryValue),
) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.array(type, children)
end

private class W230SizeTransportScheduleFixture
  getter scratch : String
  getter physical : CrystalClick::BinaryBulkPhysicalPlan
  getter site : CrystalClick::BinaryQBitRecursiveAdmission::StaticArraySite
  getter source : W230CountingPartStreamSource
  getter grids : Hash(String, CrystalClick::CompressedMarkGrid)
  getter parent_rows : Array(UInt64)
  getter type : CrystalClick::BinaryDataType

  def initialize(
    @scratch : String,
    @physical : CrystalClick::BinaryBulkPhysicalPlan,
    @site : CrystalClick::BinaryQBitRecursiveAdmission::StaticArraySite,
    @source : W230CountingPartStreamSource,
    @grids : Hash(String, CrystalClick::CompressedMarkGrid),
    @parent_rows : Array(UInt64),
    @type : CrystalClick::BinaryDataType,
  )
  end

  def validate!(
    codec_limits : CrystalClick::BinaryCodecLimits = CrystalClick::BinaryCodecLimits.default,
    transport_limits : CrystalClick::CompressedStreamLimits = CrystalClick::CompressedStreamLimits.new,
  ) : Nil
    CrystalClick::BinaryQBitArrayOccurrenceSchedule.validate!(
      @site,
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

private def w230_size_transport_schedule_fixture(
  prefix : String,
  extra_early_inner : Bool = false,
) : W230SizeTransportScheduleFixture
  qbit_type = CrystalClick::QBitType.new("Int8", 3_u64)
  qbit_descriptor = CrystalClick::BinaryDataType.qbit(qbit_type)
  inner_type = CrystalClick::BinaryDataType.array(qbit_descriptor) ||
               raise CrystalClick::UnsupportedFormatError.new("fixture QBit Array is not admitted")
  outer_type = CrystalClick::BinaryDataType.array(inner_type) ||
               raise CrystalClick::UnsupportedFormatError.new("fixture nested QBit Array is not admitted")

  first = w230_size_transport_qbit_value(qbit_type, 0x10_u8)
  second = w230_size_transport_qbit_value(qbit_type, 0x20_u8)
  third = w230_size_transport_qbit_value(qbit_type, 0x30_u8)
  fourth = w230_size_transport_qbit_value(qbit_type, 0x40_u8)
  fifth = w230_size_transport_qbit_value(qbit_type, 0x50_u8)
  first_inner = w230_size_transport_array(inner_type, [first, second] of CrystalClick::BinaryValue)
  late_first_inner = w230_size_transport_array(inner_type, [third] of CrystalClick::BinaryValue)
  late_second_inner = w230_size_transport_array(inner_type, [fourth, fifth] of CrystalClick::BinaryValue)
  empty_inner = w230_size_transport_array(inner_type, [] of CrystalClick::BinaryValue)
  empty_outer = w230_size_transport_array(outer_type, [] of CrystalClick::BinaryValue)
  first_outer = if extra_early_inner
                  w230_size_transport_array(
                    outer_type,
                    [first_inner, empty_inner] of CrystalClick::BinaryValue,
                  )
                else
                  w230_size_transport_array(outer_type, [first_inner] of CrystalClick::BinaryValue)
                end
  rows_by_mark = [
    [first_outer, empty_outer] of CrystalClick::BinaryValue,
    [empty_outer, empty_outer] of CrystalClick::BinaryValue,
    [w230_size_transport_array(outer_type, [late_first_inner, late_second_inner] of CrystalClick::BinaryValue),
     empty_outer] of CrystalClick::BinaryValue,
  ] of Array(CrystalClick::BinaryValue)

  scratch = File.tempname(prefix)
  Dir.mkdir(scratch)
  begin
    part = File.join(scratch, "all_1_1_0")
    CrystalClick::WidePartWriter.write_uint64_qbit_bulk_part(
      part,
      "k",
      Slice[11_u64, 22_u64, 33_u64, 44_u64, 55_u64, 66_u64],
      "v",
      outer_type,
      rows_by_mark,
      rows_per_mark: 2,
    )

    physical = CrystalClick::BinaryBulkPhysicalPlan.new(
      outer_type,
      "v",
      CrystalClick::BinaryBulkProfile.single_stream,
    )
    site = CrystalClick::BinaryBulkTypePlan.new(
      outer_type,
      CrystalClick::BinaryBulkProfile.single_stream,
    ).qbit_array_site || raise CrystalClick::CorruptPartError.new("fixture has no recursive QBit site")
    source = W230CountingPartStreamSource.new(part)
    grids = Hash(String, CrystalClick::CompressedMarkGrid).new
    physical.stream_names.each do |role, _name|
      grids[role] = source.inspect_grid(
        physical.data_file_for(role, true),
        physical.marks_file_for(role, true),
        physical.prefix_size_for(role),
      )
    end
    parent_rows = grids[site.array_size_roles.first].rows_per_mark
    parent_rows.should eq([2_u64, 2_u64, 2_u64])
    nested_grid = grids[site.array_size_roles.last]
    nested_grid.position_at(1).should be > nested_grid.position_at(0)
    nested_grid.position_at(2).should eq(nested_grid.position_at(1))
    nested_grid.position_at(3).should be > nested_grid.position_at(2)
    grids[site.array_size_roles.first].logical_size.should eq(48_i64)
    expected_size_total = extra_early_inner ? 80_i64 : 72_i64
    (grids[site.array_size_roles.first].logical_size + nested_grid.logical_size).should eq(expected_size_total)
    per_mark_schedule_bytes = Array(UInt64).new(parent_rows.size, 0_u64)
    site.array_size_roles.each do |role|
      grid = grids[role]
      parent_rows.size.times do |mark|
        delta = grid.position_at(mark + 1) - grid.position_at(mark)
        per_mark_schedule_bytes[mark] += delta.to_u64
      end
    end
    per_mark_schedule_bytes.max.should eq(32_u64)

    W230SizeTransportScheduleFixture.new(scratch, physical, site, source, grids, parent_rows, outer_type)
  rescue ex
    FileUtils.rm_rf(scratch)
    raise ex
  end
end

describe "W230 recursive QBit occurrence-schedule size transport" do
  it "reads each complete Array size lane once regardless of its mark count" do
    qbit_type = CrystalClick::QBitType.new("Int8", 3_u64)
    qbit_type_descriptor = CrystalClick::BinaryDataType.qbit(qbit_type)
    inner_type = CrystalClick::BinaryDataType.array(qbit_type_descriptor)
    inner_type.should_not be_nil

    if inner = inner_type
      outer_type = CrystalClick::BinaryDataType.array(inner)
      outer_type.should_not be_nil

      if outer = outer_type
        first = w230_size_transport_qbit_value(qbit_type, 0x10_u8)
        second = w230_size_transport_qbit_value(qbit_type, 0x20_u8)
        third = w230_size_transport_qbit_value(qbit_type, 0x30_u8)
        fourth = w230_size_transport_qbit_value(qbit_type, 0x40_u8)
        empty_inner = w230_size_transport_array(inner, [] of CrystalClick::BinaryValue)
        one_inner = w230_size_transport_array(inner, [first] of CrystalClick::BinaryValue)
        two_inner = w230_size_transport_array(
          inner,
          [first, second] of CrystalClick::BinaryValue
        )
        late_inner = w230_size_transport_array(
          inner,
          [third, fourth] of CrystalClick::BinaryValue
        )
        empty_outer = w230_size_transport_array(outer, [] of CrystalClick::BinaryValue)
        rows_by_mark = [
          [w230_size_transport_array(outer, [two_inner, empty_inner] of CrystalClick::BinaryValue),
           empty_outer] of CrystalClick::BinaryValue,
          [empty_outer, empty_outer] of CrystalClick::BinaryValue,
          [w230_size_transport_array(outer, [one_inner] of CrystalClick::BinaryValue),
           w230_size_transport_array(outer, [late_inner] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue,
        ] of Array(CrystalClick::BinaryValue)

        scratch = File.tempname("crystal-click-w230-qbit-size-transport-")
        Dir.mkdir(scratch)
        part = File.join(scratch, "all_1_1_0")
        begin
          CrystalClick::WidePartWriter.write_uint64_qbit_bulk_part(
            part,
            "k",
            Slice[11_u64, 22_u64, 33_u64, 44_u64, 55_u64, 66_u64],
            "v",
            outer,
            rows_by_mark,
            rows_per_mark: 2,
          )

          physical = CrystalClick::BinaryBulkPhysicalPlan.new(
            outer,
            "v",
            CrystalClick::BinaryBulkProfile.single_stream,
          )
          site = CrystalClick::BinaryBulkTypePlan.new(
            outer,
            CrystalClick::BinaryBulkProfile.single_stream,
          ).qbit_array_site
          site.should_not be_nil

          source = W230CountingPartStreamSource.new(part)
          grids = Hash(String, CrystalClick::CompressedMarkGrid).new
          physical.stream_names.each do |role, _name|
            grids[role] = source.inspect_grid(
              physical.data_file_for(role, true),
              physical.marks_file_for(role, true),
              physical.prefix_size_for(role),
            )
          end

          parent_rows = grids[site.not_nil!.array_size_roles.first].rows_per_mark
          parent_rows.should eq([2_u64, 2_u64, 2_u64])
          nested_size_role = site.not_nil!.array_size_roles.last
          nested_grid = grids[nested_size_role]
          nested_grid.position_at(1).should be > nested_grid.position_at(0)
          nested_grid.position_at(2).should eq(nested_grid.position_at(1))
          nested_grid.position_at(3).should be > nested_grid.position_at(2)

          CrystalClick::BinaryQBitArrayOccurrenceSchedule.validate!(
            site.not_nil!,
            physical,
            source,
            grids,
            parent_rows,
            CrystalClick::BinaryCodecLimits.default,
            CrystalClick::CompressedStreamBudget.read_default,
          )

          roles = site.not_nil!.array_size_roles
          roles.size.should eq(2)
          reads = source.window_reads
          # One complete size-lane read per static Array level, independent
          # of the three marks (the nested lane's middle mark is empty).
          reads.size.should eq(roles.size)
          reads.each do |read|
            read[1].should eq(0)
            read[2].should eq(parent_rows.size)
          end
          expected_data_names = roles.map { |role| physical.data_file_for(role, true) }.sort
          actual_data_names = reads.map(&.[0]).sort
          actual_data_names.should eq(expected_data_names)
        ensure
          FileUtils.rm_rf(scratch)
        end
      end
    end
  end

  it "preflights the full outer size-lane result budget before reading marks" do
    fixture = w230_size_transport_schedule_fixture("crystal-click-w230-qbit-result-budget-")
    begin
      expect_raises(CrystalClick::CorruptPartError) do
        fixture.validate!(
          CrystalClick::BinaryCodecLimits.default,
          CrystalClick::CompressedStreamLimits.new(max_result_bytes: 47),
        )
      end
      fixture.source.window_reads.should be_empty
    ensure
      fixture.cleanup
    end
  end

  it "preflights all mark schedule accounting before allocating or reading size lanes" do
    fixture = w230_size_transport_schedule_fixture("crystal-click-w230-qbit-schedule-budget-")
    begin
      limits = CrystalClick::BinaryCodecLimits.new(
        max_depth: 64,
        max_nodes: 4_096,
        max_elements: 1_000_000,
        max_bytes: 64,
      )
      expect_raises(CrystalClick::CorruptPartError) do
        fixture.validate!(limits)
      end
      fixture.source.window_reads.should be_empty
    ensure
      fixture.cleanup
    end
  end

  it "charges consumptive result bytes across separate size lanes" do
    fixture = w230_size_transport_schedule_fixture(
      "crystal-click-w230-qbit-cross-lane-budget-",
      extra_early_inner: true,
    )
    begin
      expect_raises(CrystalClick::CorruptPartError) do
        fixture.validate!(
          CrystalClick::BinaryCodecLimits.default,
          CrystalClick::CompressedStreamLimits.new(max_result_bytes: 79),
        )
      end
      fixture.source.window_reads.size.should be <= 1
    ensure
      fixture.cleanup
    end
  end

  it "keeps the open-time inspection and size-shape pass in one transport budget" do
    fixture = w230_size_transport_schedule_fixture("crystal-click-w230-qbit-open-budget-")
    begin
      part = File.join(fixture.scratch, "all_1_1_0")
      inspected_bytes = 0_i64
      fixture.physical.stream_names.each do |role, _name|
        data_path = File.join(part, fixture.physical.data_file_for(role, true))
        marks_path = File.join(part, fixture.physical.marks_file_for(role, true))
        inspected_bytes += File.size(data_path) + File.size(marks_path)
      end

      size_lane_bytes = 0_i64
      fixture.site.array_size_roles.each do |role|
        data_path = File.join(part, fixture.physical.data_file_for(role, true))
        marks_path = File.join(part, fixture.physical.marks_file_for(role, true))
        size_lane_bytes += File.size(data_path) + File.size(marks_path)
      end
      size_lane_bytes.should be > 0_i64
      size_lane_bytes.should be <= inspected_bytes

      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryBulkColumnReader.open(
          part,
          "v",
          fixture.type,
          transport_limits: CrystalClick::CompressedStreamLimits.new(max_file_bytes: inspected_bytes),
        )
      end
      error.message.not_nil!.should contain("file-byte")
    ensure
      fixture.cleanup
    end
  end
end
