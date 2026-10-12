require "./spec_helper"
require "./support/compact_part_writer_w264_fixture"
require "./support/compact_part_writer_w265_fixture"

class CompactPartWriterW265Probe
  class_property parent = ""
  class_property result_preflight_probe_enabled = false
  class_property result_preflight_events = [] of Tuple(Int64, Int64, Int32, Bool)
  class_property grid_preflight_probe_enabled = false
  class_property grid_preflight_events = [] of Tuple(Int32, Int32, Int64, UInt64, Bool)
  class_property context_open_probe_enabled = false
  class_property context_open_events = [] of Tuple(CrystalClick::CompactMarkFormat, Int32)
  class_property reader_open_probe_enabled = false
  class_property reader_open_count = 0
  class_property reader_open_events = [] of String
  class_property reader_path_byte_events = [] of Int32

  def self.staged_part?(path : String) : Bool
    expanded = File.expand_path(path)
    File.dirname(expanded) == parent && File.basename(expanded).starts_with?(".crystal-click-wide-writer-")
  end
end

class CrystalClick::CompressedStreamBudget
  def preflight_result_bytes(count : Int64) : Nil
    if CompactPartWriterW265Probe.result_preflight_probe_enabled && !writing?
      begin
        previous_def
      rescue ex : CrystalClick::CorruptPartError
        CompactPartWriterW265Probe.result_preflight_events << {
          result_byte_count,
          count,
          CompactPartWriterW265Probe.reader_open_count,
          true,
        }
        raise ex
      else
        CompactPartWriterW265Probe.result_preflight_events << {
          result_byte_count,
          count,
          CompactPartWriterW265Probe.reader_open_count,
          false,
        }
      end
    else
      previous_def
    end
  end
end

class CrystalClick::CompactReadbackGrid
  def self.preflight!(
    budget : CompressedStreamBudget,
    mark_count : Int,
    slot_count : Int,
    data_size : UInt64,
  ) : Nil
    if CompactPartWriterW265Probe.grid_preflight_probe_enabled
      begin
        previous_def
      rescue ex : CorruptPartError
        CompactPartWriterW265Probe.grid_preflight_events << {
          mark_count.to_i32,
          slot_count.to_i32,
          budget.result_byte_count,
          data_size,
          true,
        }
        raise ex
      else
        CompactPartWriterW265Probe.grid_preflight_events << {
          mark_count.to_i32,
          slot_count.to_i32,
          budget.result_byte_count,
          data_size,
          false,
        }
      end
    else
      previous_def
    end
  end
end

class CrystalClick::CompactPartPhysicalContext
  def self.open(
    part_path : String,
    budget : CompressedStreamBudget = CompressedStreamBudget.read_default,
  ) : CompactPartPhysicalContext
    context = previous_def(part_path, budget)
    if CompactPartWriterW265Probe.context_open_probe_enabled && CompactPartWriterW265Probe.staged_part?(part_path)
      CompactPartWriterW265Probe.context_open_events << {context.mode, context.physical_roster.size}
    end
    context
  end
end

class CrystalClick::CompactBinaryBulkColumnReader
  def self.open(
    part_path : String,
    column_name : String,
    expected_type : BinaryDataType,
    limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
    transport_limits : CompressedStreamLimits = CompressedStreamLimits.new,
    codec_budget : BinaryCodecBudget? = nil,
    transport_budget : CompressedStreamBudget? = nil,
  ) : CompactBinaryBulkColumnReader
    reader = previous_def(
      part_path,
      column_name,
      expected_type,
      limits,
      transport_limits,
      codec_budget,
      transport_budget,
    )
    if CompactPartWriterW265Probe.reader_open_probe_enabled && CompactPartWriterW265Probe.staged_part?(part_path)
      CompactPartWriterW265Probe.reader_open_events << String.new(column_name.to_slice)
      CompactPartWriterW265Probe.reader_path_byte_events << part_path.bytesize
      CompactPartWriterW265Probe.reader_open_count += 1
    end
    reader
  end
end

private def w265_complete_readback_result_limit(
  events : Array(Tuple(Int64, Int64, Int32, Bool)),
) : Int64
  raise "staged result-byte preflights were not captured" if events.empty?
  raise "reference staged validation unexpectedly refused a result-byte preflight" if events.any? { |event| event[3] }

  # reserve_result_bytes and direct preflight_result_bytes both pass through
  # this seam. The maximum cumulative-count-plus-request is therefore the
  # whole-operation result limit, including charges not emitted by observers.
  events.max_of { |event| event[0] + event[1] }
end

