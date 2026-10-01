module CrystalClick
  class WideTypePlan
    struct PhysicalSubstream
      getter name : String
      getter kind : PhysicalSubstreamKind
      @field_path : Array(String)

      def initialize(@name : String, @kind : PhysicalSubstreamKind, field_path : Array(String))
        @field_path = field_path.dup
      end

      def field_path : Array(String)
        @field_path.dup
      end

      def element_width : Int32
        case @kind
        when .array_size0?, .array_size1?, .u_int64?, .string_size?
          8
        when .null_map?, .string_data?
          1
        else
          raise UnsupportedFormatError.new("unsupported planned Array(Tuple) stream kind")
        end
      end
    end
  end
end
