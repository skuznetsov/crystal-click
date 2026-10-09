module CrystalClick
  # Closed nominal owner for ClickHouse's seven static Custom Geo aliases.
  # The binary descriptor carries only the alias name; its storage_type is an
  # implicit recursive child used by the ordinary descriptor/value visitors.
  class BinaryCustomGeoType
    enum Profile
      Point
      MultiPoint
      LineString
      Ring
      MultiLineString
      Polygon
      MultiPolygon
    end

    MAX_NAME_BYTES = 15

    @profile : Profile
    @name : String

    def initialize(name : String)
      @profile = self.class.profile_for(name) ||
                 raise ArgumentError.new("Custom Geo name is outside the admitted alias profile")
      @name = String.new(name.to_slice)
    end

    def name : String
      String.new(@name.to_slice)
    end

    def profile : Profile
      @profile
    end

    def self.profile_for(name : String) : Profile?
      case name
      when "Point"           then Profile::Point
      when "MultiPoint"      then Profile::MultiPoint
      when "LineString"      then Profile::LineString
      when "Ring"            then Profile::Ring
      when "MultiLineString" then Profile::MultiLineString
      when "Polygon"         then Profile::Polygon
      when "MultiPolygon"    then Profile::MultiPolygon
      else
        nil
      end
    end

    def self.admitted_name?(name : String) : Bool
      !profile_for(name).nil?
    end

    # Point is Tuple-backed and is the only alias admitted directly beneath
    # Nullable by ClickHouse's DataTypeNullable construction rules.
    def nullable_eligible? : Bool
      @profile == Profile::Point
    end

    # Return the one exact implicit storage descriptor. Nested aliases remain
    # nominal Custom nodes; their own name-only wire representation is not
    # replaced by a flattened Array/Tuple spelling.
    def storage_type : BinaryDataType
      case @profile
      when Profile::Point
        coordinates = [
          BinaryDataType.primitive("Float64"),
          BinaryDataType.primitive("Float64"),
        ] of BinaryDataType
        BinaryDataType.tuple(coordinates)
      when Profile::MultiPoint, Profile::LineString, Profile::Ring
        BinaryDataType.array(BinaryDataType.custom("Point"))
      when Profile::MultiLineString
        BinaryDataType.array(BinaryDataType.custom("LineString"))
      when Profile::Polygon
        BinaryDataType.array(BinaryDataType.custom("Ring"))
      when Profile::MultiPolygon
        BinaryDataType.array(BinaryDataType.custom("Polygon"))
      else
        raise UnsupportedFormatError.new("Custom Geo storage profile is not admitted")
      end
    end

    # Preflight the complete hidden descriptor expansion without constructing
    # its implicit child graph. The caller has already visited the Custom
    # root. Hidden edges equal hidden nodes because every admitted profile is
    # a tree with exactly one immediate storage root and no shared subgraphs.
    def preflight_expansion(budget : BinaryCodecBudget, root_depth : Int) : Nil
      maximum = max_hidden_depth
      budget.ensure_depth(root_depth + maximum)
      budget.preflight_children(hidden_node_count)

      offset = 1
      while offset <= maximum
        count = nodes_at_hidden_depth(offset)
        count.times { budget.visit_node(root_depth + offset) }
        offset += 1
      end
      nil
    end

    def ==(other : BinaryCustomGeoType) : Bool
      @profile == other.@profile
    end

    def hash(hasher)
      @profile.hash(hasher)
    end

    private def hidden_node_count : UInt64
      case @profile
      when Profile::Point
        3_u64
      when Profile::MultiPoint, Profile::LineString, Profile::Ring
        5_u64
      when Profile::MultiLineString, Profile::Polygon
        7_u64
      when Profile::MultiPolygon
        9_u64
      else
        raise UnsupportedFormatError.new("Custom Geo expansion profile is not admitted")
      end
    end

    # Number of hidden descriptor levels below the nominal Custom root.
    private def max_hidden_depth : Int32
      case @profile
      when Profile::Point
        2
      when Profile::MultiPoint, Profile::LineString, Profile::Ring
        4
      when Profile::MultiLineString, Profile::Polygon
        6
      when Profile::MultiPolygon
        8
      else
        raise UnsupportedFormatError.new("Custom Geo expansion profile is not admitted")
      end
    end

    private def nodes_at_hidden_depth(offset : Int32) : Int32
      case @profile
      when Profile::Point
        offset == 1 ? 1 : offset == 2 ? 2 : 0
      when Profile::MultiPoint, Profile::LineString, Profile::Ring
        offset == 1 || offset == 2 || offset == 3 ? 1 : offset == 4 ? 2 : 0
      when Profile::MultiLineString, Profile::Polygon
        offset >= 1 && offset <= 5 ? 1 : offset == 6 ? 2 : 0
      when Profile::MultiPolygon
        offset >= 1 && offset <= 7 ? 1 : offset == 8 ? 2 : 0
      else
        raise UnsupportedFormatError.new("Custom Geo expansion profile is not admitted")
      end
    end
  end
end
