require "./spec_helper"
require "file_utils"

private def w213_physical_json_type : CrystalClick::BinaryDataType
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  CrystalClick::BinaryDataType.json(
    max_dynamic_paths: 1,
    max_dynamic_types: 1,
    typed_paths: {"id" => uint8} of String => CrystalClick::BinaryDataType,
  )
end

private def w213_physical_json_value(type : CrystalClick::BinaryDataType, id : UInt8) : CrystalClick::BinaryValue
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  row = CrystalClick::BinaryJsonRow.new(
    type,
    [{"id", CrystalClick::BinaryValue.fixed(uint8, Bytes[id])}] of Tuple(String, CrystalClick::BinaryValue),
  )
  CrystalClick::BinaryValue.json(type, row)
end

private def w213_physical_expect_grids_equal!(
  actual : Array(Array(CrystalClick::BinaryValue)),
  expected : Array(Array(CrystalClick::BinaryValue)),
) : Nil
  actual.size.should eq(expected.size)
  actual.each_with_index do |rows, mark|
    rows.size.should eq(expected[mark].size)
    rows.each_with_index do |value, row|
      CrystalClick::BinaryValueCodec.encode(value).should eq(
        CrystalClick::BinaryValueCodec.encode(expected[mark][row])
      )
    end
  end
end

describe "W213 Dynamic SharedVariant inline JSON physical path" do
  it "writes and reads root Dynamic JSON through both automatic typed-table String profiles" do
    json = w213_physical_json_type
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    structures = {
      "root" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType),
    }
    granules = [
      [CrystalClick::BinaryValue.dynamic(dynamic, w213_physical_json_value(json, 21_u8))] of CrystalClick::BinaryValue,
      [CrystalClick::BinaryValue.dynamic(dynamic, w213_physical_json_value(json, 22_u8))] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)

    profiles = [
      CrystalClick::BinaryBulkProfile.single_stream,
      CrystalClick::BinaryBulkProfile.with_size_stream,
    ] of CrystalClick::BinaryBulkProfile
    profiles.each do |profile|
      parent = File.tempname("crystal-click-w213-shared-json-")
      Dir.mkdir(parent)
      begin
        part = File.join(parent, "all_1_1_0")
        CrystalClick::WidePartWriter.write_uint64_dynamic_bulk_part(
          part,
          "pk",
          Slice[1_u64, 2_u64],
          "payload",
          dynamic,
          structures,
          granules,
          rows_per_mark: 1,
          profile: profile,
        ).should eq(part)

        reader = CrystalClick::DynamicBulkColumnReader.open(part, "payload", dynamic)
        reader.ordinary_profile.should eq(profile)
        reader.mark_row_counts.should eq([1_u64, 1_u64])
        w213_physical_expect_grids_equal!(reader.read_marks(0, reader.mark_count), granules)

        table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
        observed = Array(Array(CrystalClick::BinaryValue)).new(granules.size) do
          [] of CrystalClick::BinaryValue
        end
        table.scan_typed do |batch|
          observed[batch.mark_index] = batch.dynamic_bulk_values_for("payload").to_a
        end
        w213_physical_expect_grids_equal!(observed, granules)

        middle = [] of CrystalClick::BinaryValue
        table.scan_typed_candidate_marks([[1_i32]]) do |batch|
          batch.mark_index.should eq(1)
          middle.concat(batch.dynamic_bulk_values_for("payload").to_a)
        end
        w213_physical_expect_grids_equal!([middle], [granules[1]])

        eof_callbacks = 0
        table.scan_typed_window(table.total_row_count, max_rows: 1) do |_batch|
          eof_callbacks += 1
        end
        eof_callbacks.should eq(0)
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "rejects an over-depth inline JSON value before publishing a physical part" do
    json = w213_physical_json_type
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    structures = {
      "root" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType),
    }
    granules = [
      [CrystalClick::BinaryValue.dynamic(dynamic, w213_physical_json_value(json, 31_u8))] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)
    limits = CrystalClick::BinaryCodecLimits.new(
      max_depth: 2,
      max_nodes: 256,
      max_elements: 256,
      max_bytes: 4096,
    )

    parent = File.tempname("crystal-click-w213-json-depth-")
    Dir.mkdir(parent)
    begin
      part = File.join(parent, "all_1_1_0")
      expect_raises(CrystalClick::UnsupportedFormatError, "depth") do
        CrystalClick::WidePartWriter.write_uint64_dynamic_bulk_part(
          part,
          "pk",
          Slice[1_u64],
          "payload",
          dynamic,
          structures,
          granules,
          rows_per_mark: 1,
          limits: limits,
        )
      end
      File.exists?(part).should be_false
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
