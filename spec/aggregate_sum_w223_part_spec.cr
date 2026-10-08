require "./spec_helper"
require "file_utils"

private def w223p_type(function : String, argument : CrystalClick::BinaryDataType) : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.aggregate_function(function, argument)
end

private def w223p_u64_bytes(value : UInt64) : Bytes
  bytes = Bytes.new(8, 0_u8)
  8.times { |index| bytes[index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
  bytes
end

private def w223p_nullable_sum_bytes(value : UInt64?) : Bytes
  return Bytes[0_u8] unless value

  bytes = Bytes.new(9, 0_u8)
  bytes[0] = 1_u8
  8.times { |index| bytes[index + 1] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
  bytes
end

private def w223p_values(
  type : CrystalClick::BinaryDataType,
  state_granules : Array(Array(Bytes)),
) : Array(Array(CrystalClick::BinaryValue))
  state_granules.map do |granule|
    granule.map { |state| CrystalClick::BinaryValue.aggregate_function_state(type, state) }
  end
end

private def w223p_keys(rows : Int32) : Array(UInt64)
  Array(UInt64).new(rows) { |index| 7_u64 + index.to_u64 * 11_u64 }
end

private def w223p_write(
  destination : String,
  type : CrystalClick::BinaryDataType,
  state_granules : Array(Array(Bytes)),
  rows_per_mark : Int32 = 2,
) : String
  keys = w223p_keys(state_granules.flatten.size.to_i32)
  values = w223p_values(type, state_granules)
  CrystalClick::WidePartWriter.write_uint64_and_aggregate_function_part(
    destination,
    "pk",
    keys.to_unsafe.to_slice(keys.size),
    "v",
    type,
    values,
    rows_per_mark: rows_per_mark
  )
end

private def w223p_read_states(
  reader : CrystalClick::BinaryBulkColumnReader,
  first_mark : Int,
  mark_count : Int,
) : Array(CrystalClick::BinaryValue)
  reader.read_marks(first_mark, mark_count).flatten
end

private def w223p_parent(&)
  parent = File.tempname("crystal-click-w223-aggregate-part-")
  Dir.mkdir(parent)
  begin
    yield parent
  ensure
    FileUtils.rm_rf(parent)
  end
end

describe "W223 AggregateFunction paired static part" do
  it "writes fixed promoted sum states and reads independent mark windows" do
    argument = CrystalClick::BinaryDataType.primitive("UInt8")
    type = w223p_type("sum", argument)
    type.name.should eq("AggregateFunction(sum, UInt8)")

    state_bytes = [0_u64, 42_u64, 200_u64, 255_u64, 1_000_u64].map { |value| w223p_u64_bytes(value) }
    state_granules = [state_bytes[0, 2], state_bytes[2, 2], state_bytes[4, 1]]

    w223p_parent do |parent|
      part_path = File.join(parent, "all_1_1_0")
      w223p_write(part_path, type, state_granules).should eq(part_path)

      reader = CrystalClick::BinaryBulkColumnReader.open(part_path, "v", type)
      reader.schema_declaration.should eq(type.name)
      reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      reader.physical_stream_names.should eq(["v"])

      w223p_read_states(reader, 0, 1).map(&.aggregate_function_state_bytes).should eq(state_bytes[0, 2])
      w223p_read_states(reader, 1, 1).map(&.aggregate_function_state_bytes).should eq(state_bytes[2, 2])
      w223p_read_states(reader, 2, 1).map(&.aggregate_function_state_bytes).should eq(state_bytes[4, 1])
      w223p_read_states(reader, 1, 2).map(&.aggregate_function_state_bytes).should eq(state_bytes[2, 3])

      decoded_lane = CrystalClick::CompressedBlock.decode_all(
        File.read(File.join(part_path, "#{CrystalClick::StreamName.hash("v")}.bin")).to_slice
      )
      expected_lane = [] of UInt8
      state_bytes.each { |bytes| expected_lane.concat(bytes.to_a) }
      decoded_lane.to_a.should eq(expected_lane)
    end
  end

  it "preserves both raw Kahan words without interpreting their bits" do
    type = w223p_type("sumKahan", CrystalClick::BinaryDataType.primitive("Float64"))
    type.name.should eq("AggregateFunction(sumKahan, Float64)")
    kahan = Bytes[
      0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0xf8_u8, 0x3f_u8,
      0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0xd0_u8, 0x3f_u8,
    ]
    state_granules = [[kahan] of Bytes]

    w223p_parent do |parent|
      part_path = File.join(parent, "all_1_1_0")
      w223p_write(part_path, type, state_granules, 1)
      reader = CrystalClick::BinaryBulkColumnReader.open(part_path, "v", type)
      state = w223p_read_states(reader, 0, 1).first
      state.type.should eq(type)
      state.aggregate_function_state_bytes.should eq(kahan)
      state.aggregate_function_state_bytes.size.should eq(16)
    end
  end

  it "preserves sumWithOverflow Bool accumulator bytes outside the Bool value domain" do
    type = w223p_type("sumWithOverflow", CrystalClick::BinaryDataType.primitive("Bool"))
    state_bytes = Bytes[0x03_u8]

    w223p_parent do |parent|
      part_path = File.join(parent, "all_1_1_0")
      w223p_write(part_path, type, [[state_bytes] of Bytes], 1)
      reader = CrystalClick::BinaryBulkColumnReader.open(part_path, "v", type)
      reader.physical_stream_names.should eq(["v"])
      reader.read_marks(0, 1).first.first.aggregate_function_state_bytes.should eq(state_bytes)
    end
  end

  it "keeps Nullable argument presence inside the opaque state, not as a NULL aggregate value" do
    argument = CrystalClick::BinaryDataType.nullable(
      CrystalClick::BinaryDataType.primitive("UInt64")
    )
    type = w223p_type("sum", argument)
    type.name.should eq("AggregateFunction(sum, Nullable(UInt64))")

    state_bytes = [
      w223p_nullable_sum_bytes(nil),
      w223p_nullable_sum_bytes(0_u64),
      w223p_nullable_sum_bytes(42_u64),
    ]
    state_granules = [state_bytes[0, 2], state_bytes[2, 1]]

    w223p_parent do |parent|
      part_path = File.join(parent, "all_1_1_0")
      w223p_write(part_path, type, state_granules)
      reader = CrystalClick::BinaryBulkColumnReader.open(part_path, "v", type)
      reader.physical_stream_names.should eq(["v"])
      states = w223p_read_states(reader, 0, 2)
      states.map(&.type).should eq([type, type, type])
      states.map(&.is_null?).should eq([false, false, false])
      states.map(&.aggregate_function_state_bytes).should eq(state_bytes)
      states[0].aggregate_function_state_bytes.should eq(Bytes[0_u8])
    end
  end

  it "retains explicit LowCardinality argument metadata despite normalized state dispatch" do
    low_cardinality_bool = CrystalClick::BinaryDataType.low_cardinality(
      CrystalClick::BinaryDataType.primitive("Bool")
    )
    type = w223p_type("sum", low_cardinality_bool)
    type.name.should eq("AggregateFunction(sum, LowCardinality(Bool))")
    state_bytes = w223p_u64_bytes(3_u64)

    w223p_parent do |parent|
      part_path = File.join(parent, "all_1_1_0")
      w223p_write(part_path, type, [[state_bytes] of Bytes], 1)
      reader = CrystalClick::BinaryBulkColumnReader.open(part_path, "v", type)
      state = w223p_read_states(reader, 0, 1).first
      state.type.should eq(type)
      reader.schema_declaration.should eq("AggregateFunction(sum, LowCardinality(Bool))")
      state.aggregate_function_state_bytes.should eq(state_bytes)

      # Bool and LowCardinality(Bool) can reach the same fixed state lane;
      # the declared argument tree is still part of the persisted identity.
      bare_bool_type = w223p_type("sum", CrystalClick::BinaryDataType.primitive("Bool"))
      expect_raises(CrystalClick::CorruptPartError, /source declaration differs/) do
        CrystalClick::BinaryBulkColumnReader.open(part_path, "v", bare_bool_type)
      end
    end
  end

  it "rejects same-layout nominal substitutions and malformed lane rosters" do
    argument = CrystalClick::BinaryDataType.primitive("UInt64")
    sum_type = w223p_type("sum", argument)
    wrong_function = w223p_type("sumWithOverflow", argument)
    state = w223p_u64_bytes(42_u64)

    w223p_parent do |parent|
      part_path = File.join(parent, "all_1_1_0")
      w223p_write(part_path, sum_type, [[state] of Bytes], 1)
      expect_raises(CrystalClick::CorruptPartError, /source declaration differs/) do
        CrystalClick::BinaryBulkColumnReader.open(part_path, "v", wrong_function)
      end

      roster_path = File.join(part_path, "columns_substreams.txt")
      original = File.read(roster_path)
      original.should contain("\tv\n")
      malformed = original.gsub("\tv\n", "\tv.unexpected\n")
      malformed.should_not eq(original)
      File.write(roster_path, malformed)
      expect_raises(CrystalClick::CorruptPartError, /selected columns_substreams roster differs/) do
        CrystalClick::BinaryBulkColumnReader.open(part_path, "v", sum_type)
      end
    end
  end

  it "rejects invalid grids and wrong state descriptors before creating or replacing output" do
    type = w223p_type("sum", CrystalClick::BinaryDataType.primitive("UInt64"))
    wrong_type = w223p_type("sumWithOverflow", CrystalClick::BinaryDataType.primitive("UInt64"))
    valid_value = CrystalClick::BinaryValue.aggregate_function_state(type, w223p_u64_bytes(42_u64))
    wrong_value = CrystalClick::BinaryValue.aggregate_function_state(wrong_type, w223p_u64_bytes(42_u64))

    w223p_parent do |parent|
      keep = File.join(parent, "keep.txt")
      File.write(keep, "preserve")
      destination = File.join(parent, "all_1_1_0")
      keys = [7_u64, 18_u64]
      wrong_rows = [[valid_value] of CrystalClick::BinaryValue]
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_and_aggregate_function_part(
          destination,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "v",
          type,
          wrong_rows,
          rows_per_mark: 1
        )
      end
      File.exists?(destination).should be_false
      Dir.children(parent).sort.should eq(["keep.txt"])

      wrong_descriptor_rows = [[wrong_value] of CrystalClick::BinaryValue]
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.write_uint64_and_aggregate_function_part(
          destination,
          "pk",
          Slice[7_u64],
          "v",
          type,
          wrong_descriptor_rows,
          rows_per_mark: 1
        )
      end
      File.exists?(destination).should be_false
      Dir.children(parent).sort.should eq(["keep.txt"])
      File.read(keep).should eq("preserve")
    end
  end

  it "does not expose a same-byte Sum state through the legacy Count accessor" do
    sum_type = w223p_type("sum", CrystalClick::BinaryDataType.primitive("UInt8"))
    sum_state = CrystalClick::BinaryValue.aggregate_function_state(sum_type, w223p_u64_bytes(42_u64))
    count_state = CrystalClick::BinaryValue.aggregate_count_state(
      CrystalClick::BinaryDataType.aggregate_count,
      42_u64
    )

    sum_state.aggregate_function_state_bytes.should eq(count_state.bytes)
    expect_raises(ArgumentError) { sum_state.count_state }
  end
end
