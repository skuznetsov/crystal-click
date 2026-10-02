module CrystalClick
  # Paired codec for the admitted ClickHouse binary DataType descriptor
  # grammar. Decode is exact-consumption and uses a strict minimal VarUInt
  # profile; it does not claim the upstream decoder requires minimality.
  module BinaryDataTypeCodec
    def self.encode(type : BinaryDataType, limits : BinaryCodecLimits = BinaryCodecLimits.default) : Bytes
      context = BinaryCodecContext.new(limits, nil, true)
      write_to(type, context)
      context.finish_bytes
    end

    def self.decode(bytes : Bytes, limits : BinaryCodecLimits = BinaryCodecLimits.default) : BinaryDataType
      context = BinaryCodecContext.new(limits, bytes)
      type = read_from(context)
      context.ensure_consumed
      type
    end

    # Internal shared entry point used by the typed value envelope so its type
    # and scalar visits consume one combined context budget.
    def self.write_to(type : BinaryDataType, context : BinaryCodecContext, depth : Int = 1) : Nil
      context.visit_node(depth)
      context.write_byte(type.tag)

      case type.tag
      when BinaryDataType::TAG_FIXED_STRING
        context.write_var_uint(type.fixed_size.not_nil!.to_u64)
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NULLABLE
        preflight_descriptor_children(type, context)
        context.ensure_depth(depth + 1)
        write_to(type.child_at(0), context, depth + 1)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        count = type.child_count
        context.charge_elements(count.to_u64) unless count == 0
        context.ensure_future_nodes(count.to_u64) unless count == 0
        context.ensure_depth(depth + 1) unless count == 0
        context.write_var_uint(count.to_u64)
        count.times do |index|
          if type.named_tuple?
            name_size = type.field_name_byte_size(index)
            context.write_var_uint(name_size.to_u64)
            context.ensure_output_bytes(name_size.to_u64)
            name_size.times do |byte_index|
              context.write_byte(type.field_name_byte_at(index, byte_index))
            end
          end
          write_to(type.child_at(index), context, depth + 1)
        end
      when BinaryDataType::TAG_MAP
        preflight_descriptor_children(type, context)
        context.ensure_depth(depth + 1)
        write_to(type.child_at(0), context, depth + 1)
        write_to(type.child_at(1), context, depth + 1)
      else
        # Legacy primitive descriptors have no parameters; W119 parameterized
        # leaves emit their narrow parameter suffix through this owner.
        BinaryScalarTypeCodec.write_parameters(type, context, depth)
      end
    end

    # Internal shared entry point used by the typed value envelope.
    def self.read_from(context : BinaryCodecContext, depth : Int = 1) : BinaryDataType
      context.visit_node(depth)
      tag = context.read_byte

      case tag
      when BinaryDataType::TAG_NOTHING,
           BinaryDataType::TAG_UINT8, BinaryDataType::TAG_UINT16,
           BinaryDataType::TAG_UINT32, BinaryDataType::TAG_UINT64,
           BinaryDataType::TAG_UINT128, BinaryDataType::TAG_UINT256,
           BinaryDataType::TAG_INT8, BinaryDataType::TAG_INT16,
           BinaryDataType::TAG_INT32, BinaryDataType::TAG_INT64,
           BinaryDataType::TAG_INT128, BinaryDataType::TAG_INT256,
           BinaryDataType::TAG_FLOAT32, BinaryDataType::TAG_FLOAT64,
           BinaryDataType::TAG_STRING, BinaryDataType::TAG_BOOL,
           BinaryDataType::TAG_BFLOAT16
        BinaryDataType.primitive(primitive_name(tag))
      when BinaryDataType::TAG_DATE, BinaryDataType::TAG_DATE32,
           BinaryDataType::TAG_DATETIME, BinaryDataType::TAG_DATETIME_ZONE,
           BinaryDataType::TAG_DATETIME64, BinaryDataType::TAG_DATETIME64_ZONE,
           BinaryDataType::TAG_ENUM8, BinaryDataType::TAG_ENUM16,
           BinaryDataType::TAG_DECIMAL32, BinaryDataType::TAG_DECIMAL64,
           BinaryDataType::TAG_DECIMAL128, BinaryDataType::TAG_DECIMAL256,
           BinaryDataType::TAG_UUID, BinaryDataType::TAG_IPV4,
           BinaryDataType::TAG_IPV6, BinaryDataType::TAG_TIME,
           BinaryDataType::TAG_TIME64
        BinaryScalarTypeCodec.read_type(tag, context, depth)
      when BinaryDataType::TAG_FIXED_STRING
        size = context.read_var_uint
        if size == 0_u64 || size > BinaryDataType::MAX_FIXED_STRING.to_u64
          context.corrupt!("FixedString descriptor size is outside ClickHouse's supported range")
        end
        BinaryDataType.fixed_string(size.to_i)
      when BinaryDataType::TAG_ARRAY
        context.preflight_children(1_u64)
        child = read_from(context, depth + 1)
        BinaryDataType.array(child)
      when BinaryDataType::TAG_NULLABLE
        context.preflight_children(1_u64)
        child = read_from(context, depth + 1)
        begin
          BinaryDataType.nullable(child)
        rescue ex : ArgumentError
          context.corrupt!("invalid Nullable child type: #{ex.message}")
        end
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        read_tuple(context, tag, depth)
      when BinaryDataType::TAG_MAP
        context.preflight_children(2_u64)
        key = read_from(context, depth + 1)
        value = read_from(context, depth + 1)
        begin
          BinaryDataType.map(key, value)
        rescue ex : ArgumentError
          context.corrupt!("invalid Map child types: #{ex.message}")
        end
      else
        if recognized_but_unsupported?(tag)
          context.unsupported!("ClickHouse binary DataType tag 0x#{tag.to_s(16)} is valid but not admitted")
        end
        context.corrupt!("unknown or reserved ClickHouse binary DataType tag 0x#{tag.to_s(16)}")
      end
    end

    private def self.read_tuple(context : BinaryCodecContext, tag : UInt8, depth : Int) : BinaryDataType
      raw_count = context.read_var_uint
      if raw_count > BinaryDataType::MAX_TUPLE_ARITY.to_u64
        context.corrupt!("Tuple arity exceeds ClickHouse's supported maximum")
      end
      count = raw_count.to_i32
      context.preflight_children(raw_count) unless raw_count == 0_u64

      if tag == BinaryDataType::TAG_UNNAMED_TUPLE
        context.ensure_depth(depth + 1) unless count == 0
        children = Array(BinaryDataType).new(count) do
          read_from(context, depth + 1)
        end
        BinaryDataType.tuple(children)
      else
        context.ensure_depth(depth + 1) unless count == 0
        children = [] of BinaryDataType
        names = [] of String
        count.times do
          name_length = context.read_var_uint
          if name_length > Int32::MAX.to_u64
            context.corrupt!("Tuple field name is too large")
          end
          raw_name = context.read_slice(name_length)
          names << String.new(raw_name)
          children << read_from(context, depth + 1)
        end
        begin
          BinaryDataType.tuple(children, names)
        rescue ex : ArgumentError
          context.corrupt!("invalid Tuple field names: #{ex.message}")
        end
      end
    end

    private def self.preflight_descriptor_children(type : BinaryDataType, context : BinaryCodecContext) : Nil
      count = type.child_count.to_u64
      context.preflight_children(count) unless count == 0_u64
    end

    private def self.primitive_name(tag : UInt8) : String
      case tag
      when BinaryDataType::TAG_NOTHING  then "Nothing"
      when BinaryDataType::TAG_UINT8    then "UInt8"
      when BinaryDataType::TAG_UINT16   then "UInt16"
      when BinaryDataType::TAG_UINT32   then "UInt32"
      when BinaryDataType::TAG_UINT64   then "UInt64"
      when BinaryDataType::TAG_UINT128  then "UInt128"
      when BinaryDataType::TAG_UINT256  then "UInt256"
      when BinaryDataType::TAG_INT8     then "Int8"
      when BinaryDataType::TAG_INT16    then "Int16"
      when BinaryDataType::TAG_INT32    then "Int32"
      when BinaryDataType::TAG_INT64    then "Int64"
      when BinaryDataType::TAG_INT128   then "Int128"
      when BinaryDataType::TAG_INT256   then "Int256"
      when BinaryDataType::TAG_FLOAT32  then "Float32"
      when BinaryDataType::TAG_FLOAT64  then "Float64"
      when BinaryDataType::TAG_STRING   then "String"
      when BinaryDataType::TAG_BOOL     then "Bool"
      when BinaryDataType::TAG_BFLOAT16 then "BFloat16"
      else
        raise CorruptPartError.new("invalid primitive DataType tag")
      end
    end

    private def self.recognized_but_unsupported?(tag : UInt8) : Bool
      (tag >= 0x0f_u8 && tag <= 0x32_u8) || tag == 0x34_u8 || tag == 0x36_u8 || tag == 0x37_u8
    end
  end
end
