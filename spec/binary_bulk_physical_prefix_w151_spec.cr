require "./spec_helper"

private def w151_prefix_budget(
  max_bytes : Int,
  max_elements : Int,
  writing : Bool,
) : CrystalClick::BinaryCodecBudget
  limits = CrystalClick::BinaryCodecLimits.new(
    max_depth: 8,
    max_nodes: 32,
    max_elements: max_elements,
    max_bytes: max_bytes
  )
  CrystalClick::BinaryCodecBudget.new(limits, writing: writing)
end

describe "W151 paired Object Variant physical prefixes" do
  it "adds and strips the BASIC UInt64 zero discriminator header with rebased marks" do
    source = CrystalClick::BinaryBulkStream.new(
      Bytes[0x01, 0x00],
      [0_u64, 1_u64, 2_u64]
    )
    lanes = [{"root.discriminators", source, 8_i32}] of Tuple(
      String,
      CrystalClick::BinaryBulkStream,
      Int32,
    )
    write_budget = w151_prefix_budget(8, 3, true)

    CrystalClick::BinaryBulkPhysicalPrefixAdapter.preflight_write(lanes, write_budget)
    physical_bytes, physical_offsets, physical_prefix =
      CrystalClick::BinaryBulkPhysicalPrefixAdapter.write_lane(
        "root.discriminators", source, 8
      )

    physical_bytes.should eq(Bytes[0, 0, 0, 0, 0, 0, 0, 0, 0x01, 0x00])
    physical_offsets.should eq([8_u64, 9_u64, 10_u64])
    physical_prefix.should eq(8)

    read_budget = w151_prefix_budget(8, 3, false)
    read_work = [{"root.discriminators", 8, 3}] of Tuple(String, Int32, Int32)
    CrystalClick::BinaryBulkPhysicalPrefixAdapter.preflight_read(read_work, read_budget)
    logical_bytes, logical_offsets, logical_prefix =
      CrystalClick::BinaryBulkPhysicalPrefixAdapter.read_lane(
        "root.discriminators", physical_bytes, physical_offsets, 8
      )

    logical_bytes.should eq(Bytes[0x01, 0x00])
    logical_bytes.to_unsafe.should eq(physical_bytes[8, 2].to_unsafe)
    logical_offsets.should eq([0_u64, 1_u64, 2_u64])
    logical_prefix.should eq(0)
  end

  it "preserves ordinary and LowCardinality dictionary lanes without copying their payload bytes" do
    ordinary_bytes = Bytes[0xA5, 0x5A]
    ordinary_offsets = [0_u64, 1_u64, 2_u64]
    ordinary_write = CrystalClick::BinaryBulkStream.new(ordinary_bytes, ordinary_offsets)
    ordinary_write_budget = w151_prefix_budget(0, 3, true)
    ordinary_write_lanes = [{"root.arm.1.data", ordinary_write, 0_i32}] of Tuple(
      String,
      CrystalClick::BinaryBulkStream,
      Int32,
    )
    CrystalClick::BinaryBulkPhysicalPrefixAdapter.preflight_write(ordinary_write_lanes, ordinary_write_budget)
    ordinary_write_budget.wire_byte_count.should eq(0)
    ordinary_write_budget.element_count.should eq(3)
    ordinary_write_result = CrystalClick::BinaryBulkPhysicalPrefixAdapter.write_lane(
      "root.arm.1.data", ordinary_write, 0
    )
    ordinary_write_result[0].to_unsafe.should eq(ordinary_write.borrowed_slice(0, 2).to_unsafe)
    ordinary_write_result[1].should eq(ordinary_offsets)
    ordinary_write_result[2].should eq(0)

    ordinary_budget = w151_prefix_budget(0, 3, false)
    ordinary_work = [{"root.arm.1.data", 0, 3}] of Tuple(String, Int32, Int32)
    CrystalClick::BinaryBulkPhysicalPrefixAdapter.preflight_read(ordinary_work, ordinary_budget)
    ordinary_result, ordinary_result_offsets, ordinary_prefix =
      CrystalClick::BinaryBulkPhysicalPrefixAdapter.read_lane(
        "root.arm.1.data", ordinary_bytes, ordinary_offsets, 0
      )

    ordinary_result.should eq(ordinary_bytes)
    ordinary_result.to_unsafe.should eq(ordinary_bytes.to_unsafe)
    ordinary_result_offsets.should eq(ordinary_offsets)
    ordinary_prefix.should eq(0)

    dictionary_bytes = Bytes[0x01, 0, 0, 0, 0, 0, 0, 0, 0x44]
    dictionary_offsets = [8_u64, 9_u64]
    dictionary_write = CrystalClick::BinaryBulkStream.new(dictionary_bytes, dictionary_offsets)
    dictionary_write_budget = w151_prefix_budget(0, 2, true)
    dictionary_write_lanes = [{"root.arm.0.dictionary", dictionary_write, 8_i32}] of Tuple(
      String,
      CrystalClick::BinaryBulkStream,
      Int32,
    )
    CrystalClick::BinaryBulkPhysicalPrefixAdapter.preflight_write(dictionary_write_lanes, dictionary_write_budget)
    dictionary_write_budget.wire_byte_count.should eq(0)
    dictionary_write_budget.element_count.should eq(2)
    dictionary_write_result = CrystalClick::BinaryBulkPhysicalPrefixAdapter.write_lane(
      "root.arm.0.dictionary", dictionary_write, 8
    )
    dictionary_write_result[0].to_unsafe.should eq(dictionary_write.borrowed_slice(0, 9).to_unsafe)
    dictionary_write_result[1].should eq(dictionary_offsets)
    dictionary_write_result[2].should eq(8)

    dictionary_budget = w151_prefix_budget(0, 2, false)
    dictionary_work = [{"root.arm.0.dictionary", 8, 2}] of Tuple(String, Int32, Int32)
    CrystalClick::BinaryBulkPhysicalPrefixAdapter.preflight_read(dictionary_work, dictionary_budget)
    dictionary_result, dictionary_result_offsets, dictionary_prefix =
      CrystalClick::BinaryBulkPhysicalPrefixAdapter.read_lane(
        "root.arm.0.dictionary", dictionary_bytes, dictionary_offsets, 8
      )

    dictionary_result.should eq(dictionary_bytes)
    dictionary_result.to_unsafe.should eq(dictionary_bytes.to_unsafe)
    dictionary_result_offsets.should eq(dictionary_offsets)
    dictionary_prefix.should eq(8)
  end

  it "aggregates transformed headers and copied coordinate grids before adapting two discriminator lanes" do
    first = CrystalClick::BinaryBulkStream.new(Bytes[0x00], [0_u64, 1_u64])
    second = CrystalClick::BinaryBulkStream.new(Bytes[0x01], [0_u64, 1_u64])
    lanes = [
      {"root.discriminators", first, 8_i32},
      {"root.arm.0.discriminators", second, 8_i32},
    ] of Tuple(String, CrystalClick::BinaryBulkStream, Int32)

    exact = w151_prefix_budget(16, 4, true)
    CrystalClick::BinaryBulkPhysicalPrefixAdapter.preflight_write(lanes, exact)
    a_result = CrystalClick::BinaryBulkPhysicalPrefixAdapter.write_lane(
      "root.discriminators", first, 8
    )
    b_result = CrystalClick::BinaryBulkPhysicalPrefixAdapter.write_lane(
      "root.arm.0.discriminators", second, 8
    )
    a_bytes = a_result[0]
    a_offsets = a_result[1]
    b_bytes = b_result[0]
    b_offsets = b_result[1]
    a_bytes.size.should eq(9)
    b_bytes.size.should eq(9)
    a_offsets.should eq([8_u64, 9_u64])
    b_offsets.should eq([8_u64, 9_u64])

    one_byte_short = w151_prefix_budget(15, 4, true)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkPhysicalPrefixAdapter.preflight_write(lanes, one_byte_short)
    end

    one_coordinate_short = w151_prefix_budget(16, 3, true)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkPhysicalPrefixAdapter.preflight_write(lanes, one_coordinate_short)
    end
  end

  it "charges read-side coordinate rebasing through one aggregate operation budget" do
    exact = w151_prefix_budget(16, 4, false)
    work = [
      {"root.discriminators", 8, 2},
      {"root.arm.0.discriminators", 8, 2},
    ] of Tuple(String, Int32, Int32)

    CrystalClick::BinaryBulkPhysicalPrefixAdapter.preflight_read(work, exact)

    one_byte_short = w151_prefix_budget(15, 4, false)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkPhysicalPrefixAdapter.preflight_read(work, one_byte_short)
    end
    one_coordinate_short = w151_prefix_budget(16, 3, false)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkPhysicalPrefixAdapter.preflight_read(work, one_coordinate_short)
    end
  end

  it "rejects mode-confused discriminator headers, dictionary versions, and short prefix coordinates" do
    bad_discriminator_mode = Bytes[0x01, 0, 0, 0, 0, 0, 0, 0, 0x00]
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkPhysicalPrefixAdapter.read_lane(
        "root.discriminators", bad_discriminator_mode, [8_u64, 9_u64], 8
      )
    end

    bad_dictionary_version = Bytes[0x00, 0, 0, 0, 0, 0, 0, 0, 0x44]
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkPhysicalPrefixAdapter.read_lane(
        "root.arm.0.dictionary", bad_dictionary_version, [8_u64, 9_u64], 8
      )
    end

    short_discriminator_coordinate = Bytes[0, 0, 0, 0, 0, 0, 0, 0, 0x00]
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkPhysicalPrefixAdapter.read_lane(
        "root.discriminators", short_discriminator_coordinate, [7_u64, 9_u64], 8
      )
    end
  end
end
