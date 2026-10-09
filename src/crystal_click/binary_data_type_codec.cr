require "./binary_shared_json_envelope_policy"

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
      if type.geometry_storage_variant?
        context.unsupported!("Geometry's fixed-order storage Variant cannot be encoded independently")
      end
      tag = type.tag
      if type.tag == BinaryDataType::TAG_QBIT
        descriptor = type.qbit_type || context.unsupported!("QBit descriptor metadata is missing")
        tag = BinaryDataType::TAG_QBIT_STRIDE if descriptor.stride != descriptor.dimension
      end
      if context.shared_json_envelope_policy?
        BinarySharedJsonEnvelopePolicy.check_data_type_tag!(context, tag)
      end
      context.write_byte(tag)

      case type.tag
      when BinaryDataType::TAG_QBIT
        BinaryQBitTypeCodec.write(type, context, depth)
      when BinaryDataType::TAG_DYNAMIC
        context.write_byte(type.dynamic_max_types.not_nil!)
      when BinaryDataType::TAG_CUSTOM
        descriptor = type.custom_geo_type || context.unsupported!("Custom Geo descriptor metadata is missing")
        descriptor.preflight_expansion(context.budget, depth)
        name = descriptor.name.to_slice
        context.write_var_uint(name.size.to_u64)
        context.write_slice(name)
      when BinaryDataType::TAG_FIXED_STRING
        context.write_var_uint(type.fixed_size.not_nil!.to_u64)
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NULLABLE, BinaryDataType::TAG_LOW_CARDINALITY
        preflight_descriptor_children(type, context)
        context.ensure_depth(depth + 1)
        write_to(type.child_at(0), context, depth + 1)
      when BinaryDataType::TAG_SIMPLE_AGGREGATE
        descriptor = type.simple_aggregate_type.not_nil!
        function_name = descriptor.function_name.to_slice
        context.write_var_uint(function_name.size.to_u64)
        context.write_slice(function_name)
        parameter_count = descriptor.parameters.count.to_u64
        context.preflight_metadata(parameter_count, maximum_count: 1_u64, label: "SimpleAggregateFunction parameter count")
        context.write_var_uint(parameter_count)
        descriptor.parameters.count.times do |index|
          context.visit_node(depth)
          context.write_byte(1_u8) # Field::UInt64
          context.write_var_uint(descriptor.parameters.value_at(index))
        end
        context.write_var_uint(1_u64) # argument types
        preflight_descriptor_children(type, context)
        context.ensure_depth(depth + 1)
        write_to(type.child_at(0), context, depth + 1)
      when BinaryDataType::TAG_AGGREGATE_FUNCTION
        descriptor = type.aggregate_function_type || context.unsupported!("AggregateFunction descriptor metadata is missing")
        context.write_var_uint(descriptor.version.to_u64)
        function_name = descriptor.function_name.to_slice
        context.write_var_uint(function_name.size.to_u64)
        context.write_slice(function_name)
        context.write_var_uint(0_u64) # parameters
        argument = descriptor.argument_type
        context.write_var_uint(argument.nil? ? 0_u64 : 1_u64)
        if argument
          context.preflight_children(1_u64)
          context.ensure_depth(depth + 1)
          write_to(argument, context, depth + 1)
        end
      when BinaryDataType::TAG_JSON
        descriptor = type.json_type || context.unsupported!("JSON descriptor metadata is missing")
        BinaryJsonTypeCodec.write(descriptor, context, depth)
      when BinaryDataType::TAG_VARIANT
        count = type.child_count
        context.preflight_children(count.to_u64)
        context.ensure_depth(depth + 1)
        context.write_var_uint(count.to_u64)
        count.times do |index|
          write_to(type.child_at(index), context, depth + 1)
        end
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
      when BinaryDataType::TAG_NESTED
        tuple_type = BinaryNestedType.tuple_for(type)
        # Nested has one implicit named-Tuple node even though the wire omits
        # the Tuple tag. Charge its root edge/node before field metadata.
        context.preflight_children(1_u64)
        context.ensure_depth(depth + 1)
        context.visit_node(depth + 1)
        count = tuple_type.child_count.to_u64
        context.preflight_children(count)
        context.ensure_depth(depth + 2)
        context.write_var_uint(count)
        tuple_type.child_count.times do |index|
          name_size = tuple_type.field_name_byte_size(index)
          context.write_var_uint(name_size.to_u64)
          context.ensure_output_bytes(name_size.to_u64)
          name_size.times do |byte_index|
            context.write_byte(tuple_type.field_name_byte_at(index, byte_index))
          end
          write_to(tuple_type.child_at(index), context, depth + 2)
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
      if context.shared_json_envelope_policy?
        BinarySharedJsonEnvelopePolicy.check_data_type_tag!(context, tag)
      end

      case tag
      when BinaryDataType::TAG_QBIT, BinaryDataType::TAG_QBIT_WITH_STRIDE
        BinaryQBitTypeCodec.read(tag, context, depth)
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
           BinaryDataType::TAG_TIME64, BinaryDataType::TAG_INTERVAL
        BinaryScalarTypeCodec.read_type(tag, context, depth)
      when BinaryDataType::TAG_FIXED_STRING
        size = context.read_var_uint
        if size == 0_u64 || size > BinaryDataType::MAX_FIXED_STRING.to_u64
          context.corrupt!("FixedString descriptor size is outside ClickHouse's supported range")
        end
        BinaryDataType.fixed_string(size.to_i)
      when BinaryDataType::TAG_DYNAMIC
        max_types = context.read_byte
        if max_types == 0xff_u8
          context.corrupt!("Dynamic max_types 255 is outside the local normal-type profile")
        end
        BinaryDataType.dynamic(max_types.to_i)
      when BinaryDataType::TAG_CUSTOM
        name_length = context.read_var_uint
        if name_length == 0_u64 || name_length > BinaryCustomGeoType::MAX_NAME_BYTES.to_u64
          context.unsupported!("Custom Geo name is outside the admitted alias profile")
        end
        name = String.new(context.read_slice(name_length))
        descriptor = begin
          BinaryCustomGeoType.new(name)
        rescue ex : ArgumentError
          context.unsupported!("Custom Geo name is outside the admitted alias profile")
        end
        # A Custom tag is wire-compact: account for its full implicit storage
        # tree now, under this caller's budget, before constructing that tree.
        descriptor.preflight_expansion(context.budget, depth)
        BinaryDataType.custom(descriptor.name)
      when BinaryDataType::TAG_JSON
        BinaryJsonTypeCodec.read(context, depth)
      when BinaryDataType::TAG_ARRAY
        context.preflight_children(1_u64)
        child = read_from(context, depth + 1)
        unless BinaryDataType.admitted_array_qbit_child?(child)
          context.unsupported!("QBit is outside the admitted Array profile")
        end
        BinaryDataType.array(child)
      when BinaryDataType::TAG_SIMPLE_AGGREGATE
        name_length = context.read_var_uint
        if name_length > BinarySimpleAggregateType::MAX_FUNCTION_NAME_BYTES.to_u64
          context.unsupported!("SimpleAggregateFunction name is outside the admitted function profile")
        end
        raw_name = context.read_slice(name_length)
        function_name = String.new(raw_name)
        unless function = BinarySimpleAggregateType.function_from_name(function_name)
          context.unsupported!("SimpleAggregateFunction function is outside the admitted function profile")
        end
        parameter_count = context.read_var_uint
        if parameter_count > 1_u64
          context.unsupported!("SimpleAggregateFunction parameter count is outside the admitted profile")
        end
        unless BinarySimpleAggregateAdmission.parameter_count_allowed?(function, parameter_count)
          context.unsupported!("SimpleAggregateFunction function does not admit this parameter count")
        end
        context.preflight_metadata(
          parameter_count,
          2_u64,
          1_u64,
          "SimpleAggregateFunction parameter count",
        )
        context.visit_metadata_nodes(parameter_count, depth)
        parameter_values = [] of UInt64
        parameter_count.to_i.times do
          field_tag = context.read_byte
          unless field_tag == 1_u8
            context.unsupported!("SimpleAggregateFunction parameter Field kind is outside the UInt64 profile")
          end
          value = context.read_var_uint
          if value == 0_u64
            context.unsupported!("SimpleAggregateFunction UInt64 parameter must be positive")
          end
          parameter_values << value
        end
        parameters = begin
          BinarySimpleAggregateParameters.new(parameter_values)
        rescue ex : ArgumentError
          context.unsupported!("SimpleAggregateFunction parameters are outside the admitted Field profile")
        end
        argument_count = context.read_var_uint
        if argument_count != 1_u64
          context.unsupported!("SimpleAggregateFunction argument count is outside the admitted unary profile")
        end
        context.preflight_children(1_u64)
        context.ensure_depth(depth + 1)
        child = read_from(context, depth + 1)
        begin
          BinaryDataType.simple_aggregate(function, child, parameters)
        rescue ex : ArgumentError
          context.unsupported!("SimpleAggregateFunction function/storage pair is outside the admitted storage profile")
        end
      when BinaryDataType::TAG_AGGREGATE_FUNCTION
        version = context.read_var_uint
        unless version == BinaryAggregateFunctionType::VERSION.to_u64
          context.unsupported!("AggregateFunction version is outside the admitted profile")
        end
        name_length = context.read_var_uint
        if name_length == 0_u64 || name_length > BinaryAggregateFunctionAdmission::MAX_FUNCTION_NAME_BYTES.to_u64
          context.unsupported!("AggregateFunction name is outside the admitted function profile")
        end
        function_name = String.new(context.read_slice(name_length))
        unless function_name == "count" || function_name == "sum" || function_name == "sumWithOverflow" || function_name == "sumKahan" || function_name == "avg" || function_name == "min" || function_name == "max"
          context.unsupported!("AggregateFunction function is outside the admitted profile")
        end
        parameter_count = context.read_var_uint
        unless parameter_count == 0_u64
          # These functions all have zero parameters. Refuse the count before
          # attempting to decode any Field payload so malformed parameter
          # bytes cannot hide an unsupported function signature.
          context.unsupported!("parameterized AggregateFunction is outside the admitted profile")
        end
        argument_count = context.read_var_uint
        if function_name == "count"
          unless argument_count <= 1_u64
            context.unsupported!("AggregateFunction(count) argument count is outside the admitted profile")
          end
        elsif argument_count != 1_u64
          if function_name == "avg"
            context.unsupported!("AggregateFunction avg argument count is outside the admitted unary profile")
          elsif function_name == "min" || function_name == "max"
            context.unsupported!("AggregateFunction #{function_name} argument count is outside the admitted unary profile")
          else
            context.unsupported!("AggregateFunction Sum argument count is outside the admitted unary profile")
          end
        end
        if function_name == "count" && argument_count == 0_u64
          BinaryDataType.aggregate_count
        else
          context.preflight_children(1_u64)
          context.ensure_depth(depth + 1)
          argument = read_from(context, depth + 1)
          begin
            type = if function_name == "count"
                     BinaryDataType.aggregate_count(argument)
                   else
                     BinaryDataType.aggregate_function(function_name, argument)
                   end
            unless type.aggregate_function_type.try(&.function_name) == function_name
              context.unsupported!("AggregateFunction function identity is not canonical for its argument")
            end
            type
          rescue ex : ArgumentError
            context.unsupported!("AggregateFunction argument type is outside the admitted profile")
          end
        end
      when BinaryDataType::TAG_NULLABLE
        context.preflight_children(1_u64)
        child = read_from(context, depth + 1)
        begin
          BinaryDataType.nullable(child)
        rescue ex : ArgumentError
          context.corrupt!("invalid Nullable child type: #{ex.message}")
        end
      when BinaryDataType::TAG_LOW_CARDINALITY
        context.preflight_children(1_u64)
        context.ensure_depth(depth + 1)
        child = read_from(context, depth + 1)
        if child.contains_json?
          context.unsupported!("JSON is outside the admitted LowCardinality child profile")
        end
        begin
          BinaryDataType.low_cardinality(child)
        rescue ex : ArgumentError
          context.corrupt!("invalid LowCardinality child type: #{ex.message}")
        end
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        read_tuple(context, tag, depth)
      when BinaryDataType::TAG_NESTED
        read_nested(context, depth)
      when BinaryDataType::TAG_MAP
        context.preflight_children(2_u64)
        key = read_from(context, depth + 1)
        value = read_from(context, depth + 1)
        begin
          BinaryDataType.map(key, value)
        rescue ex : ArgumentError
          context.corrupt!("invalid Map child types: #{ex.message}")
        end
      when BinaryDataType::TAG_VARIANT
        raw_count = context.read_var_uint
        if raw_count == 0_u64 || raw_count > BinaryVariantRoster::MAX_ARMS.to_u64
          context.corrupt!("Variant wire roster must contain between 1 and 255 arms")
        end
        count = context.preflight_metadata(
          raw_count,
          1_u64,
          BinaryVariantRoster::MAX_ARMS.to_u64,
          "Variant arm count"
        )
        context.ensure_depth(depth + 1)
        arms = Array(BinaryDataType).new(count) do
          read_from(context, depth + 1)
        end
        BinaryDataType.variant_from_wire(arms, context, depth)
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
        begin
          BinaryDataType.tuple(children)
        rescue ex : ArgumentError
          context.corrupt!("invalid Tuple child types: #{ex.message}")
        end
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

    private def self.read_nested(context : BinaryCodecContext, depth : Int) : BinaryDataType
      raw_count = context.read_var_uint
      if raw_count == 0_u64 || raw_count > BinaryDataType::MAX_TUPLE_ARITY.to_u64
        context.corrupt!("Nested field count is outside ClickHouse's supported range")
      end

      # Match the constructed graph: Nested root -> implicit Tuple -> fields.
      # Both edges and the Tuple node are charged before either field array is
      # allocated, sharing the enclosing descriptor operation's budget.
      context.preflight_children(1_u64)
      context.ensure_depth(depth + 1)
      context.visit_node(depth + 1)
      context.preflight_children(raw_count)
      context.ensure_depth(depth + 2)

      count = raw_count.to_i32
      children = [] of BinaryDataType
      names = [] of String
      count.times do
        name_length = context.read_var_uint
        if name_length > Int32::MAX.to_u64
          context.corrupt!("Nested field name is too large")
        end
        raw_name = context.read_slice(name_length)
        names << String.new(raw_name)
        children << read_from(context, depth + 2)
      end
      begin
        BinaryDataType.nested(children, names)
      rescue ex : ArgumentError
        context.corrupt!("invalid Nested field names: #{ex.message}")
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
      (tag >= 0x0f_u8 && tag <= 0x32_u8 && tag != BinaryDataType::TAG_INTERVAL) ||
        tag == 0x34_u8
    end
  end
end