private def w265_grid_workspace_upper_bound(mark_count : Int32, slot_count : Int32, data_size : UInt64) : Int64
  marks = mark_count.to_u64
  slots = slot_count.to_u64
  coordinate_count = (marks + 1_u64) * slots
  frame_count = data_size // CrystalClick::CompressedBlock::FRAME_HEADER_SIZE.to_u64

  bytes = instance_sizeof(CrystalClick::CompactMarkIndex).to_u64
  bytes += instance_sizeof(Array(Int64)).to_u64
  bytes += coordinate_count * sizeof(Int64).to_u64
  bytes += instance_sizeof(Array(UInt64)).to_u64
  bytes += marks * sizeof(UInt64).to_u64
  bytes += instance_sizeof(CrystalClick::CompressedFrameIndex).to_u64
  bytes += instance_sizeof(Array(CrystalClick::CompressedFrameDescriptor)).to_u64
  bytes += frame_count * sizeof(CrystalClick::CompressedFrameDescriptor).to_u64
  bytes.to_i64
end

describe CrystalClick::CompactPartWriter do
  it "calibrates cumulative staged readback and distinguishes the MRK4 17-slot grid" do
    parent = File.tempname("crystal-click-w265-mrk4-readback-grid-")
    mrk3_reference = File.join(parent, "part0000")
    mrk3_limited = File.join(parent, "part0001")
    mrk4_reference = File.join(parent, "part0002")
    mrk4_limited = File.join(parent, "part0003")
    sentinel = File.join(parent, "keep.txt")
    begin
      Dir.mkdir(parent)
      File.write(sentinel, "unrelated")
      CompactPartWriterW265Probe.parent = File.expand_path(parent)

      CompactPartWriterW265Probe.result_preflight_events = [] of Tuple(Int64, Int64, Int32, Bool)
      CompactPartWriterW265Probe.grid_preflight_events = [] of Tuple(Int32, Int32, Int64, UInt64, Bool)
      CompactPartWriterW265Probe.reader_open_count = 0
      CompactPartWriterW265Probe.reader_open_events = [] of String
      CompactPartWriterW265Probe.reader_path_byte_events = [] of Int32
      CompactPartWriterW265Probe.result_preflight_probe_enabled = true
      CompactPartWriterW265Probe.grid_preflight_probe_enabled = true
      CompactPartWriterW265Probe.reader_open_probe_enabled = true
      begin
        CompactPartWriterW265Fixture.write(mrk3_reference, CrystalClick::CompactMarkFormat::Mrk3)
      ensure
        CompactPartWriterW265Probe.result_preflight_probe_enabled = false
        CompactPartWriterW265Probe.grid_preflight_probe_enabled = false
        CompactPartWriterW265Probe.reader_open_probe_enabled = false
      end

      mrk3_grid = CompactPartWriterW265Probe.grid_preflight_events.find { |event| event[1] == 8 } ||
                  raise "staged MRK3 grid preflight was not observed"
      mrk3_grid[4].should be_false
      reference_result_events = CompactPartWriterW265Probe.result_preflight_events.dup
      reference_reader_path_bytes = CompactPartWriterW265Probe.reader_path_byte_events.dup
      reference_max = w265_complete_readback_result_limit(reference_result_events)
      reference_max.should be > 0_i64
      reference_reader_path_bytes.size.should eq(8)
      # File.tempname appends an unpadded base36 UInt32 suffix (1–7 bytes).
      # The retained context accounts for two path strings; every typed-reader
      # census also accounts for its own part path and those two context paths.
      path_owner_count = 2_i64 + 3_i64 * reference_reader_path_bytes.size.to_i64
      path_suffix_slack = 6_i64 * path_owner_count
      result_limit = reference_max + path_suffix_slack

      # Exercise the grid bound independently at one identical preseeded
      # result-byte count. The MRK3 bound fits exactly; only the slot count
      # changes for the MRK4 falsifier.
      mrk3_grid_bound = w265_grid_workspace_upper_bound(mrk3_grid[0], 8, mrk3_grid[3])
      mrk4_grid_bound = w265_grid_workspace_upper_bound(mrk3_grid[0], 17, mrk3_grid[3])
      mrk4_grid_bound.should be > mrk3_grid_bound
      direct_limit = mrk3_grid[2] + mrk3_grid_bound
      direct_limits = CrystalClick::CompressedStreamLimits.new(max_result_bytes: direct_limit)
      direct_mrk3_budget = CrystalClick::CompressedStreamBudget.new(direct_limits)
      direct_mrk3_budget.reserve_result_bytes(mrk3_grid[2])
      direct_mrk4_budget = CrystalClick::CompressedStreamBudget.new(direct_limits)
      direct_mrk4_budget.reserve_result_bytes(mrk3_grid[2])

      CompactPartWriterW265Probe.grid_preflight_events = [] of Tuple(Int32, Int32, Int64, UInt64, Bool)
      CompactPartWriterW265Probe.grid_preflight_probe_enabled = true
      begin
        CrystalClick::CompactReadbackGrid.preflight!(direct_mrk3_budget, mrk3_grid[0], 8, mrk3_grid[3])
        expect_raises(CrystalClick::CorruptPartError, /result-byte limit exceeded/) do
          CrystalClick::CompactReadbackGrid.preflight!(direct_mrk4_budget, mrk3_grid[0], 17, mrk3_grid[3])
        end
      ensure
        CompactPartWriterW265Probe.grid_preflight_probe_enabled = false
      end
      direct_grid_events = CompactPartWriterW265Probe.grid_preflight_events
      direct_grid_events.size.should eq(2)
      direct_grid_events[0][1].should eq(8)
      direct_grid_events[0][2].should eq(mrk3_grid[2])
      direct_grid_events[0][4].should be_false
      direct_grid_events[1][1].should eq(17)
      direct_grid_events[1][2].should eq(mrk3_grid[2])
      direct_grid_events[1][4].should be_true

      reader_limits = CrystalClick::CompressedStreamLimits.new(max_result_bytes: result_limit)
      CompactPartWriterW265Probe.result_preflight_events = [] of Tuple(Int64, Int64, Int32, Bool)
      CompactPartWriterW265Probe.grid_preflight_events = [] of Tuple(Int32, Int32, Int64, UInt64, Bool)
      CompactPartWriterW265Probe.reader_open_events = [] of String
      CompactPartWriterW265Probe.reader_path_byte_events = [] of Int32
      CompactPartWriterW265Probe.reader_open_count = 0
      CompactPartWriterW265Probe.result_preflight_probe_enabled = true
      CompactPartWriterW265Probe.grid_preflight_probe_enabled = true
      CompactPartWriterW265Probe.reader_open_probe_enabled = true
      begin
        begin
          CompactPartWriterW265Fixture.write(
            mrk3_limited,
            CrystalClick::CompactMarkFormat::Mrk3,
            reader_limits: reader_limits,
          )
        rescue ex : CrystalClick::CorruptPartError
          events = CompactPartWriterW265Probe.result_preflight_events
          failed_event = events.find { |event| event[3] }
          last_successful_event = events.reverse.find { |event| !event[3] }
          failed_detail = if failed_event
                            "current=#{failed_event[0]},request=#{failed_event[1]},reader_count=#{failed_event[2]}"
                          else
                            "missing"
                          end
          last_successful_detail = if last_successful_event
                                     "current=#{last_successful_event[0]},request=#{last_successful_event[1]},reader_count=#{last_successful_event[2]}"
                                   else
                                     "missing"
                                   end
          raise "capped MRK3 diagnostic: reference_max=#{reference_max}, " +
                "reader_limit=#{result_limit}, " +
                "path_suffix_slack=#{path_suffix_slack}, " +
                "reference_path_bytes=#{reference_reader_path_bytes.inspect}, " +
                "current_path_bytes=#{CompactPartWriterW265Probe.reader_path_byte_events.inspect}, " +
                "first_failed_preflight=#{failed_detail}, " +
                "last_successful_preflight=#{last_successful_detail}, " +
                "reader_names=#{CompactPartWriterW265Probe.reader_open_events.inspect}, " +
                "cause=#{ex.message}"
        end
      ensure
        CompactPartWriterW265Probe.result_preflight_probe_enabled = false
        CompactPartWriterW265Probe.grid_preflight_probe_enabled = false
        CompactPartWriterW265Probe.reader_open_probe_enabled = false
      end
      mrk3_preflights = CompactPartWriterW265Probe.grid_preflight_events
      mrk3_preflights.should_not be_empty
      mrk3_preflights.all? { |event| event[1] == 8 && !event[4] }.should be_true
      CrystalClick::CompactPartPhysicalContext.open(mrk3_limited).physical_roster.size.should eq(8)

      # A successful MRK4 staged validation must open every physical context
      # and typed value reader against the authenticated 17-slot roster.
      CompactPartWriterW265Probe.context_open_events = [] of Tuple(CrystalClick::CompactMarkFormat, Int32)
      CompactPartWriterW265Probe.reader_open_events = [] of String
      CompactPartWriterW265Probe.reader_open_count = 0
      CompactPartWriterW265Probe.context_open_probe_enabled = true
      CompactPartWriterW265Probe.reader_open_probe_enabled = true
      begin
        CompactPartWriterW265Fixture.write(mrk4_reference, CrystalClick::CompactMarkFormat::Mrk4)
      ensure
        CompactPartWriterW265Probe.context_open_probe_enabled = false
        CompactPartWriterW265Probe.reader_open_probe_enabled = false
      end
      CompactPartWriterW265Probe.reader_open_events.should eq(
        ["pk"] + CompactPartWriterW264Fixture::COLUMN_NAMES,
      )
      CompactPartWriterW265Probe.context_open_events.should_not be_empty
      all_mrk4_contexts_used_seventeen_slots = CompactPartWriterW265Probe.context_open_events.all? do |mode, slot_count|
        mode.mrk4? && slot_count == 17
      end
      all_mrk4_contexts_used_seventeen_slots.should be_true

      # Reuse the MRK3-calibrated cumulative cap, but do not infer the cause
      # from the error: the direct matched-budget test above isolates grid
      # cardinality, while this checks refusal cleanup through publication.
      CompactPartWriterW265Probe.result_preflight_events = [] of Tuple(Int64, Int64, Int32, Bool)
      CompactPartWriterW265Probe.grid_preflight_events = [] of Tuple(Int32, Int32, Int64, UInt64, Bool)
      CompactPartWriterW265Probe.reader_open_events = [] of String
      CompactPartWriterW265Probe.reader_path_byte_events = [] of Int32
      CompactPartWriterW265Probe.reader_open_count = 0
      CompactPartWriterW265Probe.result_preflight_probe_enabled = true
      CompactPartWriterW265Probe.grid_preflight_probe_enabled = true
      CompactPartWriterW265Probe.reader_open_probe_enabled = true
      begin
        expect_raises(CrystalClick::CorruptPartError, /result-byte limit exceeded/) do
          CompactPartWriterW265Fixture.write(
            mrk4_limited,
            CrystalClick::CompactMarkFormat::Mrk4,
            reader_limits: reader_limits,
          )
        end
      ensure
        CompactPartWriterW265Probe.result_preflight_probe_enabled = false
        CompactPartWriterW265Probe.grid_preflight_probe_enabled = false
        CompactPartWriterW265Probe.reader_open_probe_enabled = false
      end
      mrk4_limited_result_events = CompactPartWriterW265Probe.result_preflight_events
      failed_result_events = mrk4_limited_result_events.select { |event| event[3] }
      failed_result_events.size.should eq(1)
      failed_result_event = failed_result_events[0]
      (failed_result_event[0] + failed_result_event[1]).should be > result_limit
      successful_result_events = mrk4_limited_result_events.select do |event|
        !event[3] && event[0] + event[1] <= result_limit
      end
      successful_result_events.should_not be_empty
      successful_result_events.any? { |event| event[2] > 0 }.should be_true
      failed_result_event[0].should be > 0_i64
      failed_result_event[2].should be > 1

      mrk4_limited_grid_events = CompactPartWriterW265Probe.grid_preflight_events
      mrk4_limited_grid_events.should_not be_empty
      mrk4_limited_grid_events.all? { |event| event[1] == 17 }.should be_true
      expected_reader_names = ["pk"] + CompactPartWriterW264Fixture::COLUMN_NAMES
      observed_reader_count = CompactPartWriterW265Probe.reader_open_count
      observed_reader_count.should eq(CompactPartWriterW265Probe.reader_open_events.size)
      observed_reader_count.should be > 1
      observed_reader_count.should be <= expected_reader_names.size
      failed_result_event[2].should eq(observed_reader_count)
      CompactPartWriterW265Probe.reader_open_events.each_with_index do |name, index|
        name.should eq(expected_reader_names[index])
      end
      File.exists?(mrk4_limited).should be_false
      File.read(sentinel).should eq("unrelated")
      Dir.children(parent).sort.should eq(["keep.txt", "part0000", "part0001", "part0002"])
    ensure
      CompactPartWriterW265Probe.parent = ""
      CompactPartWriterW265Probe.result_preflight_probe_enabled = false
      CompactPartWriterW265Probe.grid_preflight_probe_enabled = false
      CompactPartWriterW265Probe.context_open_probe_enabled = false
      CompactPartWriterW265Probe.reader_open_probe_enabled = false
      FileUtils.rm_rf(parent)
    end
  end

  it "does not replace an existing destination for an explicit MRK4 write" do
    parent = File.tempname("crystal-click-w265-mrk4-destination-guard-")
    target = File.join(parent, "existing")
    marker = File.join(target, "keep.txt")
    begin
      Dir.mkdir(parent)
      Dir.mkdir(target)
      File.write(marker, "existing MRK3 bytes")

      expect_raises(ArgumentError, /destination must not already exist/) do
        CompactPartWriterW265Fixture.write(target, CrystalClick::CompactMarkFormat::Mrk4)
      end

      File.read(marker).should eq("existing MRK3 bytes")
      Dir.children(parent).should eq(["existing"])
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
