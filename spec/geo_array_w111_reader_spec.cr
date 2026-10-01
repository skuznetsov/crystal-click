require "./spec_helper"

private def w111_geo_u64_bytes(values : Array(UInt64)) : Bytes
  bytes = Bytes.new(values.size * 8, 0_u8)
  values.each_with_index do |value, row|
    8.times { |index| bytes[row * 8 + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
  end
  bytes
end

private def w111_geo_float_bytes(values : Array(Float64)) : Bytes
  w111_geo_u64_bytes(values.map { |value| value.unsafe_as(UInt64) })
end

private def w111_geo_decode_u64(bytes : Bytes, offset : Int32) : UInt64
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

private def w111_geo_depth3_payloads(
  size0 : Array(Array(UInt64)),
  size1 : Array(Array(UInt64)),
  size2 : Array(Array(UInt64)),
  x_by_mark : Array(Array(Float64)),
  y_by_mark : Array(Array(Float64)),
) : Hash(String, Array(Bytes))
  {
    "shape.size0" => size0.map { |values| w111_geo_u64_bytes(values) },
    "shape.size1" => size1.map { |values| w111_geo_u64_bytes(values) },
    "shape.size2" => size2.map { |values| w111_geo_u64_bytes(values) },
    "shape%2E1"   => x_by_mark.map { |values| w111_geo_float_bytes(values) },
    "shape%2E2"   => y_by_mark.map { |values| w111_geo_float_bytes(values) },
  }
end

class CrystalClick::WidePart
  class W111GeoArrayReaderHarness
    getter reader : GeoArrayReader
    getter read_calls : Array(Tuple(String, Int32))
    getter validate_calls : Array(Tuple(String, Int32))
    getter uint64_decode_calls : Int32
    getter float64_decode_calls : Int32

    @rows_by_mark : Array(UInt64)
    @payloads : Hash(String, Array(Bytes))
    @corrupt_boundary : Tuple(String, Int32)?

    def initialize(
      @rows_by_mark : Array(UInt64),
      @payloads : Hash(String, Array(Bytes)),
      @corrupt_boundary : Tuple(String, Int32)? = nil,
    )
      @read_calls = [] of Tuple(String, Int32)
      @validate_calls = [] of Tuple(String, Int32)
      @uint64_decode_calls = 0
      @float64_decode_calls = 0
      plan = GeoArrayColumnType.for_type("MultiPolygon").not_nil!
      @reader = GeoArrayReader.new(
        plan,
        "shape",
        ->(_stream : String, first : Int32, count : Int32) {
          rows = 0_u64
          count.times { |offset| rows += @rows_by_mark[first + offset] }
          rows
        },
        ->(_stream : String, mark : Int32) { @rows_by_mark[mark] },
        ->(stream : String, first : Int32, count : Int32, expected_bytes : Int32, _width : Int32, _rows : UInt64) {
          @read_calls << {stream, first}
          parts = Array(Bytes).new(count)
          total_bytes = 0
          count.times do |offset|
            part = @payloads[stream][first + offset]
            parts << part
            total_bytes += part.size
          end
          raise CrystalClick::CorruptPartError.new("synthetic selected byte count differs") unless total_bytes == expected_bytes
          bytes = Bytes.new(total_bytes)
          cursor = 0
          parts.each do |part|
            part.each do |byte|
              bytes[cursor] = byte
              cursor += 1
            end
          end
          bytes
        },
        ->(stream : String, first : Int32, count : Int32, expected_bytes : Int32, _width : Int32, _rows : UInt64) {
          raise CrystalClick::CorruptPartError.new("synthetic range validates one mark at a time") unless count == 1
          @validate_calls << {stream, first}
          if @corrupt_boundary == {stream, first}
            raise CrystalClick::CorruptPartError.new("seeded later Geo Array boundary defect")
          end
          bytes = @payloads[stream][first]
          raise CrystalClick::CorruptPartError.new("synthetic selected boundary differs") unless bytes.size == expected_bytes
          nil
        },
        ->(bytes : Bytes, offset : Int32) {
          @uint64_decode_calls += 1
          w111_geo_decode_u64(bytes, offset)
        },
        ->(bytes : Bytes, offset : Int32) {
          @float64_decode_calls += 1
          w111_geo_decode_u64(bytes, offset).unsafe_as(Float64)
        }
      )
    end
  end
end

describe "W111 bounded Geo Array reader" do
  it "discovers ragged depth cardinalities while retaining outer mark rows and exact Point bits" do
    payloads = w111_geo_depth3_payloads(
      [[2_u64], [0_u64]],
      [[1_u64, 2_u64], [] of UInt64],
      [[1_u64, 0_u64, 1_u64], [] of UInt64],
      [[10.5_f64, -0.0_f64], [] of Float64],
      [[-7.25_f64, 0x7ff8_0000_0000_0042_u64.unsafe_as(Float64)], [] of Float64],
    )
    harness = CrystalClick::WidePart::W111GeoArrayReaderHarness.new([1_u64, 1_u64], payloads)
    data = harness.reader.read(0, 2, CrystalClick::GeoArrayColumnType::MAX_MATERIALIZED_BYTES)

    data.type_name.should eq("MultiPolygon")
    data.row_count.should eq(2)
    data.point_count.should eq(2)
    data.topology.level_counts.should eq([2_u64, 2_u64, 3_u64])
    data.topology.sizes(0).should eq([2_u64, 0_u64])
    data.topology.sizes(1).should eq([1_u64, 2_u64])
    data.topology.sizes(2).should eq([1_u64, 0_u64, 1_u64])
    data.row(0).size.should eq(2)
    data.row(0).array_at(1).array_at(1).point_at(0).x_bits.should eq(0x8000_0000_0000_0000_u64)
    data.row(0).array_at(1).array_at(1).point_at(0).y_bits.should eq(0x7ff8_0000_0000_0042_u64)
    data.row(1).size.should eq(0)
    harness.float64_decode_calls.should eq(4)
  end

  it "preflights all selected later coordinate boundaries before reads, Float64 decoding or row callbacks" do
    payloads = w111_geo_depth3_payloads(
      [[1_u64], [1_u64]],
      [[1_u64], [1_u64]],
      [[1_u64], [1_u64]],
      [[1.0_f64], [2.0_f64]],
      [[3.0_f64], [4.0_f64]],
    )
    harness = CrystalClick::WidePart::W111GeoArrayReaderHarness.new(
      [1_u64, 1_u64],
      payloads,
      {"shape%2E2", 1}
    )
    yielded = 0

    # The earlier-only window remains independent of an unselected later mark.
    earlier = harness.reader.read(0, 1, CrystalClick::GeoArrayColumnType::MAX_MATERIALIZED_BYTES)
    earlier.point_count.should eq(1)
    harness.read_calls.clear
    harness.validate_calls.clear
    harness.float64_decode_calls.should eq(2)

    expect_raises(CrystalClick::CorruptPartError, "seeded later Geo Array boundary defect") do
      harness.reader.each(0, 2, CrystalClick::GeoArrayColumnType::MAX_MATERIALIZED_BYTES) do |_data, _mark|
        yielded += 1
        nil
      end
    end
    harness.read_calls.none? { |stream, _mark| stream == "shape%2E1" || stream == "shape%2E2" }.should be_true
    harness.float64_decode_calls.should eq(2)
    yielded.should eq(0)
  end

  it "rejects a cap-minus-one charge before any coordinate boundary, read or decoder callback" do
    payloads = w111_geo_depth3_payloads(
      [[1_u64], [1_u64]],
      [[1_u64], [1_u64]],
      [[1_u64], [1_u64]],
      [[1.0_f64], [2.0_f64]],
      [[3.0_f64], [4.0_f64]],
    )
    charge_harness = CrystalClick::WidePart::W111GeoArrayReaderHarness.new([1_u64, 1_u64], payloads)
    exact_charge = charge_harness.reader.materialization_charge(
      0,
      2,
      CrystalClick::GeoArrayColumnType::MAX_MATERIALIZED_BYTES
    )
    charge_harness.validate_calls.any? { |stream, _mark| stream == "shape%2E1" || stream == "shape%2E2" }.should be_false
    charge_harness.float64_decode_calls.should eq(0)

    exact_budget = CrystalClick::WidePart::W111GeoArrayReaderHarness.new([1_u64, 1_u64], payloads)
    exact_data = exact_budget.reader.read(0, 2, exact_charge)
    exact_data.point_count.should eq(2)
    exact_budget.float64_decode_calls.should eq(4)

    limited = CrystalClick::WidePart::W111GeoArrayReaderHarness.new([1_u64, 1_u64], payloads)
    expect_raises(CrystalClick::CorruptPartError) do
      limited.reader.read(0, 2, exact_charge - 1_u64)
    end
    limited.validate_calls.any? { |stream, _mark| stream == "shape%2E1" || stream == "shape%2E2" }.should be_false
    limited.read_calls.any? { |stream, _mark| stream == "shape%2E1" || stream == "shape%2E2" }.should be_false
    limited.float64_decode_calls.should eq(0)
  end

  it "validates zero-byte deeper and coordinate frames for an empty nested branch" do
    payloads = w111_geo_depth3_payloads(
      [[0_u64]],
      [[] of UInt64],
      [[] of UInt64],
      [[] of Float64],
      [[] of Float64],
    )
    harness = CrystalClick::WidePart::W111GeoArrayReaderHarness.new([1_u64], payloads)
    data = harness.reader.read(0, 1, CrystalClick::GeoArrayColumnType::MAX_MATERIALIZED_BYTES)

    data.row_count.should eq(1)
    data.point_count.should eq(0)
    data.row(0).size.should eq(0)
    {"shape.size1", "shape.size2", "shape%2E1", "shape%2E2"}.each do |stream|
      harness.validate_calls.includes?({stream, 0}).should be_true
      harness.read_calls.includes?({stream, 0}).should be_true
    end
  end
end
