module CrystalClick
  # Small physical helpers shared by the bounded LowCardinality dictionary
  # and index lane owners. This profile is mark-aligned: one index record per
  # nonempty mark and at most one global dictionary record per named coordinate.
  module BinaryLowCardinalityStorageStreams
    DICTIONARY_ROLE = "root.dictionary"
    INDEX_ROLE      = "root.indexes"
    VERSION         = 1_u64
    GLOBAL_BIT      = 1_u64 << 8
    ADDITIONAL_BIT  = 1_u64 << 9
    UPDATE_BIT      = 1_u64 << 10
    ALLOWED_MASK    = 0x703_u64

    def self.write_u64(context : BinaryCodecContext, value : UInt64) : Nil
      8.times do |index|
        context.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8)
      end
      nil
    end

    def self.read_u64(context : BinaryCodecContext) : UInt64
      value = 0_u64
      8.times do |index|
        value |= context.read_byte.to_u64 << (index * 8)
      end
      value
    end

    def self.write_index(context : BinaryCodecContext, value : UInt64, width : Int32) : Nil
      width.times do |index|
        context.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8)
      end
      nil
    end

    def self.read_index(context : BinaryCodecContext, width : Int32) : UInt64
      value = 0_u64
      width.times do |index|
        value |= context.read_byte.to_u64 << (index * 8)
      end
      value
    end

    def self.width_for_code(code : UInt64) : Int32
      1 << code.to_i32
    end

    def self.width_code_for_maximum(maximum : UInt64) : UInt64
      return 0_u64 if maximum <= UInt8::MAX.to_u64
      return 1_u64 if maximum <= UInt16::MAX.to_u64
      return 2_u64 if maximum <= UInt32::MAX.to_u64
      3_u64
    end

    def self.scalar_bytes(value : BinaryValue) : String
      bytes = Bytes.new(value.byte_size) { |index| value.byte_at(index) }
      String.new(bytes)
    end

    # String keys use their native length-prefixed scalar representation;
    # every other admitted key is the exact fixed-width column payload.
    def self.write_scalar(type : BinaryDataType, value : BinaryValue, context : BinaryCodecContext) : Nil
      unless value.type == type
        context.unsupported!("LowCardinality dictionary key does not match its scalar type")
      end
      case type.tag
      when BinaryDataType::TAG_STRING
        size = value.byte_size.to_u64
        context.write_var_uint(size)
        size.to_i.times { |index| context.write_byte(value.byte_at(index)) }
      when BinaryDataType::TAG_BOOL
        context.write_byte(BoolValueCodec.encode(value.as_bool))
      else
        width = type.fixed_width || context.unsupported!("unsupported LowCardinality dictionary scalar")
        unless value.byte_size == width
          context.unsupported!("LowCardinality fixed dictionary key has an invalid width")
        end
        width.times { |index| context.write_byte(value.byte_at(index)) }
      end
      nil
    end

    def self.read_scalar(type : BinaryDataType, context : BinaryCodecContext) : BinaryValue
      case type.tag
      when BinaryDataType::TAG_STRING
        size = context.read_var_uint
        BinaryValue.string(String.new(context.read_slice(size)))
      when BinaryDataType::TAG_BOOL
        BinaryValue.bool(BoolValueCodec.decode(context.read_byte))
      else
        width = type.fixed_width || context.unsupported!("unsupported LowCardinality dictionary scalar")
        BinaryValue.fixed(type, context.read_slice(width.to_u64))
      end
    end

    def self.default_scalar(type : BinaryDataType) : BinaryValue
      case type.tag
      when BinaryDataType::TAG_STRING
        BinaryValue.string("")
      when BinaryDataType::TAG_BOOL
        BinaryValue.bool(false)
      else
        width = type.fixed_width || raise UnsupportedFormatError.new("unsupported LowCardinality dictionary scalar")
        BinaryValue.fixed(type, Bytes.new(width) { 0_u8 })
      end
    end

    def self.is_default_scalar?(type : BinaryDataType, value : BinaryValue) : Bool
      case type.tag
      when BinaryDataType::TAG_STRING
        value.byte_size == 0
      when BinaryDataType::TAG_BOOL
        !value.as_bool
      else
        width = type.fixed_width || return false
        return false unless value.byte_size == width
        width.times.all? { |index| value.byte_at(index) == 0_u8 }
      end
    end

    # Equality is over raw physical payload bits. In particular Float32/64
    # NaNs and signed zero are never canonicalized by numeric comparison.
    def self.same_scalar?(left : BinaryValue, right : BinaryValue) : Bool
      return false unless left.type == right.type && left.byte_size == right.byte_size
      left.byte_size.times.all? { |index| left.byte_at(index) == right.byte_at(index) }
    end

    def self.checked_add(left : UInt64, right : UInt64, message : String) : UInt64
      if left > UInt64::MAX - right
        raise CorruptPartError.new(message)
      end
      left + right
    end

    def self.checked_multiply(left : UInt64, right : UInt64, message : String) : UInt64
      return 0_u64 if left == 0_u64 || right == 0_u64
      if left > UInt64::MAX // right
        raise CorruptPartError.new(message)
      end
      left * right
    end

    def self.unwrap(type : BinaryDataType) : {Bool, BinaryDataType}
      if type.tag == BinaryDataType::TAG_NULLABLE
        {true, type.child_at(0)}
      else
        {false, type}
      end
    end

    def self.ensure_root_type(type : BinaryDataType, context : BinaryCodecContext) : {Bool, BinaryDataType}
      unless type.tag == BinaryDataType::TAG_LOW_CARDINALITY && type.child_count == 1
        context.unsupported!("LowCardinality storage codec requires a LowCardinality root")
      end
      child = type.child_at(0)
      unless BinaryLowCardinalityTypePolicy.admitted_child?(child)
        context.unsupported!("LowCardinality child is outside the represented scalar profile")
      end
      nullable, leaf = unwrap(child)
      unless leaf.tag == BinaryDataType::TAG_STRING || leaf.tag == BinaryDataType::TAG_BOOL || leaf.fixed_width
        context.unsupported!("LowCardinality child has no represented scalar storage")
      end
      {nullable, leaf}
    end
  end
end
