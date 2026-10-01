require "./spec_helper"
require "file_utils"

private def w109r_write_part(
  parent : String,
  key_name : String,
  point_name : String,
  values : Array(CrystalClick::WidePointValue),
  rows_per_mark : Int32,
) : String
  destination = File.join(parent, "all_1_1_0")
  keys = Array(UInt64).new(values.size) { |index| (index + 10).to_u64 }
  CrystalClick::WidePartWriter.write_uint64_point_pair(
    destination,
    key_name,
    keys.to_unsafe.to_slice(keys.size),
    point_name,
    values.to_unsafe.to_slice(values.size),
    rows_per_mark: rows_per_mark
  )
end

private def w109r_profile_json(
  columns_json : String,
  version : Int32 = 1,
  string_version : Int32 = 1,
  propagated : String = "true",
) : String
  %({"version":#{version},"columns":#{columns_json},"types_serialization_versions":{"string":#{string_version}},"propagate_types_serialization_versions_to_nested_types":#{propagated}})
end

private def w109r_validate_profile(text : String) : Nil
  CrystalClick::PointSerializationProfile.validate!(
    text,
    [{"a", "UInt64"}, {"z", "Point"}],
    "z",
    3_u64
  )
end

private def w109r_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

private def w109r_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w109r_shift_mark_boundary(part : String, stream_name : String, mark_index : Int32) : Nil
  mark_path = File.join(part, "#{CrystalClick::StreamName.hash(stream_name)}.mrk2")
  marks = File.read(mark_path).to_slice.dup
  offset = mark_index * CrystalClick::WidePart::MARK_SIZE + 8
  w109r_write_u64(marks, offset, w109r_u64(marks, offset) + 8_u64)
  File.write(mark_path, marks)
end

describe CrystalClick::WidePart do
  it "preserves exact Point identity and raw IEEE bits across selected ranges and lazy marks" do
    parent = File.tempname("crystal-click-point-w109-reader")
    Dir.mkdir(parent)
    values = [
      CrystalClick::WidePointValue.from_bits(0x8000_0000_0000_0000_u64, 0_u64),
      CrystalClick::WidePointValue.from_bits(0x7ff8_0000_0000_0042_u64, 0xfff0_0000_0000_0000_u64),
      CrystalClick::WidePointValue.new(1.25, -3.5),
    ]

    begin
      # "a" sorts before "z"; profile validation must bind records by name,
      # not assume the selected Point is serializer record zero.
      part = w109r_write_part(parent, "a", "z", values, 2)
      reader = CrystalClick::WidePart.open_typed(part, "z")
      reader.column_type.should eq("Point")
      reader.mark_row_counts.should eq([2_u64, 1_u64])

      plan = CrystalClick::PointColumnType.for_type(reader.column_type).not_nil!
      plan.coordinate_streams("z").should eq({"z%2E1", "z%2E2"})
      plan.physical_streams("z").should eq([{"z%2E1", 8}, {"z%2E2", 8}])

      exact_charge = reader.point_mark_range_materialization_charge("z", 0, 2)
      all = reader.read_point_mark_range("z", 0, 2, exact_charge)
      all.size.should eq(values.size)
      all.zip(values).each { |actual, expected| actual.same_bits?(expected).should be_true }
      expect_raises(CrystalClick::CorruptPartError) do
        reader.read_point_mark_range("z", 0, 2, exact_charge - 1_u64)
      end

      selected = reader.read_point_mark_range("z", 1, 1)
      selected.size.should eq(1)
      selected.first.same_bits?(values[2]).should be_true

      mark_indexes = [] of Int32
      observed = [] of CrystalClick::WidePointValue
      reader.each_point_mark_range("z", 0, 2) do |mark_values, mark_index|
        mark_indexes << mark_index
        observed.concat(mark_values)
        nil
      end
      mark_indexes.should eq([0_i32, 1_i32])
      observed.zip(values).each { |actual, expected| actual.same_bits?(expected).should be_true }

      expect_raises(CrystalClick::BoundsError) { reader.read_point_mark_range("z", -1, 1) }
      expect_raises(CrystalClick::BoundsError) { reader.read_point_mark_range("z", 0, 0) }
      expect_raises(CrystalClick::BoundsError) { reader.read_point_mark_range("z", UInt64::MAX, 1_u64) }
      expect_raises(CrystalClick::BoundsError) { reader.read_point_mark_range("z", 0, UInt64::MAX) }
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "accepts only the exact empty Default-statistics envelope" do
    w109r_validate_profile(w109r_profile_json("[]"))

    # Missing and malformed envelope fields remain invalid even when the
    # per-column statistics array is empty.
    missing_columns = %({"version":1,"types_serialization_versions":{"string":1},"propagate_types_serialization_versions_to_nested_types":true})
    expect_raises(CrystalClick::UnsupportedFormatError) do
      w109r_validate_profile(missing_columns)
    end

    malformed_columns = %({"version":1,"columns":"[]","types_serialization_versions":{"string":1},"propagate_types_serialization_versions_to_nested_types":true})
    expect_raises(CrystalClick::CorruptPartError) do
      w109r_validate_profile(malformed_columns)
    end

    malformed_empty_envelope = %({"version":1,"columns":[],"types_serialization_versions":{"string":1}})
    expect_raises(CrystalClick::UnsupportedFormatError) do
      w109r_validate_profile(malformed_empty_envelope)
    end

    unknown_envelope_field = %({"version":1,"columns":[],"types_serialization_versions":{"string":1},"propagate_types_serialization_versions_to_nested_types":true,"extra":0})
    expect_raises(CrystalClick::UnsupportedFormatError) do
      w109r_validate_profile(unknown_envelope_field)
    end

    partial_records = %([{"kind":"Default","name":"z","num_defaults":0,"num_rows":3,"subcolumns":[]}])
    expect_raises(CrystalClick::UnsupportedFormatError) do
      w109r_validate_profile(w109r_profile_json(partial_records))
    end

    point_record = %({"kind":"Default","name":"z","num_defaults":0,"num_rows":3,"subcolumns":[{"kind":"Default","num_defaults":0,"num_rows":3},{"kind":"Default","num_defaults":0,"num_rows":3}]})
    sparse_key_record = %({"kind":"Sparse","name":"a","num_defaults":0,"num_rows":3})
    sparse_records = "[#{point_record},#{sparse_key_record}]"
    expect_raises(CrystalClick::UnsupportedFormatError) do
      w109r_validate_profile(w109r_profile_json(sparse_records))
    end

    expect_raises(CrystalClick::UnsupportedFormatError) do
      w109r_validate_profile(w109r_profile_json("[]", version: 2))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      w109r_validate_profile(w109r_profile_json("[]", string_version: 2))
    end
  end

  it "still rejects physical coordinate corruption with empty Default statistics" do
    parent = File.tempname("crystal-click-point-w109-empty-stat-corrupt")
    Dir.mkdir(parent)
    values = [
      CrystalClick::WidePointValue.new(1.0, 2.0),
      CrystalClick::WidePointValue.new(3.0, 4.0),
      CrystalClick::WidePointValue.new(5.0, 6.0),
    ]

    begin
      part = w109r_write_part(parent, "a", "z", values, 1)
      File.write(File.join(part, "serialization.json"), w109r_profile_json("[]"))
      w109r_shift_mark_boundary(part, "z%2E2", 2)

      reader = CrystalClick::WidePart.open_typed(part, "z")
      expect_raises(CrystalClick::CorruptPartError) do
        reader.read_point_mark_range("z", 0, 3)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
