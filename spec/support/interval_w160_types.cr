W160_INTERVAL_TYPES = [
  {"IntervalNanosecond", CrystalClick::BinaryIntervalType::Kind::Nanosecond, 0x00_u8},
  {"IntervalMicrosecond", CrystalClick::BinaryIntervalType::Kind::Microsecond, 0x01_u8},
  {"IntervalMillisecond", CrystalClick::BinaryIntervalType::Kind::Millisecond, 0x02_u8},
  {"IntervalSecond", CrystalClick::BinaryIntervalType::Kind::Second, 0x03_u8},
  {"IntervalMinute", CrystalClick::BinaryIntervalType::Kind::Minute, 0x04_u8},
  {"IntervalHour", CrystalClick::BinaryIntervalType::Kind::Hour, 0x05_u8},
  {"IntervalDay", CrystalClick::BinaryIntervalType::Kind::Day, 0x06_u8},
  {"IntervalWeek", CrystalClick::BinaryIntervalType::Kind::Week, 0x07_u8},
  {"IntervalMonth", CrystalClick::BinaryIntervalType::Kind::Month, 0x08_u8},
  {"IntervalQuarter", CrystalClick::BinaryIntervalType::Kind::Quarter, 0x09_u8},
  {"IntervalYear", CrystalClick::BinaryIntervalType::Kind::Year, 0x0a_u8},
] of Tuple(String, CrystalClick::BinaryIntervalType::Kind, UInt8)

module W160IntervalTestSupport
  def self.i64_le(value : Int64) : Array(UInt8)
    bits = value.unsafe_as(UInt64)
    Array(UInt8).new(8) { |index| ((bits >> (index * 8)) & 0xff_u64).to_u8 }
  end

  def self.u64_le(value : UInt64) : Array(UInt8)
    Array(UInt8).new(8) { |index| ((value >> (index * 8)) & 0xff_u64).to_u8 }
  end
end
