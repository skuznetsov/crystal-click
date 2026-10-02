module CrystalClick
  # Fixed global Geometry discriminator arms. NULL is tag 255 and is not an arm.
  enum WideGeometryArm : UInt8
    LineString      = 0
    MultiLineString = 1
    MultiPolygon    = 2
    Point           = 3
    Polygon         = 4
    Ring            = 5
    MultiPoint      = 6

    def self.for_tag(tag : UInt8) : WideGeometryArm?
      case tag
      when 0_u8 then LineString
      when 1_u8 then MultiLineString
      when 2_u8 then MultiPolygon
      when 3_u8 then Point
      when 4_u8 then Polygon
      when 5_u8 then Ring
      when 6_u8 then MultiPoint
      else
        nil
      end
    end

    def type_name : String
      case self.value
      when 0 then "LineString"
      when 1 then "MultiLineString"
      when 2 then "MultiPolygon"
      when 3 then "Point"
      when 4 then "Polygon"
      when 5 then "Ring"
      when 6 then "MultiPoint"
      else
        raise ArgumentError.new("invalid Geometry arm tag")
      end
    end

    def depth : Int32
      case self.value
      when 0, 5, 6 then 1
      when 1, 4    then 2
      when 2       then 3
      when 3       then 0
      else
        raise ArgumentError.new("invalid Geometry arm tag")
      end
    end
  end
end
