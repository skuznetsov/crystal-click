module CrystalClick
  class WidePart
    # Keeps SimpleAggregateFunction's exact nominal gate at the semantic
    # reader boundary, then delegates UInt64 decoding to WidePart's checked
    # fixed-width mark paths.
    private class SimpleAggregateColumnReader
      def self.read_uint64(type_name : String, &read : -> Array(UInt64)) : Array(UInt64)
        plan = SimpleAggregateColumnType.parse(type_name)
        unless plan && plan.shape == SimpleAggregateColumnType::Shape::Scalar
          raise UnsupportedFormatError.new("SimpleAggregateFunction accessor requires an exact scalar UInt64 profile")
        end
        read.call
      end

      def self.read_nullable_uint64(type_name : String, &read : -> Array(UInt64?)) : Array(UInt64?)
        plan = SimpleAggregateColumnType.parse(type_name)
        unless plan && plan.shape == SimpleAggregateColumnType::Shape::Nullable
          raise UnsupportedFormatError.new("SimpleAggregateFunction accessor requires an exact Nullable scalar UInt64 profile")
        end
        read.call
      end
    end
  end
end
