require "./spec_helper"

# Test-only seam: inject observable callbacks without changing production
# visibility or letting a self-produced part establish budget ordering.
class CrystalClick::WidePart
  def self.w109_hostile_point_probe(
    operation : Symbol,
    budget : UInt64,
    calls : Array(Int32),
    corrupt_later_boundary : Bool = false,
  ) : UInt64
    reader = PointReader.new(
      PointColumnType.for_type("Point").not_nil!,
      "payload",
      ->(_stream : String, _first : Int32, count : Int32) { count.to_u64 * 2_u64 },
      ->(_stream : String, _mark : Int32) { 2_u64 },
      ->(_stream : String, _first : Int32, _count : Int32, bytes : Int32, _width : Int32, _rows : UInt64) {
        calls[1] += 1
        Bytes.new(bytes, 0_u8)
      },
      ->(stream : String, first : Int32, _count : Int32, _bytes : Int32, _width : Int32, _rows : UInt64) {
        calls[0] += 1
        if corrupt_later_boundary && stream == "payload%2E2" && first == 1
          raise CorruptPartError.new("seeded later Point boundary defect")
        end
        nil
      },
      ->(_bytes : Bytes, _offset : Int32) {
        calls[2] += 1
        0.0_f64
      }
    )
    case operation
    when :charge
      reader.materialization_charge(0, 2, budget)
    when :read
      reader.read(0, 2, budget)
      0_u64
    when :each
      reader.each(0, 2, budget) do |_values, _mark|
        calls[3] += 1
        nil
      end
      0_u64
    else
      raise ArgumentError.new("invalid test operation")
    end
  end
end

describe "W109 independent Point boundary controls" do
  it "estimates selected materialization from metadata without touching payload" do
    calls = [0, 0, 0, 0]
    schedule = instance_sizeof(Array(UInt64)).to_u64 + 2_u64 * sizeof(UInt64).to_u64
    expected = CrystalClick::PointColumnType.for_type("Point").not_nil!
      .materialization_charge(4_u64, schedule)
    actual = CrystalClick::WidePart.w109_hostile_point_probe(:charge, expected, calls, true)
    actual.should eq(expected)
    calls.should eq([0, 0, 0, 0])
  end

  it "rejects full and lazy cap-minus-one before validation, read, decode or callback" do
    plan = CrystalClick::PointColumnType.for_type("Point").not_nil!
    schedule = instance_sizeof(Array(UInt64)).to_u64 + 2_u64 * sizeof(UInt64).to_u64
    {:charge, :read, :each}.each do |operation|
      calls = [0, 0, 0, 0]
      rows = operation == :each ? 2_u64 : 4_u64
      cap = plan.materialization_charge(rows, schedule) - 1_u64
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.w109_hostile_point_probe(operation, cap, calls)
      end
      calls.should eq([0, 0, 0, 0])
    end
  end

  it "rejects a later selected coordinate boundary before even the first value read" do
    calls = [0, 0, 0, 0]
    expect_raises(CrystalClick::CorruptPartError, "seeded later Point boundary defect") do
      CrystalClick::WidePart.w109_hostile_point_probe(
        :each, CrystalClick::PointColumnType::MAX_MATERIALIZED_BYTES, calls, true
      )
    end
    calls.should eq([4, 0, 0, 0])
  end

  it "keeps both coordinates' NaN payloads and signed zeros in equality and hashing" do
    a = CrystalClick::WidePointValue.from_bits(0x7ff8_0000_0000_002a_u64, 0x8000_0000_0000_0000_u64)
    same = CrystalClick::WidePointValue.from_bits(0x7ff8_0000_0000_002a_u64, 0x8000_0000_0000_0000_u64)
    different_x = CrystalClick::WidePointValue.from_bits(0x7ff8_0000_0000_002b_u64, 0x8000_0000_0000_0000_u64)
    different_y = CrystalClick::WidePointValue.from_bits(0x7ff8_0000_0000_002a_u64, 0_u64)
    swapped = CrystalClick::WidePointValue.from_bits(0x8000_0000_0000_0000_u64, 0x7ff8_0000_0000_002a_u64)
    a.should eq(same)
    a.hash.should eq(same.hash)
    Set{a, same, different_x, different_y, swapped}.size.should eq(4)
    a.x_bits.should eq(0x7ff8_0000_0000_002a_u64)
    a.y_bits.should eq(0x8000_0000_0000_0000_u64)
  end
end
