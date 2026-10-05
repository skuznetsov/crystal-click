require "./spec_helper"

describe "W160 Interval descriptor admission RED" do
  it "admits the exact Interval(Nanosecond) wire descriptor" do
    decoded = CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x22_u8, 0x00_u8])
    decoded.name.should eq("IntervalNanosecond")
  end

  it "admits the exact Interval(Microsecond) wire descriptor" do
    decoded = CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x22_u8, 0x01_u8])
    decoded.name.should eq("IntervalMicrosecond")
  end

  it "admits the exact Interval(Millisecond) wire descriptor" do
    decoded = CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x22_u8, 0x02_u8])
    decoded.name.should eq("IntervalMillisecond")
  end

  it "admits the exact Interval(Second) wire descriptor" do
    decoded = CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x22_u8, 0x03_u8])
    decoded.name.should eq("IntervalSecond")
  end

  it "admits the exact Interval(Minute) wire descriptor" do
    decoded = CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x22_u8, 0x04_u8])
    decoded.name.should eq("IntervalMinute")
  end

  it "admits the exact Interval(Hour) wire descriptor" do
    decoded = CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x22_u8, 0x05_u8])
    decoded.name.should eq("IntervalHour")
  end

  it "admits the exact Interval(Day) wire descriptor" do
    decoded = CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x22_u8, 0x06_u8])
    decoded.name.should eq("IntervalDay")
  end

  it "admits the exact Interval(Week) wire descriptor" do
    decoded = CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x22_u8, 0x07_u8])
    decoded.name.should eq("IntervalWeek")
  end

  it "admits the exact Interval(Month) wire descriptor" do
    decoded = CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x22_u8, 0x08_u8])
    decoded.name.should eq("IntervalMonth")
  end

  it "admits the exact Interval(Quarter) wire descriptor" do
    decoded = CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x22_u8, 0x09_u8])
    decoded.name.should eq("IntervalQuarter")
  end

  it "admits the exact Interval(Year) wire descriptor" do
    decoded = CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x22_u8, 0x0a_u8])
    decoded.name.should eq("IntervalYear")
  end

  it "keeps primitive Int64 descriptor admission intact" do
    decoded = CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x0a_u8])
    decoded.should eq(CrystalClick::BinaryDataType.primitive("Int64"))
  end
end
