require "./spec_helper"

W91_READER_TUPLE_FIXTURE = File.expand_path("../test/fixtures/public/wide_tuple_uint64_string/part", __DIR__)

def w91_copy_reader_tuple_fixture : String
  path = File.tempname("crystal-click-w91-reader-tuple")
  FileUtils.cp_r(W91_READER_TUPLE_FIXTURE, path)
  path
end

def w91_string_payload_values(
  sizes : Array(UInt64),
  raw_bytes : Bytes,
  label : String,
) : Array({String, Int32})
  values = [] of {String, Int32}
  CrystalClick::WidePart.w91_spec_each_string_payload(sizes, raw_bytes, label) do |value, index|
    values << {value, index}
    nil
  end
  values
end

class CrystalClick::WidePart
  def self.w91_spec_each_string_payload(
    sizes : Array(UInt64),
    raw_bytes : Bytes,
    label : String,
    &block : String, Int32 -> Nil
  ) : Nil
    StringPayloadDecoder.each(sizes, raw_bytes, label) do |value, index|
      yield value, index
    end
    nil
  end
end

class W91PayloadCallbackStop < Exception
end

describe "W91 WidePart reader String payload seam" do
  it "accepts empty sizes with an empty raw payload" do
    w91_string_payload_values([] of UInt64, Bytes.new(0), "String").should eq([] of {String, Int32})
  end

  it "yields each zero-length String from an empty raw payload" do
    w91_string_payload_values([0_u64, 0_u64], Bytes.new(0), "Tuple(String)").should eq([
      {"", 0},
      {"", 1},
    ])
  end

  it "yields owned empty, binary, and multibyte Strings with their positions" do
    expected = ["", String.new(Bytes[0x41_u8, 0x00_u8, 0xff_u8]), "é猫"]
    encoded = expected.join.to_slice
    raw = Bytes.new(encoded.size)
    encoded.size.times { |index| raw[index] = encoded[index] }
    sizes = expected.map { |value| value.bytesize.to_u64 }

    observed = w91_string_payload_values(sizes, raw, "Tuple(String)")
    raw.size.times { |index| raw[index] = 0_u8 }

    observed.map { |entry| entry[0] }.should eq(expected)
    observed.map { |entry| entry[1] }.should eq([0, 1, 2])
  end

  it "rejects an element extending beyond the selected raw bytes with the Tuple label" do
    error = expect_raises(CrystalClick::CorruptPartError) do
      w91_string_payload_values([4_u64], Bytes[0x41_u8, 0x42_u8, 0x43_u8], "Tuple(String)")
    end

    error.message.to_s.should eq("Tuple(String) sizes exceed selected raw bytes")
  end

  it "rejects UInt64::MAX before converting it to an Int length" do
    error = expect_raises(CrystalClick::CorruptPartError) do
      w91_string_payload_values([UInt64::MAX], Bytes.new(0), "Tuple(String)")
    end

    error.message.to_s.should eq("Tuple(String) sizes exceed selected raw bytes")
  end

  it "rejects trailing raw bytes with the Tuple label" do
    error = expect_raises(CrystalClick::CorruptPartError) do
      w91_string_payload_values([1_u64], Bytes[0x41_u8, 0x42_u8], "Tuple(String)")
    end

    error.message.to_s.should eq("Tuple(String) sizes do not consume selected raw bytes")
  end

  it "retains the scalar String trailing-byte error label" do
    error = expect_raises(CrystalClick::CorruptPartError) do
      w91_string_payload_values([1_u64], Bytes[0x41_u8, 0x42_u8], "String")
    end

    error.message.to_s.should eq("String sizes do not consume selected raw bytes")
  end

  it "propagates a callback exception without visiting later values" do
    visited = [] of Int32

    error = expect_raises(W91PayloadCallbackStop) do
      CrystalClick::WidePart.w91_spec_each_string_payload(
        [1_u64, 1_u64], Bytes[0x41_u8, 0x42_u8], "String"
      ) do |_value, index|
        visited << index
        raise W91PayloadCallbackStop.new("stop at first value")
      end
    end

    error.message.to_s.should eq("stop at first value")
    visited.should eq([0])
  end

  it "retains scalar-root rejection for an exact Tuple and rejects a near-prefix type" do
    reader = CrystalClick::WidePart.open_typed(W91_READER_TUPLE_FIXTURE, "payload")

    expect_raises(CrystalClick::UnsupportedFormatError) do
      reader.read_string_mark_range("payload", 0, 1)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      reader.read_numeric_mark_range("payload", 0, 1, UInt64)
    end

    part_path = w91_copy_reader_tuple_fixture
    begin
      columns_path = File.join(part_path, "columns.txt")
      columns = File.read(columns_path)
      columns.should contain("Tuple(a UInt64, b String)")
      File.write(columns_path, columns.sub("Tuple(a UInt64, b String)", "Tuple(a UInt64, b StringExtra)"))

      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(part_path, "payload")
      end
    ensure
      FileUtils.rm_rf(part_path)
    end
  end
end
