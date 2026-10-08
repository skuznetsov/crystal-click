module CrystalClick
  module BinaryQBitRecursiveAdmission
    # One immutable QBit occurrence inside an admitted static product tree.
    # All public String/Array accessors return detached values: consumers may
    # inspect or mutate their copies without changing the plan's role identity.
    class StaticSite
      @path : String
      @column : QBitColumnType
      @plane_roles : Array(String)
      @size_roles : Array(String)
      @nullable_roles : Array(String)
      @nullable_role : String?

      def initialize(
        path : String,
        @column : QBitColumnType,
        plane_roles : Array(String),
        size_roles : Array(String),
        nullable_roles : Array(String),
        nullable_role : String?,
      )
        @path = String.new(path.to_slice)
        @plane_roles = copy_strings(plane_roles)
        @size_roles = copy_strings(size_roles)
        @nullable_roles = copy_strings(nullable_roles)
        @nullable_role = nullable_role.try { |role| String.new(role.to_slice) }
        unless !@path.empty? && @plane_roles.size == @column.value_type.plane_count
          raise ArgumentError.new("static QBit site has an invalid path or plane roster")
        end
        unless @column.nullable == !@nullable_role.nil?
          raise ArgumentError.new("static QBit leaf null role differs from its nominal type")
        end
        if role = @nullable_role
          unless @nullable_roles.includes?(role)
            raise ArgumentError.new("static QBit leaf null role is absent from its nullable ancestry")
          end
        end
      end

      def path : String
        String.new(@path.to_slice)
      end

      # Internal path comparison for recursive visitors. This avoids making a
      # detached String for every QBit value while keeping the stored path
      # unreachable through the public accessor.
      def matches_path?(candidate : String) : Bool
        @path == candidate
      end

      def path_bytesize : UInt64
        @path.bytesize.to_u64
      end

      def plane_role_bytesize : UInt64
        total = 0_u64
        @plane_roles.each do |role|
          size = role.bytesize.to_u64
          if total > UInt64::MAX - size
            raise ArgumentError.new("static QBit plane role byte count overflows UInt64")
          end
          total += size
        end
        total
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

      def plane_roles : Array(String)
        copy_strings(@plane_roles)
      end

      def size_roles : Array(String)
        copy_strings(@size_roles)
      end

      def nullable_roles : Array(String)
        copy_strings(@nullable_roles)
      end

      # Compatibility name for W230's direct Nullable(QBit) site law.
      # Nullable(Tuple(QBit,...)) ancestry is exposed by `nullable_roles` and
      # does not make each QBit leaf itself nullable.
      def nullable_role? : String?
        @nullable_role.try { |role| String.new(role.to_slice) }
      end

      # Reuse the shared scalar QBit codec while keeping the site's stored
      # numeric-order role names detached from callers.
      def append_plane_row(
        value : QBitValue,
        scratch : Bytes,
        &write_byte : String, UInt8 -> Nil
      ) : Nil
        BinaryQBitBulkCodec.append_plane_row(value, @plane_roles, 0, scratch, &write_byte)
      end

      def append_zero_planes(
        scratch : Bytes,
        &write_byte : String, UInt8 -> Nil
      ) : Nil
        BinaryQBitBulkCodec.append_zero_planes(@column, @plane_roles, 0, scratch, &write_byte)
      end

      private def copy_strings(values : Array(String)) : Array(String)
        values.map { |value| String.new(value.to_slice) }
      end
    end
  end
end
