require "./spec_helper"

private def w112m_u64_bytes(values : Array(UInt64)) : Bytes
  bytes = Bytes.new(values.size * 8, 0_u8)
  values.each_with_index do |value, row|
    8.times { |index| bytes[row * 8 + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
  end
  bytes
end

private def w112m_float_bytes(values : Array(Float64)) : Bytes
  w112m_u64_bytes(values.map { |value| value.unsafe_as(UInt64) })
end

private def w112m_payloads(
  sizes_by_mark : Array(Array(UInt64)),
  x_by_mark : Array(Array(Float64)),
  y_by_mark : Array(Array(Float64)),
) : Hash(String, Array(Bytes))
  {
    "shape.size0" => sizes_by_mark.map { |values| w112m_u64_bytes(values) },
    "shape%2E1"   => x_by_mark.map { |values| w112m_float_bytes(values) },
    "shape%2E2"   => y_by_mark.map { |values| w112m_float_bytes(values) },
  }
end

private def w112m_decode_u64(bytes : Bytes, offset : Int32) : UInt64
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

class CrystalClick::WidePart
  class W112MultiPointReaderHarness
    getter reader : GeoArrayReader
    getter read_calls : Array(Tuple(String, Int32))
    getter validate_calls : Array(Tuple(String, Int32))
    getter uint64_decode_calls : Int32
    getter float64_decode_calls : Int32

    @rows_by_mark : Array(UInt64)
    @payloads : Hash(String, Array(Bytes))
    @corrupt_boundary : Tuple(String, Int32)?

    def initialize(
      sizes_by_mark : Array(Array(UInt64)),
      x_by_mark : Array(Array(Float64)),
      y_by_mark : Array(Array(Float64)),
      @corrupt_boundary : Tuple(String, Int32)? = nil,
    )
      @rows_by_mark = sizes_by_mark.map(&.size.to_u64)
      @payloads = w112m_payloads(sizes_by_mark, x_by_mark, y_by_mark)
      @read_calls = [] of Tuple(String, Int32)
      @validate_calls = [] of Tuple(String, Int32)
      @uint64_decode_calls = 0
      @float64_decode_calls = 0
      @reader = GeoArrayReader.new(
        GeoArrayColumnType.for_type("MultiPoint").not_nil!,
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
          raise CrystalClick::CorruptPartError.new("W112 synthetic selected byte count differs") unless total_bytes == expected_bytes
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
          raise CrystalClick::CorruptPartError.new("W112 synthetic boundary validates one mark at a time") unless count == 1
          @validate_calls << {stream, first}
          if @corrupt_boundary == {stream, first}
            raise CrystalClick::CorruptPartError.new("seeded selected MultiPoint boundary defect")
          end
          bytes = @payloads[stream][first]
          raise CrystalClick::CorruptPartError.new("W112 synthetic selected boundary differs") unless bytes.size == expected_bytes
          nil
        },
        ->(bytes : Bytes, offset : Int32) {
          @uint64_decode_calls += 1
          w112m_decode_u64(bytes, offset)
        },
        ->(bytes : Bytes, offset : Int32) {
          @float64_decode_calls += 1
          w112m_decode_u64(bytes, offset).unsafe_as(Float64)
        }
      )
    end
  end
end

describe "W112 MultiPoint reader" do
  it "preserves exact nominal identity and reads a selected nonzero mark with its own origin" do
    sizes = [[2_u64, 0_u64], [1_u64, 2_u64]]
    xs = [[10.0_f64, 20.0_f64], [30.0_f64, 40.0_f64, 50.0_f64]]
    ys = [[-1.0_f64, -2.0_f64], [-3.0_f64, -4.0_f64, -5.0_f64]]
    harness = CrystalClick::WidePart::W112MultiPointReaderHarness.new(sizes, xs, ys)
    plan = CrystalClick::GeoArrayColumnType.for_type("MultiPoint").not_nil!

    plan.type_name.should eq("MultiPoint")
    plan.depth.should eq(1)
    plan.size_streams("shape").should eq(["shape.size0"])
    plan.coordinate_streams("shape").should eq({"shape%2E1", "shape%2E2"})

    data = harness.reader.read(1, 1, CrystalClick::GeoArrayColumnType::MAX_MATERIALIZED_BYTES)
    data.type_name.should eq("MultiPoint")
    data.row_count.should eq(2)
    data.point_count.should eq(3)
    data.row(0).size.should eq(1)
    data.row(0).point_at(0).x.should eq(30.0)
    data.row(1).size.should eq(2)
    data.row(1).point_at(1).y.should eq(-5.0)
    harness.float64_decode_calls.should eq(6)
  end

  it "keeps empty MultiPoint values as rows and validates zero-byte coordinate frames" do
    sizes = [[0_u64, 0_u64], [0_u64]]
    empty = [[] of Float64, [] of Float64]
    harness = CrystalClick::WidePart::W112MultiPointReaderHarness.new(sizes, empty, empty)
    yielded = 0

    harness.reader.each(0, 2, CrystalClick::GeoArrayColumnType::MAX_MATERIALIZED_BYTES) do |data, mark|
      data.type_name.should eq("MultiPoint")
      data.point_count.should eq(0)
      data.row_count.should eq(sizes[mark].size)
      data.row_count.times { |index| data.row(index).size.should eq(0) }
      yielded += 1
      nil
    end

    yielded.should eq(2)
    harness.float64_decode_calls.should eq(0)
    {"shape%2E1", "shape%2E2"}.each do |stream|
      harness.validate_calls.includes?({stream, 0}).should be_true
      harness.validate_calls.includes?({stream, 1}).should be_true
      harness.read_calls.includes?({stream, 0}).should be_true
      harness.read_calls.includes?({stream, 1}).should be_true
    end
  end

  it "preflights every selected later coordinate boundary before reads or callbacks" do
    sizes = [[1_u64, 0_u64], [2_u64, 0_u64], [1_u64]]
    xs = [[10.0_f64], [20.0_f64, 30.0_f64], [40.0_f64]]
    ys = [[-10.0_f64], [-20.0_f64, -30.0_f64], [-40.0_f64]]
    harness = CrystalClick::WidePart::W112MultiPointReaderHarness.new(
      sizes,
      xs,
      ys,
      {"shape%2E2", 2}
    )

    earlier = harness.reader.read(0, 1, CrystalClick::GeoArrayColumnType::MAX_MATERIALIZED_BYTES)
    earlier.point_count.should eq(1)
    prior_float_decodes = harness.float64_decode_calls
    harness.read_calls.clear
    harness.validate_calls.clear
    yielded = 0

    expect_raises(CrystalClick::CorruptPartError, "seeded selected MultiPoint boundary defect") do
      harness.reader.each(0, 3, CrystalClick::GeoArrayColumnType::MAX_MATERIALIZED_BYTES) do |_data, _mark|
        yielded += 1
        nil
      end
    end
    harness.read_calls.none? { |stream, _mark| stream == "shape%2E1" || stream == "shape%2E2" }.should be_true
    harness.float64_decode_calls.should eq(prior_float_decodes)
    yielded.should eq(0)
  end

  it "rejects budget-minus-one before coordinate validation, reads or Float64 decoding" do
    sizes = [[1_u64, 1_u64]]
    xs = [[10.0_f64, 20.0_f64]]
    ys = [[-10.0_f64, -20.0_f64]]
    charge_reader = CrystalClick::WidePart::W112MultiPointReaderHarness.new(sizes, xs, ys)
    exact_charge = charge_reader.reader.materialization_charge(
      0,
      1,
      CrystalClick::GeoArrayColumnType::MAX_MATERIALIZED_BYTES
    )
    charge_reader.validate_calls.any? { |stream, _mark| stream == "shape%2E1" || stream == "shape%2E2" }.should be_false

    exact_budget = CrystalClick::WidePart::W112MultiPointReaderHarness.new(sizes, xs, ys)
    exact_data = exact_budget.reader.read(0, 1, exact_charge)
    exact_data.point_count.should eq(2)

    limited = CrystalClick::WidePart::W112MultiPointReaderHarness.new(sizes, xs, ys)
    expect_raises(CrystalClick::CorruptPartError) do
      limited.reader.read(0, 1, exact_charge - 1_u64)
    end
    limited.validate_calls.any? { |stream, _mark| stream == "shape%2E1" || stream == "shape%2E2" }.should be_false
    limited.read_calls.any? { |stream, _mark| stream == "shape%2E1" || stream == "shape%2E2" }.should be_false
    limited.float64_decode_calls.should eq(0)
  end
end
