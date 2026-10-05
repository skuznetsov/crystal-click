module CrystalClick
  # Exact ClickHouse Interval kind metadata for the BinaryType descriptor.
  # Its Int64 payload width is fixed, but the interval kind remains part of
  # nominal identity and is never interchangeable with a primitive Int64.
  class BinaryIntervalType
    enum Kind : UInt8
      Nanosecond  = 0x00
      Microsecond = 0x01
      Millisecond = 0x02
      Second      = 0x03
      Minute      = 0x04
      Hour        = 0x05
      Day         = 0x06
      Week        = 0x07
      Month       = 0x08
      Quarter     = 0x09
      Year        = 0x0a
    end

    getter kind : Kind

    def initialize(@kind : Kind)
      unless valid_kind?(@kind)
        raise ArgumentError.new("invalid Interval kind")
      end
    end

    def kind_code : UInt8
      @kind.value.to_u8
    end

    def fixed_width : Int32
      8
    end

    def type_name : String
      case @kind
      when Kind::Nanosecond  then "IntervalNanosecond"
      when Kind::Microsecond then "IntervalMicrosecond"
      when Kind::Millisecond then "IntervalMillisecond"
      when Kind::Second      then "IntervalSecond"
      when Kind::Minute      then "IntervalMinute"
      when Kind::Hour        then "IntervalHour"
      when Kind::Day         then "IntervalDay"
      when Kind::Week        then "IntervalWeek"
      when Kind::Month       then "IntervalMonth"
      when Kind::Quarter     then "IntervalQuarter"
      when Kind::Year        then "IntervalYear"
      else
        raise ArgumentError.new("invalid Interval kind")
      end
    end

    def name : String
      type_name
    end

    # Bound canonical name construction without first materializing it.
    def name_byte_size : UInt64
      case @kind
      when Kind::Nanosecond  then 18_u64
      when Kind::Microsecond then 19_u64
      when Kind::Millisecond then 19_u64
      when Kind::Second      then 14_u64
      when Kind::Minute      then 14_u64
      when Kind::Hour        then 12_u64
      when Kind::Day         then 11_u64
      when Kind::Week        then 12_u64
      when Kind::Month       then 13_u64
      when Kind::Quarter     then 15_u64
      when Kind::Year        then 12_u64
      else
        raise ArgumentError.new("invalid Interval kind")
      end
    end

    def self.parse(type_name : String) : BinaryIntervalType?
      case type_name
      when "IntervalNanosecond"  then new(Kind::Nanosecond)
      when "IntervalMicrosecond" then new(Kind::Microsecond)
      when "IntervalMillisecond" then new(Kind::Millisecond)
      when "IntervalSecond"      then new(Kind::Second)
      when "IntervalMinute"      then new(Kind::Minute)
      when "IntervalHour"        then new(Kind::Hour)
      when "IntervalDay"         then new(Kind::Day)
      when "IntervalWeek"        then new(Kind::Week)
      when "IntervalMonth"       then new(Kind::Month)
      when "IntervalQuarter"     then new(Kind::Quarter)
      when "IntervalYear"        then new(Kind::Year)
      else
        nil
      end
    end

    def self.kind_for_code(code : UInt8) : Kind?
      case code
      when 0x00_u8 then Kind::Nanosecond
      when 0x01_u8 then Kind::Microsecond
      when 0x02_u8 then Kind::Millisecond
      when 0x03_u8 then Kind::Second
      when 0x04_u8 then Kind::Minute
      when 0x05_u8 then Kind::Hour
      when 0x06_u8 then Kind::Day
      when 0x07_u8 then Kind::Week
      when 0x08_u8 then Kind::Month
      when 0x09_u8 then Kind::Quarter
      when 0x0a_u8 then Kind::Year
      else
        nil
      end
    end

    def ==(other : self) : Bool
      @kind == other.kind
    end

    def hash(hasher)
      hasher = @kind.hash(hasher)
      hasher
    end

    private def valid_kind?(kind : Kind) : Bool
      case kind
      when Kind::Nanosecond, Kind::Microsecond, Kind::Millisecond, Kind::Second,
           Kind::Minute, Kind::Hour, Kind::Day, Kind::Week, Kind::Month,
           Kind::Quarter, Kind::Year
        true
      else
        false
      end
    end
  end
end
