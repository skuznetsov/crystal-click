module CrystalClick
  # Scalar leaf descriptor parameters for the W119 fixed-width repertoire.
  # Recursive/container grammar remains owned by BinaryDataTypeCodec.
  module BinaryScalarTypeCodec
    def self.write_parameters(type : BinaryDataType, context : BinaryCodecContext, depth : Int) : Nil
      case type.tag
      when BinaryDataType::TAG_DATETIME_ZONE
        zone = type.temporal_type.not_nil!.time_zone?.not_nil!.name
        write_string(zone, context)
      when BinaryDataType::TAG_DATETIME64
        scale = type.temporal_type.not_nil!.scale.not_nil!
        context.write_byte(scale.to_u8)
      when BinaryDataType::TAG_DATETIME64_ZONE
        temporal = type.temporal_type.not_nil!
        context.write_byte(temporal.scale.not_nil!.to_u8)
        write_string(temporal.time_zone?.not_nil!.name, context)
      when BinaryDataType::TAG_TIME64
        context.write_byte(type.temporal_type.not_nil!.scale.not_nil!.to_u8)
      when BinaryDataType::TAG_DECIMAL32, BinaryDataType::TAG_DECIMAL64,
           BinaryDataType::TAG_DECIMAL128, BinaryDataType::TAG_DECIMAL256
        decimal = type.decimal_type.not_nil!
        context.write_byte(decimal.precision.to_u8)
        context.write_byte(decimal.scale.to_u8)
      when BinaryDataType::TAG_ENUM8, BinaryDataType::TAG_ENUM16
        write_enum(type.enum_definition.not_nil!, context, depth)
      end
      nil
    end

    def self.read_type(tag : UInt8, context : BinaryCodecContext, depth : Int) : BinaryDataType
      case tag
      when BinaryDataType::TAG_DATE
        BinaryDataType.primitive("Date")
      when BinaryDataType::TAG_DATE32
        BinaryDataType.primitive("Date32")
      when BinaryDataType::TAG_DATETIME
        BinaryDataType.datetime
      when BinaryDataType::TAG_DATETIME_ZONE
        BinaryDataType.datetime(read_time_zone(context))
      when BinaryDataType::TAG_DATETIME64
        BinaryDataType.datetime64(read_scale(context, "DateTime64"))
      when BinaryDataType::TAG_DATETIME64_ZONE
        scale = read_scale(context, "DateTime64")
        BinaryDataType.datetime64(scale, read_time_zone(context))
      when BinaryDataType::TAG_TIME
        BinaryDataType.primitive("Time")
      when BinaryDataType::TAG_TIME64
        BinaryDataType.time64(read_scale(context, "Time64"))
      when BinaryDataType::TAG_UUID
        BinaryDataType.primitive("UUID")
      when BinaryDataType::TAG_IPV4
        BinaryDataType.primitive("IPv4")
      when BinaryDataType::TAG_IPV6
        BinaryDataType.primitive("IPv6")
      when BinaryDataType::TAG_DECIMAL32
        read_decimal(32, context)
      when BinaryDataType::TAG_DECIMAL64
        read_decimal(64, context)
      when BinaryDataType::TAG_DECIMAL128
        read_decimal(128, context)
      when BinaryDataType::TAG_DECIMAL256
        read_decimal(256, context)
      when BinaryDataType::TAG_ENUM8
        read_enum(8, context, depth)
      when BinaryDataType::TAG_ENUM16
        read_enum(16, context, depth)
      else
        context.corrupt!("invalid W119 scalar descriptor tag")
      end
    end

    private def self.write_string(value : String, context : BinaryCodecContext) : Nil
      bytes = value.to_slice
      context.write_var_uint(bytes.size.to_u64)
      context.write_slice(bytes)
    end

    private def self.read_time_zone(context : BinaryCodecContext) : String?
      size = context.read_var_uint
      bytes = context.read_slice(size)
      return nil if bytes.empty?

      name = String.new(bytes)
      admitted = TimezoneName.parse(name)
      context.unsupported!("timezone name is outside the pinned ClickHouse TimezoneName profile") unless admitted
      admitted.not_nil!.name
    end

    private def self.read_scale(context : BinaryCodecContext, family : String) : Int32
      scale = context.read_byte.to_i32
      context.corrupt!("#{family} scale must be between 0 and 9") if scale > 9
      scale
    end

    private def self.read_decimal(width_bits : Int32, context : BinaryCodecContext) : BinaryDataType
      precision = context.read_byte.to_i32
      scale = context.read_byte.to_i32
      begin
        BinaryDataType.decimal(width_bits, precision, scale)
      rescue ex : ArgumentError
        context.corrupt!("invalid Decimal#{width_bits} descriptor parameters: #{ex.message}")
      end
    end

    private def self.write_enum(definition : BinaryEnumDefinition, context : BinaryCodecContext, depth : Int) : Nil
      count = definition.size.to_u64
      maximum = definition.width_bits == 8 ? BinaryEnumDefinition::MAX_ENUM8_ENTRIES.to_u64 : BinaryEnumDefinition::MAX_ENUM16_ENTRIES.to_u64
      context.preflight_metadata(count, maximum_count: maximum, label: "Enum entry count")
      context.write_var_uint(count)
      count.to_i.times do |index|
        context.visit_node(depth)
        label_size = definition.label_byte_size(index)
        context.write_var_uint(label_size.to_u64)
        label_size.times do |byte_index|
          context.write_byte(definition.label_byte_at(index, byte_index))
        end
        code = definition.code_at(index)
        if definition.width_bits == 8
          context.write_byte(code.to_i8.unsafe_as(UInt8))
        else
          bits = code.unsafe_as(UInt16)
          context.write_byte((bits & 0xff_u16).to_u8)
          context.write_byte((bits >> 8).to_u8)
        end
      end
      nil
    end

    private def self.read_enum(width_bits : Int32, context : BinaryCodecContext, depth : Int) : BinaryDataType
      raw_count = context.read_var_uint
      if width_bits == 8
        maximum = BinaryEnumDefinition::MAX_ENUM8_ENTRIES.to_u64
        code_width = 1_u64
      else
        maximum = BinaryEnumDefinition::MAX_ENUM16_ENTRIES.to_u64
        code_width = 2_u64
      end

      count = context.preflight_metadata(
        raw_count,
        1_u64 + code_width,
        maximum,
        "Enum entry count"
      )
      entries = Array(BinaryEnumDefinition::Entry).new(count)
      count.times do
        context.visit_node(depth)
        label_size = context.read_var_uint
        label = String.new(context.read_slice(label_size))
        code = if width_bits == 8
                 context.read_byte.unsafe_as(Int8).to_i16
               else
                 low = context.read_byte.to_u16
                 high = context.read_byte.to_u16
                 (low | (high << 8)).unsafe_as(Int16)
               end
        entries << {label, code}
      end

      begin
        width_bits == 8 ? BinaryDataType.enum8(entries) : BinaryDataType.enum16(entries)
      rescue ex : ArgumentError
        context.corrupt!("invalid Enum#{width_bits} descriptor table: #{ex.message}")
      end
    end
  end
end
