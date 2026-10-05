module CrystalClick
  class WidePart
    # Keeps SimpleAggregateFunction's exact nominal and carrier gates at one
    # semantic reader boundary. The byte decoder remains WidePart's checked
    # fixed-width mark path; width alone never selects a carrier.
    private class SimpleAggregateColumnReader
      def self.read_numeric(type_name : String, type : T.class, &read : -> Array(T)) : Array(T) forall T
        plan = SimpleAggregateColumnType.parse(type_name)
        expected_storage = SimpleAggregateColumnType.storage_name(type)
        unless plan && plan.shape == SimpleAggregateColumnType::Shape::Scalar && plan.storage_type_name == expected_storage
          raise UnsupportedFormatError.new("SimpleAggregateFunction accessor requires an exact scalar carrier profile")
        end
        read.call
      end

      def self.read_nullable_numeric(type_name : String, type : T.class, &read : -> Array(T?)) : Array(T?) forall T
        plan = SimpleAggregateColumnType.parse(type_name)
        expected_storage = SimpleAggregateColumnType.storage_name(type)
        unless plan && plan.shape == SimpleAggregateColumnType::Shape::Nullable && plan.storage_type_name == expected_storage
          raise UnsupportedFormatError.new("SimpleAggregateFunction accessor requires an exact Nullable carrier profile")
        end
        read.call
      end

      # Retain the old UInt64 entry points as exact-carrier compatibility
      # guards, rather than allowing callers to reinterpret another child.
      def self.read_uint64(type_name : String, &read : -> Array(UInt64)) : Array(UInt64)
        read_numeric(type_name, UInt64, &read)
      end

      def self.read_nullable_uint64(type_name : String, &read : -> Array(UInt64?)) : Array(UInt64?)
        read_nullable_numeric(type_name, UInt64, &read)
      end
    end
  end
end
