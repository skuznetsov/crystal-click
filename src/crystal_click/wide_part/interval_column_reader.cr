module CrystalClick
  class WidePart
    # Keeps Interval's nominal kind check at the semantic reader boundary,
    # then delegates raw fixed-width decoding to WidePart's checked mark path.
    private class IntervalColumnReader
      def self.read_counts(type_name : String, &read : -> Array(Int64)) : Array(Int64)
        plan = IntervalColumnType.parse(type_name)
        unless plan && plan.shape == IntervalColumnType::Shape::Scalar
          raise UnsupportedFormatError.new("Interval accessor requires an exact scalar Interval column")
        end
        read.call
      end

      def self.read_nullable_counts(type_name : String, &read : -> Array(Int64?)) : Array(Int64?)
        plan = IntervalColumnType.parse(type_name)
        unless plan && plan.shape == IntervalColumnType::Shape::Nullable
          raise UnsupportedFormatError.new("Interval accessor requires an exact Nullable(Interval) column")
        end
        read.call
      end
    end
  end
end
