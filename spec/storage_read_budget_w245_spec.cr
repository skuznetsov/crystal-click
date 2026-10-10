require "./spec_helper"

private def w245_roomy_codec_limits : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: 64,
    max_nodes: 1_000_000,
    max_elements: 3_000_000,
    max_bytes: 64 * 1024 * 1024,
  )
end

private def w245_roomy_transport_limits : CrystalClick::CompressedStreamLimits
  CrystalClick::CompressedStreamLimits.new
end

private def w245_scalar_reader(
  path : String,
  column : String,
  codec_limits : CrystalClick::BinaryCodecLimits,
  transport_limits : CrystalClick::CompressedStreamLimits,
  codec_budget : CrystalClick::BinaryCodecBudget? = nil,
  transport_budget : CrystalClick::CompressedStreamBudget? = nil,
) : CrystalClick::BinaryBulkColumnReader
  CrystalClick::BinaryBulkColumnReader.open(
    path,
    column,
    CrystalClick::BinaryDataType.primitive("UInt64"),
    codec_limits,
    transport_limits,
    codec_budget,
    transport_budget,
  )
end

private def w245_measure_scalar_read(path : String, column : String)
  codec_limits = w245_roomy_codec_limits
  transport_limits = w245_roomy_transport_limits
  codec_budget = CrystalClick::BinaryCodecBudget.new(codec_limits)
  transport_budget = CrystalClick::CompressedStreamBudget.new(transport_limits)
  reader = w245_scalar_reader(
    path, column, codec_limits, transport_limits, codec_budget, transport_budget
  )
  reader.read_marks(0, reader.mark_count)

  {
    codec_nodes:       codec_budget.node_count,
    codec_elements:    codec_budget.element_count,
    codec_bytes:       codec_budget.wire_byte_count,
    transport_files:   transport_budget.file_byte_count,
    transport_records: transport_budget.record_count,
    transport_decoded: transport_budget.decoded_byte_count,
    transport_results: transport_budget.result_byte_count,
  }
end

private def w245_codec_limits_for(cost) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: 64,
    max_nodes: cost[:codec_nodes],
    max_elements: cost[:codec_elements],
    max_bytes: cost[:codec_bytes],
  )
end

private def w245_transport_limits_for(cost) : CrystalClick::CompressedStreamLimits
  CrystalClick::CompressedStreamLimits.new(
    max_file_bytes: cost[:transport_files],
    max_mark_bytes: CrystalClick::CompressedStreamLimits::DEFAULT_MAX_MARK_BYTES,
    max_frame_compressed_bytes: CrystalClick::CompressedStreamLimits::DEFAULT_MAX_FRAME_COMPRESSED_BYTES,
    max_frame_decompressed_bytes: CrystalClick::CompressedStreamLimits::DEFAULT_MAX_FRAME_DECOMPRESSED_BYTES,
    max_records: cost[:transport_records],
    max_decoded_bytes: cost[:transport_decoded],
    max_result_bytes: cost[:transport_results],
  )
end

private def w245_codec_counts(budget : CrystalClick::BinaryCodecBudget)
  {budget.node_count, budget.element_count, budget.wire_byte_count}
end

private def w245_transport_counts(budget : CrystalClick::CompressedStreamBudget)
  {
    budget.file_byte_count,
    budget.record_count,
    budget.decoded_byte_count,
    budget.result_byte_count,
  }
end

private def w245_codec_limit_variants(base : CrystalClick::BinaryCodecLimits) : Array(CrystalClick::BinaryCodecLimits)
  [
    CrystalClick::BinaryCodecLimits.new(base.max_depth + 1, base.max_nodes, base.max_elements, base.max_bytes),
    CrystalClick::BinaryCodecLimits.new(base.max_depth, base.max_nodes + 1, base.max_elements, base.max_bytes),
    CrystalClick::BinaryCodecLimits.new(base.max_depth, base.max_nodes, base.max_elements + 1, base.max_bytes),
    CrystalClick::BinaryCodecLimits.new(base.max_depth, base.max_nodes, base.max_elements, base.max_bytes + 1),
  ]
end

