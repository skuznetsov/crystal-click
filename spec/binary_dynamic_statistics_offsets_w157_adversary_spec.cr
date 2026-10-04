require "./spec_helper"

private def w157a_empty_raw : Bytes
  Bytes[0x04_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8]
end

private def w157a_present_raw : Bytes
  # V3, one UInt64 descriptor, statistics flag, two canonical counts, no shared entries.
  Bytes[0x04_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 1_u8, 0x04_u8, 1_u8, 3_u8, 7_u8, 0_u8]
end

private def w157a_budget_counts(budget : CrystalClick::BinaryCodecBudget) : Tuple(Int64, Int64, Int64)
  {budget.node_count, budget.element_count, budget.wire_byte_count}
end

private def w157a_files(data : Bytes, marks : Bytes, &)
  data_path = File.tempname("crystal-click-w157-data")
  marks_path = File.tempname("crystal-click-w157-marks")
  begin
    File.open(data_path, "wb") { |io| io.write(data) }
    File.open(marks_path, "wb") { |io| io.write(marks) }
    yield data_path, marks_path
  ensure
    File.delete(data_path) if File.exists?(data_path)
    File.delete(marks_path) if File.exists?(marks_path)
  end
end

describe "W157 Dynamic statistics-offset adversaries" do
  it "keeps empty and present suffixes occurrence-local through a precharged shared writer budget" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    declared = CrystalClick::BinaryDataType.tuple([dynamic, dynamic] of CrystalClick::BinaryDataType)
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    empty = CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)
    present = CrystalClick::DynamicStructure.new(
      [uint64] of CrystalClick::BinaryDataType,
      CrystalClick::StructureStatistics.new([3_u64, 7_u64], [] of CrystalClick::StructureStatistic),
    )
    paths = ["root.field.0", "root.field.1"] of String
    structures = {paths[0] => empty, paths[1] => present}
    literals = {paths[0] => w157a_empty_raw, paths[1] => w157a_present_raw}
    expected = {paths[0] => 9_i32, paths[1] => 10_i32}

    baseline_write = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true)
    baseline_plan = CrystalClick::BinaryDynamicBulkPlan.new_with_budget(declared, structures, baseline_write)
    baseline_planned_counts = w157a_budget_counts(baseline_write)
    write_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true)
    write_budget.charge_node
    write_budget.charge_elements(2_u64)
    write_budget.charge_wire_bytes(5_u64)
    write_precharged = w157a_budget_counts(write_budget)
    write_plan = CrystalClick::BinaryDynamicBulkPlan.new_with_budget(declared, structures, write_budget)
    planned_counts = w157a_budget_counts(write_budget)
    3.times do |index|
      planned_counts[index].should eq(baseline_planned_counts[index] + write_precharged[index])
    end
    paths.each { |path| write_plan.statistics_offset_for(path).should eq(expected[path]) }
    write_before = w157a_budget_counts(write_budget)
    20.times { paths.reverse_each { |path| write_plan.statistics_offset_for(path).should eq(expected[path]) } }
    w157a_budget_counts(write_budget).should eq(write_before)

    encoded = write_plan.encode_structure_streams(write_budget)
    baseline_plan.encode_structure_streams(baseline_write)
    paths.each { |path| encoded.structure_bytes_for(path).should eq(literals[path]) }
    encoded_counts = w157a_budget_counts(write_budget)
    baseline_encoded_counts = w157a_budget_counts(baseline_write)
    3.times do |index|
      encoded_counts[index].should eq(baseline_encoded_counts[index] + write_precharged[index])
    end
    20.times { paths.each { |path| write_plan.statistics_offset_for(path).should eq(expected[path]) } }
    w157a_budget_counts(write_budget).should eq(encoded_counts)

    baseline_read = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
    CrystalClick::BinaryDynamicBulkPlan.decode_structure_streams(
      declared, CrystalClick::BinaryDynamicStructureStreams.new(literals), baseline_read,
    )
    baseline_decoded_counts = w157a_budget_counts(baseline_read)
    read_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
    read_budget.charge_node
    read_budget.charge_elements(2_u64)
    read_budget.charge_wire_bytes(5_u64)
    read_precharged = w157a_budget_counts(read_budget)
    decoded = CrystalClick::BinaryDynamicBulkPlan.decode_structure_streams(
      declared, CrystalClick::BinaryDynamicStructureStreams.new(literals), read_budget,
    )
    decoded_counts = w157a_budget_counts(read_budget)
    3.times do |index|
      decoded_counts[index].should eq(baseline_decoded_counts[index] + read_precharged[index])
    end
    read_counts = w157a_budget_counts(read_budget)
    20.times { paths.reverse_each { |path| decoded.statistics_offset_for(path).should eq(expected[path]) } }
    w157a_budget_counts(read_budget).should eq(read_counts)
    decoded.structure_for(paths[0]).statistics.should be_nil
    decoded.structure_for(paths[1]).statistics.not_nil!.counts.should eq([3_u64, 7_u64])
  end

  it "rejects invalid statistics flags and otherwise-valid metadata with trailing bytes" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    invalid_flag = w157a_empty_raw.dup
    invalid_flag[9] = 2_u8
    base = w157a_empty_raw
    trailing = Bytes.new(base.size + 1) do |index|
      index < base.size ? base[index] : 0xaa_u8
    end

    {invalid_flag, trailing}.each do |raw|
      streams = CrystalClick::BinaryDynamicStructureStreams.new({"root" => raw})
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryDynamicBulkPlan.decode_structure_streams(
          dynamic, streams, CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
        )
      end
    end
  end

  it "requires every real metadata mark at the literal statistics boundary and the sentinel at EOF" do
    raw = w157a_present_raw
    literal_offset = 10
    files = CrystalClick::CompressedMarkWriter.encode_metadata(
      raw, literal_offset, [2_u64, 2_u64, 2_u64], frame_bytes: 4)
    w157a_files(files.data, files.marks) do |data_path, marks_path|
      grid = CrystalClick::CompressedMarkReader.inspect(
        data_path, marks_path, File.size(data_path), File.size(marks_path), prefix_size: literal_offset)
      grid.prefix_size.should eq(literal_offset)
      grid.logical_size.should eq(raw.size.to_i64)
      grid.positions.should eq([10_i64, 10_i64, 10_i64, raw.size.to_i64])
      grid.rows_per_mark.should eq([2_u64, 2_u64, 2_u64])

      # EOF is not a substitute for the statistics flag boundary.
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompressedMarkReader.inspect(
          data_path, marks_path, File.size(data_path), File.size(marks_path), prefix_size: raw.size)
      end
    end
  end
end
