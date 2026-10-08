module CrystalClick
  module BinaryQBitRecursiveAdmission
    # Immutable owner for one static Array^n(QBit/Nullable(QBit)) site.
    # Role getters return detached Strings so the admission and schedule
    # visitors share shape metadata without exposing retained names.
    class StaticArraySite
      @column : QBitColumnType
      @array_size_roles : Array(String)
      @nullable_role : String?
      @plane_roles : Array(String)

      def initialize(
        @column : QBitColumnType,
        array_size_roles : Array(String),
        nullable_role : String?,
        plane_roles : Array(String),
      )
        @array_size_roles = copy_strings(array_size_roles)
        @nullable_role = nullable_role.try { |role| String.new(role.to_slice) }
        @plane_roles = copy_strings(plane_roles)
        unless !@array_size_roles.empty? && @plane_roles.size == @column.value_type.plane_count
          raise ArgumentError.new("static recursive QBit site has an invalid role roster")
        end
        unless @column.nullable == !@nullable_role.nil?
          raise ArgumentError.new("static recursive QBit nullable role differs from its nominal type")
        end
      end

      def column : QBitColumnType
        @column
      end

      def qbit_type : QBitType
        @column.value_type
      end

      def nullable? : Bool
        @column.nullable
      end

      def array_size_roles : Array(String)
        copy_strings(@array_size_roles)
      end

      def nullable_role? : String?
        @nullable_role.try { |role| String.new(role.to_slice) }
      end

      def plane_roles : Array(String)
        copy_strings(@plane_roles)
      end

      private def copy_strings(values : Array(String)) : Array(String)
        values.map { |value| String.new(value.to_slice) }
      end
    end
  end
end
