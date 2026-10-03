module CrystalClick
  # Canonical, borrowed-slice parser and renderer for the admitted scalar
  # temporal declarations used by Object typed fields. It shares the existing
  # BinaryTemporalType and TimezoneName identity owners; this is not a codec.
  module ObjectTemporalDeclaration
    DATETIME_PREFIX     = "DateTime('"
    DATETIME64_PREFIX   = "DateTime64("
    DATETIME64_ZONE_SEP = ", '"
    TIME64_PREFIX       = "Time64("

    struct Preflight
      getter byte_size : Int32
      getter zone_byte_size : UInt64
      getter tag : UInt8
      getter scale : Int32

      @bytes : Bytes
      @first : Int32
      @after : Int32
      @zone_first : Int32
      @zone_after : Int32

      def initialize(
        @bytes : Bytes,
        @first : Int32,
        @after : Int32,
        @tag : UInt8,
        @scale : Int32,
        @zone_first : Int32 = -1,
        @zone_after : Int32 = -1,
      )
        unless @first >= 0 && @after >= @first && @after <= @bytes.size
          raise ArgumentError.new("temporal declaration preflight has invalid source bounds")
        end
        if @zone_first < 0
          unless @zone_first == -1 && @zone_after == -1
            raise ArgumentError.new("temporal declaration preflight has invalid timezone bounds")
          end
        elsif @zone_first < @first || @zone_after < @zone_first || @zone_after > @after
          raise ArgumentError.new("temporal declaration preflight has invalid timezone bounds")
        end
        @byte_size = @after - @first
        @zone_byte_size = @zone_first >= 0 ? (@zone_after - @zone_first).to_u64 : 0_u64
      end

      def explicit_zone? : Bool
        @zone_first >= 0
      end

      # Re-scan the borrowed token before allocating its timezone String or
      # descriptor. This keeps forged/stale preflight metadata from bypassing
      # scale, identity, admission, or byte-budget checks.
      def materialize : BinaryDataType
        current = ObjectTemporalDeclaration.resolve_slice(@bytes, @first, @after)
        unless current && same_metadata?(current)
          raise ArgumentError.new("temporal declaration changed after preflight")
        end
        build_type
      end

      private def build_type : BinaryDataType
        zone = if @zone_first >= 0
                 String.new(@bytes[@zone_first, @zone_after - @zone_first])
               end

        case @tag
        when BinaryDataType::TAG_DATETIME
          BinaryDataType.datetime
        when BinaryDataType::TAG_DATETIME_ZONE
          BinaryDataType.datetime(zone || raise ArgumentError.new("zoned DateTime lost its timezone"))
        when BinaryDataType::TAG_DATETIME64
          BinaryDataType.datetime64(@scale)
        when BinaryDataType::TAG_DATETIME64_ZONE
          BinaryDataType.datetime64(@scale, zone || raise ArgumentError.new("zoned DateTime64 lost its timezone"))
        when BinaryDataType::TAG_TIME
          BinaryDataType.primitive("Time")
        when BinaryDataType::TAG_TIME64
          BinaryDataType.time64(@scale)
        else
          raise ArgumentError.new("temporal declaration preflight has an unknown type tag")
        end
      end

      private def same_metadata?(other : Preflight) : Bool
        @first == other.@first && @after == other.@after &&
          @tag == other.@tag && @scale == other.@scale &&
          @byte_size == other.@byte_size && @zone_byte_size == other.@zone_byte_size &&
          @zone_first == other.@zone_first && @zone_after == other.@zone_after
      end
    end

    def self.handles_type?(type : BinaryDataType) : Bool
      case type.tag
      when BinaryDataType::TAG_TIME, BinaryDataType::TAG_DATETIME,
           BinaryDataType::TAG_DATETIME_ZONE, BinaryDataType::TAG_DATETIME64,
           BinaryDataType::TAG_DATETIME64_ZONE, BinaryDataType::TAG_TIME64
        true
      else
        false
      end
    end

    # Time is the sole temporal declaration whose canonical spelling is a
    # static primitive name. Parameterized families are rendered directly.
    def self.name_for(type : BinaryDataType) : String?
      type.tag == BinaryDataType::TAG_TIME ? "Time" : nil
    end

    def self.byte_size_for(type : BinaryDataType) : UInt64?
      case type.tag
      when BinaryDataType::TAG_TIME
        return "Time".bytesize.to_u64
      when BinaryDataType::TAG_DATETIME, BinaryDataType::TAG_DATETIME_ZONE,
           BinaryDataType::TAG_DATETIME64, BinaryDataType::TAG_DATETIME64_ZONE,
           BinaryDataType::TAG_TIME64
        temporal = type.temporal_type || return nil
        zone = temporal.time_zone?
        case type.tag
        when BinaryDataType::TAG_DATETIME
          return nil unless temporal.family == BinaryTemporalType::Family::DateTime && zone.nil?
          "DateTime".bytesize.to_u64
        when BinaryDataType::TAG_DATETIME_ZONE
          return nil unless temporal.family == BinaryTemporalType::Family::DateTime && zone
          (DATETIME_PREFIX.bytesize.to_u64 + zone.not_nil!.name_byte_size.to_u64 + "')".bytesize.to_u64)
        when BinaryDataType::TAG_DATETIME64
          return nil unless temporal.family == BinaryTemporalType::Family::DateTime64 && zone.nil?
          scale = temporal.scale || return nil
          return nil unless scale >= 0 && scale <= 9
          (DATETIME64_PREFIX.bytesize + 2).to_u64
        when BinaryDataType::TAG_DATETIME64_ZONE
          return nil unless temporal.family == BinaryTemporalType::Family::DateTime64 && zone
          scale = temporal.scale || return nil
          return nil unless scale >= 0 && scale <= 9
          (DATETIME64_PREFIX.bytesize + 1 + DATETIME64_ZONE_SEP.bytesize +
            zone.not_nil!.name_byte_size + "')".bytesize).to_u64
        when BinaryDataType::TAG_TIME64
          return nil unless temporal.family == BinaryTemporalType::Family::Time64 && zone.nil?
          scale = temporal.scale || return nil
          return nil unless scale >= 0 && scale <= 9
          (TIME64_PREFIX.bytesize + 2).to_u64
        else
          nil
        end
      else
        nil
      end
    end

    def self.append_name(io : IO, type : BinaryDataType) : Nil
      case type.tag
      when BinaryDataType::TAG_TIME
        io << "Time"
      when BinaryDataType::TAG_DATETIME, BinaryDataType::TAG_DATETIME_ZONE
        temporal = type.temporal_type || raise ArgumentError.new("DateTime descriptor is missing temporal metadata")
        raise ArgumentError.new("DateTime descriptor has the wrong temporal family") unless temporal.family == BinaryTemporalType::Family::DateTime
        zone = temporal.time_zone?
        if type.tag == BinaryDataType::TAG_DATETIME
          raise ArgumentError.new("bare DateTime descriptor has a timezone") if zone
          io << "DateTime"
        else
          zone = zone || raise ArgumentError.new("zoned DateTime descriptor is missing a timezone")
          io << DATETIME_PREFIX
          zone.append_name(io)
          io << "')"
        end
      when BinaryDataType::TAG_DATETIME64, BinaryDataType::TAG_DATETIME64_ZONE
        temporal = type.temporal_type || raise ArgumentError.new("DateTime64 descriptor is missing temporal metadata")
        raise ArgumentError.new("DateTime64 descriptor has the wrong temporal family") unless temporal.family == BinaryTemporalType::Family::DateTime64
        zone = temporal.time_zone?
        scale = temporal.scale || raise ArgumentError.new("DateTime64 descriptor is missing a scale")
        raise ArgumentError.new("DateTime64 scale is outside the canonical range") unless scale >= 0 && scale <= 9
        io << DATETIME64_PREFIX << scale
        if type.tag == BinaryDataType::TAG_DATETIME64
          raise ArgumentError.new("bare DateTime64 descriptor has a timezone") if zone
          io << ')'
        else
          zone = zone || raise ArgumentError.new("zoned DateTime64 descriptor is missing a timezone")
          io << DATETIME64_ZONE_SEP
          zone.append_name(io)
          io << "')"
        end
      when BinaryDataType::TAG_TIME64
        temporal = type.temporal_type || raise ArgumentError.new("Time64 descriptor is missing temporal metadata")
        raise ArgumentError.new("Time64 descriptor has the wrong temporal family") unless temporal.family == BinaryTemporalType::Family::Time64
        raise ArgumentError.new("Time64 descriptor cannot have a timezone") if temporal.time_zone?
        scale = temporal.scale || raise ArgumentError.new("Time64 descriptor is missing a scale")
        raise ArgumentError.new("Time64 scale is outside the canonical range") unless scale >= 0 && scale <= 9
        io << TIME64_PREFIX << scale << ')'
      else
        raise ArgumentError.new("typed JSON schema has a non-temporal descriptor")
      end
      nil
    end

    def self.resolve_slice(bytes : Bytes, first : Int32, after : Int32) : Preflight?
      return nil if first < 0 || after < first || after > bytes.size
      return Preflight.new(bytes, first, after, BinaryDataType::TAG_DATETIME, 0) if slice_equals?(bytes, first, after, "DateTime")
      return Preflight.new(bytes, first, after, BinaryDataType::TAG_TIME, 0) if slice_equals?(bytes, first, after, "Time")

      if after - first >= DATETIME_PREFIX.bytesize &&
         slice_equals?(bytes, first, first + DATETIME_PREFIX.bytesize, DATETIME_PREFIX)
        return nil if after - first < DATETIME_PREFIX.bytesize + 3
        return nil unless bytes[after - 2] == '\''.ord.to_u8 && bytes[after - 1] == ')'.ord.to_u8
        zone_first = first + DATETIME_PREFIX.bytesize
        zone_after = after - 2
        return nil unless TimezoneName.admitted_slice?(bytes, zone_first, zone_after)
        return Preflight.new(bytes, first, after, BinaryDataType::TAG_DATETIME_ZONE, 0, zone_first, zone_after)
      end

      if after - first >= DATETIME64_PREFIX.bytesize &&
         slice_equals?(bytes, first, first + DATETIME64_PREFIX.bytesize, DATETIME64_PREFIX)
        return nil if after - first < DATETIME64_PREFIX.bytesize + 2
        scale_index = first + DATETIME64_PREFIX.bytesize
        scale = scale_at(bytes, scale_index)
        return nil unless scale
        next_index = scale_index + 1
        if next_index < after && bytes[next_index] == ')'.ord.to_u8 && next_index + 1 == after
          return Preflight.new(bytes, first, after, BinaryDataType::TAG_DATETIME64, scale)
        end
        return nil unless next_index + DATETIME64_ZONE_SEP.bytesize <= after &&
                          slice_equals?(bytes, next_index, next_index + DATETIME64_ZONE_SEP.bytesize, DATETIME64_ZONE_SEP)
        zone_first = next_index + DATETIME64_ZONE_SEP.bytesize
        return nil if after - zone_first < 3
        return nil unless bytes[after - 2] == '\''.ord.to_u8 && bytes[after - 1] == ')'.ord.to_u8
        zone_after = after - 2
        return nil unless TimezoneName.admitted_slice?(bytes, zone_first, zone_after)
        return Preflight.new(bytes, first, after, BinaryDataType::TAG_DATETIME64_ZONE, scale, zone_first, zone_after)
      end

      if after - first >= TIME64_PREFIX.bytesize &&
         slice_equals?(bytes, first, first + TIME64_PREFIX.bytesize, TIME64_PREFIX)
        return nil if after - first != TIME64_PREFIX.bytesize + 2
        scale_index = first + TIME64_PREFIX.bytesize
        scale = scale_at(bytes, scale_index)
        return nil unless scale && bytes[after - 1] == ')'.ord.to_u8
        return Preflight.new(bytes, first, after, BinaryDataType::TAG_TIME64, scale)
      end

      nil
    end

    private def self.scale_at(bytes : Bytes, index : Int32) : Int32?
      return nil if index < 0 || index >= bytes.size
      byte = bytes[index]
      return nil if byte < '0'.ord.to_u8 || byte > '9'.ord.to_u8
      (byte - '0'.ord.to_u8).to_i32
    end

    private def self.slice_equals?(bytes : Bytes, first : Int32, after : Int32, expected : String) : Bool
      return false if first < 0 || after < first || after > bytes.size
      return false unless after - first == expected.bytesize
      expected_bytes = expected.to_slice
      expected_bytes.size.times do |index|
        return false unless bytes[first + index] == expected_bytes[index]
      end
      true
    end
  end
end
