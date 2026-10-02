require "./spec_helper"

class CrystalClick::WidePart
  # Test-only bridges; the codec remains private in production.
  def self.lc_codec_test_mark(bytes : Bytes, first : UInt64, last : UInt64, rows : UInt64, index : Int, global : Bool, keys : Array(String)) : {Array(String), Int32}
    LowCardinalityBinaryCodec.parse_index_mark(bytes, first, last, Mark.new(0_u64, 0_u64, rows), index, global, keys)
  end

  def self.lc_codec_test_dictionary(bytes : Bytes, offset : Int, limit : Int?) : {Array(String), Int32}
    LowCardinalityBinaryCodec.read_dictionary(bytes, offset, limit)
  end

  def self.lc_codec_test_var_uint(bytes : Bytes, offset : Int) : {UInt64, Int32}
    LowCardinalityBinaryCodec.read_var_uint(bytes, offset)
  end

  def self.lc_codec_test_string(bytes : Bytes, offset : Int) : {String, Int32}
    LowCardinalityBinaryCodec.read_string(bytes, offset)
  end

  def self.lc_codec_test_u64(bytes : Bytes, offset : Int) : UInt64
    LowCardinalityBinaryCodec.read_u64(bytes, offset)
  end
end

private def lc_codec_words(*words : UInt64) : Bytes
  io = IO::Memory.new
  words.each { |word| io.write_bytes(word, IO::ByteFormat::LittleEndian) }
  io.to_slice.dup
end

private def lc_codec_concat(*segments : Bytes) : Bytes
  io = IO::Memory.new
  segments.each { |segment| io.write(segment) }
  io.to_slice.dup
end