private def w245_transport_limit_variants(base : CrystalClick::CompressedStreamLimits) : Array(CrystalClick::CompressedStreamLimits)
  [
    CrystalClick::CompressedStreamLimits.new(base.max_file_bytes + 1, base.max_mark_bytes, base.max_frame_compressed_bytes, base.max_frame_decompressed_bytes, base.max_records, base.max_decoded_bytes, base.max_result_bytes),
    CrystalClick::CompressedStreamLimits.new(base.max_file_bytes, base.max_mark_bytes + 1, base.max_frame_compressed_bytes, base.max_frame_decompressed_bytes, base.max_records, base.max_decoded_bytes, base.max_result_bytes),
    CrystalClick::CompressedStreamLimits.new(base.max_file_bytes, base.max_mark_bytes, base.max_frame_compressed_bytes + 1, base.max_frame_decompressed_bytes, base.max_records, base.max_decoded_bytes, base.max_result_bytes),
    CrystalClick::CompressedStreamLimits.new(base.max_file_bytes, base.max_mark_bytes, base.max_frame_compressed_bytes, base.max_frame_decompressed_bytes + 1, base.max_records, base.max_decoded_bytes, base.max_result_bytes),
    CrystalClick::CompressedStreamLimits.new(base.max_file_bytes, base.max_mark_bytes, base.max_frame_compressed_bytes, base.max_frame_decompressed_bytes, base.max_records + 1, base.max_decoded_bytes, base.max_result_bytes),
    CrystalClick::CompressedStreamLimits.new(base.max_file_bytes, base.max_mark_bytes, base.max_frame_compressed_bytes, base.max_frame_decompressed_bytes, base.max_records, base.max_decoded_bytes + 1, base.max_result_bytes),
    CrystalClick::CompressedStreamLimits.new(base.max_file_bytes, base.max_mark_bytes, base.max_frame_compressed_bytes, base.max_frame_decompressed_bytes, base.max_records, base.max_decoded_bytes, base.max_result_bytes + 1),
  ]
end

private def w245_write_scalar_part(
  destination : String,
  marks : Array(Array(UInt64)),
  rows_per_mark : Int32,
) : String
  keys = marks.flatten
  values = marks.map do |mark|
    mark.map { |value| CrystalClick::BinaryValue.uint64(value) }
  end
  type = CrystalClick::BinaryDataType.primitive("UInt64")
  columns = [
    CrystalClick::WidePartColumn.binary_bulk("left", type, values),
    CrystalClick::WidePartColumn.binary_bulk("right", type, values),
  ]
  CrystalClick::WidePartWriter.write_uint64_columns(
    destination,
    "pk",
    keys.to_unsafe.to_slice(keys.size),
    columns,
    rows_per_mark: rows_per_mark,
  )
end

