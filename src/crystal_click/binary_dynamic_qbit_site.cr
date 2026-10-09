module CrystalClick
  # One direct QBit leaf in a prepared Dynamic actual roster. Plane roles keep
  # numeric traversal order; callers receive detached names and rosters.
  class BinaryDynamicQBitSite
    @path : String
    @type : BinaryDataType
    @plane_roles : Array(String)
    @column : QBitColumnType

    def initialize(path : String, @type : BinaryDataType, plane_roles : Array(String))
      qbit = @type.qbit_type || raise(ArgumentError.new("Dynamic QBit site requires a nominal QBit descriptor"))
      @column = QBitColumnType.new(qbit)
      unless plane_roles.size == qbit.plane_count
        raise ArgumentError.new("Dynamic QBit plane roles do not match the nominal descriptor")
      end
      @path = String.new(path.to_slice)
      @plane_roles = plane_roles.map { |role| String.new(role.to_slice) }
    end

    def path : String
      String.new(@path.to_slice)
    end

    def path_bytesize : UInt64
      @path.bytesize.to_u64
    end

    def matches_path?(path : String) : Bool
      @path == path
    end

    def type : BinaryDataType
      @type
    end

    def qbit_type : QBitType
      @type.qbit_type || raise UnsupportedFormatError.new("Dynamic QBit site is missing its nominal type")
    end

    def plane_width : Int32
      qbit_type.plane_width
    end

    def plane_roles : Array(String)
      @plane_roles.map { |role| String.new(role.to_slice) }
    end

    # Logical byte-work needed to detach the numeric-order role roster.
    def plane_role_bytesize : UInt64
      total = 0_u64
      @plane_roles.each do |role|
        size = role.bytesize.to_u64
        if total > UInt64::MAX - size
          raise UnsupportedFormatError.new("Dynamic QBit role byte count overflows UInt64")
        end
        total += size
      end
      total
    end

    # Keep the retained numeric plane roster private while allowing the bulk
    # visitor to reuse its one caller-owned scratch buffer for every row.
    def append_plane_row(value : QBitValue, scratch : Bytes, &write_byte : String, UInt8 -> Nil) : Nil
      BinaryQBitBulkCodec.append_plane_row(value, @plane_roles, 0, scratch) do |role, byte|
        yield role, byte
      end
    end

    def append_zero_planes(scratch : Bytes, &write_byte : String, UInt8 -> Nil) : Nil
      BinaryQBitBulkCodec.append_zero_planes(@column, @plane_roles, 0, scratch) do |role, byte|
        yield role, byte
      end
    end

    def detached_copy : BinaryDynamicQBitSite
      BinaryDynamicQBitSite.new(@path, @type, @plane_roles)
    end
  end
end