describe "private LowCardinality binary grammar owner" do
  it "preserves global dictionary identity and absolute offsets for first and later marks" do
    keys = ["", "a"]
    [0, 1].each do |index|
      header = index == 0 ? 0x500_u64 : 0x100_u64
      bytes = lc_codec_concat(Bytes[0xee_u8], lc_codec_words(header, 2_u64), Bytes[0_u8, 1_u8], Bytes[0xaa_u8])
      actual, ids = CrystalClick::WidePart.lc_codec_test_mark(bytes, 1_u64, 19_u64, 2_u64, index, true, keys)
      actual.same?(keys).should be_true
      ids.should eq(17)
      bytes[ids, 2].should eq(Bytes[0_u8, 1_u8])
    end
  end

  it "decodes a local dictionary without borrowing the shared dictionary" do
    shared = ["unused"]
    bytes = lc_codec_concat(lc_codec_words(0x600_u64, 2_u64), Bytes[0_u8, 1_u8, 0x61_u8], lc_codec_words(3_u64), Bytes[0_u8, 1_u8, 1_u8])
    keys, ids = CrystalClick::WidePart.lc_codec_test_mark(bytes, 0_u64, bytes.size.to_u64, 3_u64, 0, false, shared)
    keys.should eq(["", "a"])
    keys.same?(shared).should be_false
    ids.should eq(27)
  end

  it "rejects unsupported or changing headers without weakening error classification" do
    [{0x100_u64, 0, true}, {0x500_u64, 1, true}, {0x500_u64, 0, false}, {0x700_u64, 0, true}].each do |header, index, global|
      bytes = lc_codec_words(header, 0_u64)
      error = expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.lc_codec_test_mark(bytes, 0_u64, bytes.size.to_u64, 0_u64, index, global, [""])
      end
      error.message.should eq("unsupported or changing LowCardinality dictionary state")
    end
  end

  it "rejects invalid selected byte boundaries and truncated headers" do
    bytes = lc_codec_words(0x500_u64, 0_u64)
    [{2_u64, 1_u64}, {0_u64, 17_u64}].each do |first, last|
      expect_raises(CrystalClick::CorruptPartError, "LowCardinality index mark boundaries are invalid") do
        CrystalClick::WidePart.lc_codec_test_mark(bytes, first, last, 0_u64, 0, true, [""])
      end
    end
    expect_raises(CrystalClick::CorruptPartError, "LowCardinality UInt64 field is truncated") do
      CrystalClick::WidePart.lc_codec_test_mark(bytes, 0_u64, 7_u64, 0_u64, 0, true, [""])
    end
  end

  it "preserves local dictionary count, uniqueness and reserved-default guards" do
    [0_u64, 257_u64].each do |count|
      bytes = lc_codec_words(0x600_u64, count)
      expect_raises(CrystalClick::CorruptPartError, "LowCardinality local dictionary is empty or exceeds key limit") do
        CrystalClick::WidePart.lc_codec_test_mark(bytes, 0_u64, bytes.size.to_u64, 0_u64, 0, false, [""])
      end
    end
    duplicate = lc_codec_concat(lc_codec_words(0x600_u64, 2_u64), Bytes[0_u8, 0_u8])
    expect_raises(CrystalClick::CorruptPartError, "LowCardinality local dictionary contains duplicate keys") do
      CrystalClick::WidePart.lc_codec_test_mark(duplicate, 0_u64, duplicate.size.to_u64, 0_u64, 0, false, [""])
    end
    missing_default = lc_codec_concat(lc_codec_words(0x600_u64, 1_u64), Bytes[1_u8, 0x61_u8])
    expect_raises(CrystalClick::CorruptPartError, "LowCardinality local dictionary must reserve the empty default at ID zero") do
      CrystalClick::WidePart.lc_codec_test_mark(missing_default, 0_u64, missing_default.size.to_u64, 0_u64, 0, false, [""])
    end
  end

  it "preserves row count, row limit and exact ID byte-count guards" do
    mismatch = lc_codec_words(0x500_u64, 1_u64)
    expect_raises(CrystalClick::CorruptPartError, "LowCardinality index row count differs from marks") do
      CrystalClick::WidePart.lc_codec_test_mark(mismatch, 0_u64, 16_u64, 0_u64, 0, true, [""])
    end
    excessive = lc_codec_words(0x500_u64, 65_537_u64)
    expect_raises(CrystalClick::CorruptPartError, "LowCardinality index row count exceeds limit") do
      CrystalClick::WidePart.lc_codec_test_mark(excessive, 0_u64, 16_u64, 65_537_u64, 0, true, [""])
    end
    [Bytes.empty, Bytes[0_u8, 0_u8]].each do |ids|
      bytes = lc_codec_concat(lc_codec_words(0x500_u64, 1_u64), ids)
      expect_raises(CrystalClick::CorruptPartError, "LowCardinality index IDs are truncated or have trailing bytes") do
        CrystalClick::WidePart.lc_codec_test_mark(bytes, 0_u64, bytes.size.to_u64, 1_u64, 0, true, [""])
      end
    end
  end

  it "reads bounded detached binary dictionary keys and an absolute cursor" do
    bytes = lc_codec_concat(Bytes[0xee_u8], lc_codec_words(2_u64), Bytes[0_u8, 3_u8, 0x61_u8, 0_u8, 0xff_u8], Bytes[0xaa_u8])
    keys, cursor = CrystalClick::WidePart.lc_codec_test_dictionary(bytes, 1, 14)
    keys.map(&.to_slice).should eq([Bytes.empty, Bytes[0x61_u8, 0_u8, 0xff_u8]])
    cursor.should eq(14)
    bytes[11] = 0x62_u8
    keys[1].to_slice.should eq(Bytes[0x61_u8, 0_u8, 0xff_u8])
    expect_raises(CrystalClick::CorruptPartError, "LowCardinality dictionary record exceeds mark boundary") do
      CrystalClick::WidePart.lc_codec_test_dictionary(bytes, 1, 13)
    end
  end

  it "rejects empty, excessive and duplicate shared dictionaries" do
    [0_u64, 257_u64].each do |count|
      expect_raises(CrystalClick::CorruptPartError, "LowCardinality dictionary is empty or exceeds key limit") do
        CrystalClick::WidePart.lc_codec_test_dictionary(lc_codec_words(count), 0, nil)
      end
    end
    expect_raises(CrystalClick::CorruptPartError, "LowCardinality dictionary contains duplicate keys") do
      CrystalClick::WidePart.lc_codec_test_dictionary(lc_codec_concat(lc_codec_words(2_u64), Bytes[0_u8, 0_u8]), 0, nil)
    end
  end

  it "preserves little-endian UInt64 and the LC-specific truncation label" do
    bytes = Bytes[0xaa_u8, 1_u8, 2_u8, 3_u8, 4_u8, 5_u8, 6_u8, 7_u8, 8_u8]
    CrystalClick::WidePart.lc_codec_test_u64(bytes, 1).should eq(0x0807060504030201_u64)
    [-1, 2].each do |offset|
      expect_raises(CrystalClick::CorruptPartError, "LowCardinality UInt64 field is truncated") do
        CrystalClick::WidePart.lc_codec_test_u64(bytes, offset)
      end
    end
  end

  it "decodes canonical VarUInt boundaries, maximum and nonzero origins" do
    [{Bytes[0_u8], 0_u64}, {Bytes[0x7f_u8], 127_u64}, {Bytes[0x80_u8, 1_u8], 128_u64}].each do |bytes, value|
      CrystalClick::WidePart.lc_codec_test_var_uint(bytes, 0).should eq({value, bytes.size.to_i32})
    end
    maximum = Bytes[0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 1_u8]
    CrystalClick::WidePart.lc_codec_test_var_uint(maximum, 0).should eq({UInt64::MAX, 10_i32})
    CrystalClick::WidePart.lc_codec_test_var_uint(Bytes[0xee_u8, 0x80_u8, 1_u8], 1).should eq({128_u64, 3_i32})
  end

  it "rejects truncated, noncanonical, overflowing and overlong VarUInt" do
    [{Bytes[0_u8], -1}, {Bytes[0x80_u8], 0}, {Bytes.empty, 0}].each do |bytes, offset|
      expect_raises(CrystalClick::CorruptPartError, "LowCardinality VarUInt is truncated") do
        CrystalClick::WidePart.lc_codec_test_var_uint(bytes, offset)
      end
    end
    expect_raises(CrystalClick::CorruptPartError, "LowCardinality VarUInt is noncanonical") do
      CrystalClick::WidePart.lc_codec_test_var_uint(Bytes[0x80_u8, 0_u8], 0)
    end
    overflow = Bytes.new(10, 0x80_u8)
    overflow[9] = 2_u8
    expect_raises(CrystalClick::CorruptPartError, "LowCardinality VarUInt overflows UInt64") do
      CrystalClick::WidePart.lc_codec_test_var_uint(overflow, 0)
    end
    expect_raises(CrystalClick::CorruptPartError, "LowCardinality VarUInt is too long") do
      CrystalClick::WidePart.lc_codec_test_var_uint(Bytes.new(11, 0x80_u8), 0)
    end
  end

  it "keeps binary String bytes and rejects lengths beyond the remaining payload" do
    value, cursor = CrystalClick::WidePart.lc_codec_test_string(Bytes[0xee_u8, 3_u8, 0x61_u8, 0_u8, 0xff_u8], 1)
    value.to_slice.should eq(Bytes[0x61_u8, 0_u8, 0xff_u8])
    cursor.should eq(5)
    expect_raises(CrystalClick::CorruptPartError, "LowCardinality String length exceeds remaining bytes") do
      CrystalClick::WidePart.lc_codec_test_string(Bytes[2_u8, 0x61_u8], 0)
    end
  end
end