describe "W245 borrowed storage read budgets" do
  it "shares consumptive limits across inspection and decoding, while nil keeps per-operation owners" do
    parent = File.tempname("crystal-click-w245-read-budget")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")

    begin
      w245_write_scalar_part(destination, [[1_u64, 2_u64], [3_u64]], 2)

      left_cost = w245_measure_scalar_read(destination, "left")
      right_cost = w245_measure_scalar_read(destination, "right")
      # Identically encoded UInt64 value columns and equal-length ordinary
      # names make the calibration symmetric without assuming rows == codec
      # nodes or that inspected and decoded file passes are unique-byte counts.
      left_cost.should eq(right_cost)

      codec_limits = w245_codec_limits_for(left_cost)
      transport_limits = w245_transport_limits_for(left_cost)

      # Each column independently fits the exact measured cumulative caps.
      {"left", "right"}.each do |column|
        codec_budget = CrystalClick::BinaryCodecBudget.new(codec_limits)
        transport_budget = CrystalClick::CompressedStreamBudget.new(transport_limits)
        reader = w245_scalar_reader(
          destination, column, codec_limits, transport_limits, codec_budget, transport_budget
        )
        reader.read_marks(0, reader.mark_count)
        w245_codec_counts(codec_budget).should eq({left_cost[:codec_nodes], left_cost[:codec_elements], left_cost[:codec_bytes]})
        w245_transport_counts(transport_budget).should eq({left_cost[:transport_files], left_cost[:transport_records], left_cost[:transport_decoded], left_cost[:transport_results]})
      end

      # One codec owner is charged by open and read_marks. A second reader
      # cannot obtain a fresh/cloned allowance from that borrowed owner.
      shared_codec = CrystalClick::BinaryCodecBudget.new(codec_limits)
      ample_transport = w245_roomy_transport_limits
      codec_transport_budget = CrystalClick::CompressedStreamBudget.new(ample_transport)
      first_codec_reader = w245_scalar_reader(
        destination, "left", codec_limits, ample_transport, shared_codec, codec_transport_budget
      )
      # `open` charges the bounded descriptor walk and physical inspections
      # into these borrowed owners before `read_marks` starts.
      shared_codec.wire_byte_count.should be > 0
      codec_transport_budget.file_byte_count.should be > 0
      first_codec_reader.read_marks(0, first_codec_reader.mark_count)
      codec_before_second = w245_codec_counts(shared_codec)
      codec_before_second.should eq({left_cost[:codec_nodes], left_cost[:codec_elements], left_cost[:codec_bytes]})
      expect_raises(CrystalClick::CorruptPartError, /binary codec .* limit exceeded/) do
        w245_scalar_reader(
          destination, "right", codec_limits, ample_transport, shared_codec, codec_transport_budget
        )
      end
      shared_codec.node_count.should be >= codec_before_second[0]
      shared_codec.element_count.should be >= codec_before_second[1]
      shared_codec.wire_byte_count.should be >= codec_before_second[2]

      # Independently, one transport owner accumulates file/frame/mark work
      # across inspection plus decoding and rejects a second physical column.
      ample_codec = w245_roomy_codec_limits
      transport_codec_budget = CrystalClick::BinaryCodecBudget.new(ample_codec)
      shared_transport = CrystalClick::CompressedStreamBudget.new(transport_limits)
      first_transport_reader = w245_scalar_reader(
        destination, "left", ample_codec, transport_limits, transport_codec_budget, shared_transport
      )
      transport_codec_budget.wire_byte_count.should be > 0
      shared_transport.file_byte_count.should be > 0
      first_transport_reader.read_marks(0, first_transport_reader.mark_count)
      transport_before_second = w245_transport_counts(shared_transport)
      transport_before_second.should eq({left_cost[:transport_files], left_cost[:transport_records], left_cost[:transport_decoded], left_cost[:transport_results]})
      expect_raises(CrystalClick::CorruptPartError, /compressed stream .* limit exceeded/) do
        w245_scalar_reader(
          destination, "right", ample_codec, transport_limits, transport_codec_budget, shared_transport
        )
      end
      shared_transport.file_byte_count.should be >= transport_before_second[0]
      shared_transport.record_count.should be >= transport_before_second[1]
      shared_transport.decoded_byte_count.should be >= transport_before_second[2]
      shared_transport.result_byte_count.should be >= transport_before_second[3]

      # Omitted budgets still create fresh owners per operation. The same
      # limits that fit the explicit open+one-read sum therefore permit two
      # independent read_marks calls.
      nil_budget_reader = w245_scalar_reader(
        destination, "left", codec_limits, transport_limits
      )
      first_read = nil_budget_reader.read_marks(0, nil_budget_reader.mark_count)
      second_read = nil_budget_reader.read_marks(0, nil_budget_reader.mark_count)
      second_read.size.should eq(first_read.size)
      first_read.each_with_index do |first_mark, mark_index|
        second_mark = second_read[mark_index]
        second_mark.size.should eq(first_mark.size)
        first_mark.each_with_index do |first_value, row_index|
          second_value = second_mark[row_index]
          second_value.type.should eq(first_value.type)
          second_value.as_uint64.should eq(first_value.as_uint64)
        end
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects wrong budget direction and every changed limit field before charging either owner" do
    parent = File.tempname("crystal-click-w245-read-budget-guards")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    codec_limits = w245_roomy_codec_limits
    transport_limits = w245_roomy_transport_limits

    begin
      w245_write_scalar_part(destination, [[1_u64], [2_u64]], 1)

      wrong_codec_direction = CrystalClick::BinaryCodecBudget.new(codec_limits, true)
      untouched_transport = CrystalClick::CompressedStreamBudget.new(transport_limits)
      expect_raises(ArgumentError) do
        w245_scalar_reader(
          destination, "left", codec_limits, transport_limits,
          wrong_codec_direction, untouched_transport,
        )
      end
      w245_codec_counts(wrong_codec_direction).should eq({0_i64, 0_i64, 0_i64})
      w245_transport_counts(untouched_transport).should eq({0_i64, 0_i64, 0_i64, 0_i64})

      untouched_codec = CrystalClick::BinaryCodecBudget.new(codec_limits)
      wrong_transport_direction = CrystalClick::CompressedStreamBudget.new(transport_limits, true)
      expect_raises(ArgumentError) do
        w245_scalar_reader(
          destination, "left", codec_limits, transport_limits,
          untouched_codec, wrong_transport_direction,
        )
      end
      w245_codec_counts(untouched_codec).should eq({0_i64, 0_i64, 0_i64})
      w245_transport_counts(wrong_transport_direction).should eq({0_i64, 0_i64, 0_i64, 0_i64})

      w245_codec_limit_variants(codec_limits).each do |mismatched_limits|
        codec_budget = CrystalClick::BinaryCodecBudget.new(mismatched_limits)
        transport_budget = CrystalClick::CompressedStreamBudget.new(transport_limits)
        expect_raises(ArgumentError) do
          w245_scalar_reader(
            destination, "left", codec_limits, transport_limits,
            codec_budget, transport_budget,
          )
        end
        w245_codec_counts(codec_budget).should eq({0_i64, 0_i64, 0_i64})
        w245_transport_counts(transport_budget).should eq({0_i64, 0_i64, 0_i64, 0_i64})
      end

      w245_transport_limit_variants(transport_limits).each do |mismatched_limits|
        codec_budget = CrystalClick::BinaryCodecBudget.new(codec_limits)
        transport_budget = CrystalClick::CompressedStreamBudget.new(mismatched_limits)
        expect_raises(ArgumentError) do
          w245_scalar_reader(
            destination, "left", codec_limits, transport_limits,
            codec_budget, transport_budget,
          )
        end
        w245_codec_counts(codec_budget).should eq({0_i64, 0_i64, 0_i64})
        w245_transport_counts(transport_budget).should eq({0_i64, 0_i64, 0_i64, 0_i64})
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
