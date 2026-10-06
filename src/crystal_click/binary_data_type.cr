require "set"

module CrystalClick
  # Immutable, nominal ClickHouse binary data-type descriptor for the bounded
  # W117-W119 descriptor/value kernel. A familiar display name is not enough
  # to admit an otherwise unsupported type or imply broader part support.
  class BinaryDataType
    TAG_NOTHING          = 0x00_u8
    TAG_UINT8            = 0x01_u8
    TAG_UINT16           = 0x02_u8
    TAG_UINT32           = 0x03_u8
    TAG_UINT64           = 0x04_u8
    TAG_UINT128          = 0x05_u8
    TAG_UINT256          = 0x06_u8
    TAG_INT8             = 0x07_u8
    TAG_INT16            = 0x08_u8
    TAG_INT32            = 0x09_u8
    TAG_INT64            = 0x0a_u8
    TAG_INT128           = 0x0b_u8
    TAG_INT256           = 0x0c_u8
    TAG_FLOAT32          = 0x0d_u8
    TAG_FLOAT64          = 0x0e_u8
    TAG_DATE             = 0x0f_u8
    TAG_DATE32           = 0x10_u8
    TAG_DATETIME         = 0x11_u8
    TAG_DATETIME_ZONE    = 0x12_u8
    TAG_DATETIME64       = 0x13_u8
    TAG_DATETIME64_ZONE  = 0x14_u8
    TAG_STRING           = 0x15_u8
    TAG_FIXED_STRING     = 0x16_u8
    TAG_ENUM8            = 0x17_u8
    TAG_ENUM16           = 0x18_u8
    TAG_DECIMAL32        = 0x19_u8
    TAG_DECIMAL64        = 0x1a_u8
    TAG_DECIMAL128       = 0x1b_u8
    TAG_DECIMAL256       = 0x1c_u8
    TAG_UUID             = 0x1d_u8
    TAG_ARRAY            = 0x1e_u8
    TAG_UNNAMED_TUPLE    = 0x1f_u8
    TAG_NAMED_TUPLE      = 0x20_u8
    TAG_AGGREGATE_COUNT  = 0x25_u8
    TAG_INTERVAL         = 0x22_u8
    TAG_LOW_CARDINALITY  = 0x26_u8
    TAG_NULLABLE         = 0x23_u8
    TAG_MAP              = 0x27_u8
    TAG_IPV4             = 0x28_u8
    TAG_IPV6             = 0x29_u8
    TAG_VARIANT          = 0x2a_u8
    TAG_DYNAMIC          = 0x2b_u8
    TAG_BOOL             = 0x2d_u8
    TAG_SIMPLE_AGGREGATE = 0x2e_u8
    TAG_NESTED           = 0x2f_u8
    TAG_JSON             = 0x30_u8
    TAG_BFLOAT16         = 0x31_u8
    TAG_TIME             = 0x32_u8
    TAG_TIME64           = 0x34_u8
    TAG_QBIT             = 0x36_u8
    TAG_QBIT_STRIDE      = 0x37_u8
    TAG_QBIT_WITH_STRIDE = TAG_QBIT_STRIDE
    MAX_FIXED_STRING     = 0x00ff_ffff
    MAX_TUPLE_ARITY      =   1_000_000

    getter tag : UInt8
    getter fixed_size : Int32?
    # Immutable composition invariant for admission guards. Computing it from
    # immediate, already-immutable children avoids an unbounded recursive walk
    # before an enclosing codec has validated a caller-supplied type tree.
    getter? contains_low_cardinality : Bool
    getter? contains_variant : Bool
    getter? contains_dynamic : Bool
    getter? contains_nested : Bool
    getter? contains_aggregate_count : Bool
    getter? contains_qbit : Bool
    getter? contains_json : Bool
    getter dynamic_max_types : UInt8?

    @primitive_name : String?
    @children : Array(BinaryDataType)
    @field_names : Array(String)
    @temporal_type : BinaryTemporalType?
    @decimal_type : BinaryDecimalType?
    @enum_definition : BinaryEnumDefinition?
    @interval_type : BinaryIntervalType?
    @simple_aggregate_type : BinarySimpleAggregateType?
    @aggregate_count_type : BinaryAggregateCountType?
    @qbit_type : QBitType?
    @json_type : BinaryJsonType?

    private def initialize(
      @tag : UInt8,
      @primitive_name : String?,
      children : Array(BinaryDataType),
      field_names : Array(String),
      @fixed_size : Int32?,
      @temporal_type : BinaryTemporalType? = nil,
      @decimal_type : BinaryDecimalType? = nil,
      @enum_definition : BinaryEnumDefinition? = nil,
      @dynamic_max_types : UInt8? = nil,
      @interval_type : BinaryIntervalType? = nil,
      @simple_aggregate_type : BinarySimpleAggregateType? = nil,
      @aggregate_count_type : BinaryAggregateCountType? = nil,
      @qbit_type : QBitType? = nil,
      @json_type : BinaryJsonType? = nil,
    )
      @children = children.dup
      @field_names = field_names.map { |name| String.new(name.to_slice) }
      @contains_low_cardinality = @tag == TAG_LOW_CARDINALITY || @children.any?(&.contains_low_cardinality?)
      @contains_variant = @tag == TAG_VARIANT || @children.any?(&.contains_variant?)
      @contains_dynamic = @tag == TAG_DYNAMIC || @children.any?(&.contains_dynamic?)
      @contains_nested = @tag == TAG_NESTED || @children.any?(&.contains_nested?)
      # AggregateFunction(count) arguments are separate descriptor metadata,
      # not generic type/value composition children. This summary only marks
      # Count itself and any physical composition child that illegally wraps it.
      @contains_aggregate_count = @tag == TAG_AGGREGATE_COUNT || @children.any?(&.contains_aggregate_count?)
      @contains_qbit = @tag == TAG_QBIT || @children.any?(&.contains_qbit?)
      @contains_json = @tag == TAG_JSON || @children.any?(&.contains_json?)
    end

    def self.primitive(name : String) : BinaryDataType
      detached = String.new(name.to_slice)
      tag = case detached
            when "Nothing"  then TAG_NOTHING
            when "UInt8"    then TAG_UINT8
            when "UInt16"   then TAG_UINT16
            when "UInt32"   then TAG_UINT32
            when "UInt64"   then TAG_UINT64
            when "UInt128"  then TAG_UINT128
            when "UInt256"  then TAG_UINT256
            when "Int8"     then TAG_INT8
            when "Int16"    then TAG_INT16
            when "Int32"    then TAG_INT32
            when "Int64"    then TAG_INT64
            when "Int128"   then TAG_INT128
            when "Int256"   then TAG_INT256
            when "Float32"  then TAG_FLOAT32
            when "Float64"  then TAG_FLOAT64
            when "Date"     then TAG_DATE
            when "Date32"   then TAG_DATE32
            when "Time"     then TAG_TIME
            when "UUID"     then TAG_UUID
            when "IPv4"     then TAG_IPV4
            when "IPv6"     then TAG_IPV6
            when "BFloat16" then TAG_BFLOAT16
            when "String"   then TAG_STRING
            when "Bool"     then TAG_BOOL
            else
              raise ArgumentError.new("unsupported binary primitive type")
            end
      new(tag, detached, [] of BinaryDataType, [] of String, nil)
    end

    def self.datetime(time_zone : String? = nil) : BinaryDataType
      parameters = BinaryTemporalType.datetime(time_zone)
      tag = parameters.explicit_time_zone? ? TAG_DATETIME_ZONE : TAG_DATETIME
      new(tag, nil, [] of BinaryDataType, [] of String, nil, parameters)
    end

    def self.datetime64(scale : Int, time_zone : String? = nil) : BinaryDataType
      parameters = BinaryTemporalType.datetime64(scale, time_zone)
      tag = parameters.explicit_time_zone? ? TAG_DATETIME64_ZONE : TAG_DATETIME64
      new(tag, nil, [] of BinaryDataType, [] of String, nil, parameters)
    end

    def self.time64(scale : Int) : BinaryDataType
      parameters = BinaryTemporalType.time64(scale)
      new(TAG_TIME64, nil, [] of BinaryDataType, [] of String, nil, parameters)
    end

    def self.interval(kind : BinaryIntervalType::Kind) : BinaryDataType
      interval_type = BinaryIntervalType.new(kind)
      new(TAG_INTERVAL, nil, [] of BinaryDataType, [] of String, nil, nil, nil, nil, nil, interval_type)
    end

    def self.decimal(width_bits : Int, precision : Int, scale : Int) : BinaryDataType
      parameters = BinaryDecimalType.new(width_bits, precision, scale)
      tag = case parameters.width_bits
            when  32 then TAG_DECIMAL32
            when  64 then TAG_DECIMAL64
            when 128 then TAG_DECIMAL128
            else          TAG_DECIMAL256
            end
      new(tag, nil, [] of BinaryDataType, [] of String, nil, nil, parameters)
    end

    def self.enum8(entries : Array(BinaryEnumDefinition::Entry)) : BinaryDataType
      definition = BinaryEnumDefinition.new(8, entries)
      new(TAG_ENUM8, nil, [] of BinaryDataType, [] of String, nil, nil, nil, definition)
    end

    def self.enum16(entries : Array(BinaryEnumDefinition::Entry)) : BinaryDataType
      definition = BinaryEnumDefinition.new(16, entries)
      new(TAG_ENUM16, nil, [] of BinaryDataType, [] of String, nil, nil, nil, definition)
    end

    def self.fixed_string(size : Int) : BinaryDataType
      unless size > 0 && size <= MAX_FIXED_STRING
        raise ArgumentError.new("FixedString size is outside ClickHouse's supported range")
      end
      new(TAG_FIXED_STRING, nil, [] of BinaryDataType, [] of String, size.to_i32)
    end

    # QBit's element type, dimension, and stride are descriptor metadata. The
    # element descriptor is budgeted by the binary codec but is not a generic
    # value/physical child.
    def self.qbit(type : QBitType) : BinaryDataType
      new(TAG_QBIT, nil, [] of BinaryDataType, [] of String, nil, qbit_type: type)
    end

    def self.json(
      max_dynamic_paths : Int = BinaryJsonType::DEFAULT_MAX_DYNAMIC_PATHS,
      max_dynamic_types : Int = BinaryJsonType::DEFAULT_MAX_DYNAMIC_TYPES,
      typed_paths : Hash(String, BinaryDataType) = {} of String => BinaryDataType,
    ) : BinaryDataType
      descriptor = BinaryJsonType.new(max_dynamic_paths, max_dynamic_types, typed_paths)
      new(TAG_JSON, nil, [] of BinaryDataType, [] of String, nil, json_type: descriptor)
    end

    def self.array(child : BinaryDataType) : BinaryDataType
      reject_aggregate_count_child!(child)
      reject_qbit_child!(child)
      new(TAG_ARRAY, nil, [child] of BinaryDataType, [] of String, nil)
    end

    # Nested is nominally distinct from Array(Tuple(...)). Its one implicit
    # named-Tuple child preserves shared row alignment across sibling fields.
    def self.nested(children : Array(BinaryDataType), names : Array(String)) : BinaryDataType
      if children.empty?
        raise ArgumentError.new("Nested requires at least one field")
      end
      tuple_type = tuple(children, names)
      new(TAG_NESTED, nil, [tuple_type] of BinaryDataType, [] of String, nil)
    end

    def self.simple_aggregate(
      function : BinarySimpleAggregateType::Function,
      storage_type : BinaryDataType = primitive("UInt64"),
    ) : BinaryDataType
      reject_aggregate_count_child!(storage_type)
      reject_qbit_child!(storage_type)
      reject_json_child!(storage_type)
      storage_type_name = case storage_type.tag
                          when TAG_UINT8    then "UInt8"
                          when TAG_UINT16   then "UInt16"
                          when TAG_UINT32   then "UInt32"
                          when TAG_UINT64   then "UInt64"
                          when TAG_UINT128  then "UInt128"
                          when TAG_UINT256  then "UInt256"
                          when TAG_INT8     then "Int8"
                          when TAG_INT16    then "Int16"
                          when TAG_INT32    then "Int32"
                          when TAG_INT64    then "Int64"
                          when TAG_INT128   then "Int128"
                          when TAG_INT256   then "Int256"
                          when TAG_FLOAT32  then "Float32"
                          when TAG_FLOAT64  then "Float64"
                          when TAG_BFLOAT16 then "BFloat16"
                          when TAG_STRING   then "String"
                          when TAG_DATE     then "Date"
                          when TAG_DATE32   then "Date32"
                          when TAG_TIME     then "Time"
                          when TAG_DATETIME, TAG_DATETIME_ZONE,
                               TAG_DATETIME64, TAG_DATETIME64_ZONE,
                               TAG_TIME64
                            storage_type.temporal_type.not_nil!.type_name
                          when TAG_FIXED_STRING
                            width = storage_type.fixed_size.not_nil!
                            unless width <= BinarySimpleAggregateType::MAX_FIXED_STRING_WIDTH
                              raise ArgumentError.new("SimpleAggregateFunction FixedString width exceeds the admitted library limit")
                            end
                            "FixedString(#{width})"
                          when TAG_DECIMAL32, TAG_DECIMAL64, TAG_DECIMAL128, TAG_DECIMAL256
                            binary_decimal = storage_type.decimal_type.not_nil!
                            decimal = DecimalType.new(binary_decimal.precision, binary_decimal.scale)
                            canonical_width_bits = decimal.storage_width * 8
                            unless binary_decimal.width_bits == canonical_width_bits
                              raise ArgumentError.new("SimpleAggregateFunction Decimal width does not match its canonical precision width")
                            end
                            decimal.type_name
                          else
                            # Reject from the exact tag before asking an
                            # arbitrary child to render a recursive SQL name.
                            raise ArgumentError.new("SimpleAggregateFunction storage type is outside the admitted profile")
                          end
      descriptor = BinarySimpleAggregateType.new(function, storage_type_name)
      new(TAG_SIMPLE_AGGREGATE, nil, [storage_type] of BinaryDataType, [] of String, nil, nil, nil, nil, nil, nil, descriptor)
    end

    # A top-level count state is nominally distinct from UInt64 despite using
    # UInt64 as its owned in-memory carrier. The optional argument is nominal
    # descriptor metadata and does not become a generic value child.
    def self.aggregate_count(argument : BinaryDataType? = nil) : BinaryDataType
      if argument && argument.contains_qbit?
        raise ArgumentError.new("AggregateFunction(count) arguments cannot contain QBit")
      end
      if argument && argument.contains_json?
        raise ArgumentError.new("JSON is not admitted in AggregateFunction(count) arguments")
      end
      nominal = BinaryAggregateCountType.new(argument)
      new(TAG_AGGREGATE_COUNT, nil, [] of BinaryDataType, [] of String, nil, aggregate_count_type: nominal)
    end

    def self.dynamic(max_types : Int = 32) : BinaryDataType
      unless 0 <= max_types <= 254
        raise ArgumentError.new("Dynamic max_types must be between 0 and 254")
      end
      new(TAG_DYNAMIC, nil, [] of BinaryDataType, [] of String, nil, nil, nil, nil, max_types.to_u8)
    end

    def self.nullable(child : BinaryDataType) : BinaryDataType
      reject_aggregate_count_child!(child)
      if child.contains_qbit? && child.tag != TAG_QBIT
        raise ArgumentError.new("Nullable can contain QBit only as its direct scalar child")
      end
      if child.tag == TAG_ARRAY || child.tag == TAG_NESTED || child.tag == TAG_MAP || child.tag == TAG_NULLABLE || child.tag == TAG_LOW_CARDINALITY || child.tag == TAG_VARIANT || child.tag == TAG_DYNAMIC
        raise ArgumentError.new("Nullable cannot directly contain Array, Nested, Map, Nullable, LowCardinality, Variant, or Dynamic")
      end
      new(TAG_NULLABLE, nil, [child] of BinaryDataType, [] of String, nil)
    end

    # Normal Variant construction canonicalizes by bounded SQL display name;
    # binary decode uses the same helper with the enclosing operation's budget.
    def self.variant(arms : Array(BinaryDataType), limits : BinaryCodecLimits = BinaryCodecLimits.default) : BinaryDataType
      arms.each do |arm|
        reject_aggregate_count_child!(arm)
      end
      budget = BinaryCodecBudget.new(limits, true)
      canonical = BinaryVariantRoster.normalize(
        arms,
        budget,
        1,
        account_variant_node: true,
        account_roster_edges: true,
        strict_wire: false
      )
      new(TAG_VARIANT, nil, canonical, [] of String, nil)
    end

    # Internal delayed-materialization path for Object JSON declarations.
    # ObjectRecursiveDeclarationText has already validated the complete
    # borrowed tree, including strict arm order and the direct-arm policy,
    # against one aggregate budget before constructing any descriptor. Do not
    # re-normalize here: nested Variant normalization would recursively render
    # the same arm names again with fresh per-Variant budgets.
    protected def self.variant_from_canonical_object_declaration(arms : Array(BinaryDataType)) : BinaryDataType
      unless 1 <= arms.size <= BinaryVariantRoster::MAX_ARMS
        raise ArgumentError.new("canonical Object Variant roster is outside the admitted size")
      end
      arms.each do |arm|
        reject_aggregate_count_child!(arm)
        reject_qbit_child!(arm)
        reject_json_child!(arm)
        if arm.tag == TAG_NOTHING || arm.tag == TAG_NULLABLE || arm.tag == TAG_VARIANT || arm.tag == TAG_DYNAMIC
          raise ArgumentError.new("canonical Object Variant roster has a forbidden direct arm")
        end
        if arm.tag == TAG_LOW_CARDINALITY && arm.child_count == 1 && arm.child_at(0).tag == TAG_NULLABLE
          raise ArgumentError.new("canonical Object Variant roster has a forbidden LowCardinality(Nullable) arm")
        end
      end
      new(TAG_VARIANT, nil, arms, [] of String, nil)
    end

    # Internal descriptor constructor for a fully parsed binary roster. It
    # preserves the decoder's aggregate traversal/name budget and applies the
    # local strict-canonical wire profile after the complete roster is read.
    def self.variant_from_wire(
      arms : Array(BinaryDataType),
      context : BinaryCodecContext,
      variant_depth : Int,
    ) : BinaryDataType
      arms.each do |arm|
        if arm.contains_qbit?
          context.corrupt!("QBit is not admitted in a Variant arm")
        end
        if arm.contains_aggregate_count?
          context.corrupt!("AggregateFunction(count) cannot be nested in a Variant arm")
        end
      end
      canonical = begin
        BinaryVariantRoster.normalize(
          arms,
          context.budget,
          variant_depth,
          account_variant_node: false,
          account_roster_edges: false,
          strict_wire: true
        )
      rescue ex : ArgumentError
        context.corrupt!("invalid Variant arm roster: #{ex.message}")
      end
      new(TAG_VARIANT, nil, canonical, [] of String, nil)
    end

    def self.low_cardinality(child : BinaryDataType) : BinaryDataType
      reject_aggregate_count_child!(child)
      reject_qbit_child!(child)
      reject_json_child!(child)
      unless BinaryLowCardinalityTypePolicy.admitted_child?(child)
        raise ArgumentError.new("LowCardinality child type is not admitted by ClickHouse")
      end
      new(TAG_LOW_CARDINALITY, nil, [child] of BinaryDataType, [] of String, nil)
    end

    def self.tuple(children : Array(BinaryDataType), names : Array(String)? = nil) : BinaryDataType
      raise ArgumentError.new("Tuple arity exceeds ClickHouse's supported maximum") if children.size > MAX_TUPLE_ARITY
      children.each do |child|
        reject_aggregate_count_child!(child)
        reject_qbit_child!(child)
      end

      if names
        raise ArgumentError.new("Tuple field-name count does not match arity") unless names.size == children.size
        seen = Set(String).new
        names.each do |name|
          if name.bytesize == 0
            raise ArgumentError.new("Tuple field names cannot be empty")
          end
          if name == "null"
            raise ArgumentError.new("Tuple field name 'null' is reserved")
          end
          if seen.includes?(name)
            raise ArgumentError.new("Tuple field names must be unique")
          end
          seen.add(name)
        end
        new(TAG_NAMED_TUPLE, nil, children, names, nil)
      else
        new(TAG_UNNAMED_TUPLE, nil, children, [] of String, nil)
      end
    end

    def self.map(key : BinaryDataType, value : BinaryDataType) : BinaryDataType
      reject_aggregate_count_child!(key)
      reject_aggregate_count_child!(value)
      reject_qbit_child!(key)
      reject_qbit_child!(value)
      if BinaryLowCardinalityTypePolicy.nullable_map_key?(key)
        raise ArgumentError.new("Map key type cannot be Nullable or LowCardinality(Nullable(...))")
      end
      new(TAG_MAP, nil, [key, value] of BinaryDataType, [] of String, nil)
    end

    def children : Array(BinaryDataType)
      @children.dup
    end

    def child_count : Int32
      @children.size
    end

    def child_at(index : Int) : BinaryDataType
      @children[index]
    end

    def field_names : Array(String)
      @field_names.map { |name| String.new(name.to_slice) }
    end

    def field_name_at(index : Int) : String
      String.new(@field_names[index].to_slice)
    end

    # Bounded structural names may render a Nested root using its implicit
    # Tuple's field names without exposing mutable internal name storage.
    def field_name_display_at(index : Int) : String
      format_field_name(@field_names[index])
    end

    def field_name_byte_size(index : Int) : Int32
      @field_names[index].bytesize
    end

    def field_name_byte_at(index : Int, byte_index : Int) : UInt8
      @field_names[index].to_slice[byte_index]
    end

    def temporal_type : BinaryTemporalType?
      @temporal_type
    end

    def decimal_type : BinaryDecimalType?
      @decimal_type
    end

    def enum_definition : BinaryEnumDefinition?
      @enum_definition
    end

    def interval_type : BinaryIntervalType?
      @interval_type
    end

    def simple_aggregate_type : BinarySimpleAggregateType?
      @simple_aggregate_type
    end

    def aggregate_count_type : BinaryAggregateCountType?
      @aggregate_count_type
    end

    def qbit_type : QBitType?
      @qbit_type
    end

    def json_type : BinaryJsonType?
      @json_type
    end

    # The binary DataType grammar embeds QBit's element type as metadata. Keep
    # that descriptor separate from #children so generic value/physical
    # visitors do not mistake it for a stored value child.
    def qbit_element_descriptor : BinaryDataType
      descriptor = @qbit_type || raise ArgumentError.new("DataType is not QBit")
      BinaryDataType.primitive(descriptor.element_type)
    end

    # Return the exact immutable descriptor held by Count's nominal metadata.
    # It remains separate from the generic physical child list.
    def aggregate_count_argument_type : BinaryDataType?
      descriptor = @aggregate_count_type || return nil
      descriptor.argument_type
    end

    # Enum declarations are metadata edges/nodes in the binary budget, not
    # recursive DataType children and therefore do not increase tree depth.
    def metadata_entry_count : Int32
      @enum_definition.try(&.size) || 0
    end

    def named_tuple? : Bool
      @tag == TAG_NAMED_TUPLE
    end

    def nullable? : Bool
      @tag == TAG_NULLABLE
    end

    def name : String
      case @tag
      when TAG_FIXED_STRING
        "FixedString(#{@fixed_size})"
      when TAG_DYNAMIC
        max_types = @dynamic_max_types.not_nil!
        if max_types == 32_u8
          "Dynamic"
        else
          String.build do |io|
            io << "Dynamic(max_types=" << max_types << ')'
          end
        end
      when TAG_DATETIME, TAG_DATETIME_ZONE, TAG_DATETIME64, TAG_DATETIME64_ZONE, TAG_TIME64
        @temporal_type.not_nil!.type_name
      when TAG_INTERVAL
        @interval_type.not_nil!.type_name
      when TAG_DECIMAL32, TAG_DECIMAL64, TAG_DECIMAL128, TAG_DECIMAL256
        @decimal_type.not_nil!.type_name
      when TAG_ENUM8
        @enum_definition.not_nil!.type_name
      when TAG_ENUM16
        @enum_definition.not_nil!.type_name
      when TAG_ARRAY
        "Array(#{@children[0].name})"
      when TAG_NESTED
        tuple_type = @children[0]
        String.build do |io|
          io << "Nested("
          tuple_type.child_count.times do |index|
            io << ", " unless index == 0
            io << tuple_type.field_name_display_at(index) << ' ' << tuple_type.child_at(index).name
          end
          io << ')'
        end
      when TAG_NULLABLE
        "Nullable(#{@children[0].name})"
      when TAG_LOW_CARDINALITY
        "LowCardinality(#{@children[0].name})"
      when TAG_SIMPLE_AGGREGATE
        "SimpleAggregateFunction(#{@simple_aggregate_type.not_nil!.function_name}, #{@children[0].name})"
      when TAG_AGGREGATE_COUNT
        @aggregate_count_type.not_nil!.type_name
      when TAG_QBIT
        @qbit_type.not_nil!.type_name
      when TAG_JSON
        @json_type.not_nil!.type_name
      when TAG_MAP
        "Map(#{@children[0].name}, #{@children[1].name})"
      when TAG_VARIANT
        String.build do |io|
          io << "Variant("
          @children.each_with_index do |child, index|
            io << ", " unless index == 0
            io << child.name
          end
          io << ')'
        end
      when TAG_UNNAMED_TUPLE
        String.build do |io|
          io << "Tuple("
          @children.each_with_index do |child, index|
            io << ", " unless index == 0
            io << child.name
          end
          io << ')'
        end
      when TAG_NAMED_TUPLE
        String.build do |io|
          io << "Tuple("
          @children.each_with_index do |child, index|
            io << ", " unless index == 0
            io << format_field_name(@field_names[index]) << ' ' << child.name
          end
          io << ')'
        end
      else
        String.new(@primitive_name.not_nil!.to_slice)
      end
    end

    def type_name : String
      name
    end

    def fixed_width : Int32?
      case @tag
      when TAG_UINT8, TAG_INT8, TAG_BOOL
        1
      when TAG_UINT16, TAG_INT16, TAG_BFLOAT16
        2
      when TAG_UINT32, TAG_INT32, TAG_FLOAT32
        4
      when TAG_UINT64, TAG_INT64, TAG_FLOAT64
        8
      when TAG_UINT128, TAG_INT128
        16
      when TAG_UINT256, TAG_INT256
        32
      when TAG_FIXED_STRING
        @fixed_size
      when TAG_ENUM8
        1
      when TAG_DATE, TAG_ENUM16
        2
      when TAG_DATE32, TAG_DATETIME, TAG_DATETIME_ZONE, TAG_IPV4, TAG_TIME
        4
      when TAG_DATETIME64, TAG_DATETIME64_ZONE, TAG_TIME64
        8
      when TAG_INTERVAL
        @interval_type.not_nil!.fixed_width
      when TAG_DECIMAL64
        8
      when TAG_UUID, TAG_IPV6
        16
      when TAG_DECIMAL32
        4
      when TAG_DECIMAL128
        16
      when TAG_DECIMAL256
        32
      else
        nil
      end
    end

    def ==(other : BinaryDataType) : Bool
      return false unless @tag == other.tag && @fixed_size == other.fixed_size
      return false unless @primitive_name == other.@primitive_name
      return false unless @temporal_type == other.@temporal_type
      return false unless @decimal_type == other.@decimal_type
      return false unless @enum_definition == other.@enum_definition
      return false unless @interval_type == other.@interval_type
      return false unless @simple_aggregate_type == other.@simple_aggregate_type
      return false unless @aggregate_count_type == other.@aggregate_count_type
      return false unless @qbit_type == other.@qbit_type
      return false unless @json_type == other.@json_type
      return false unless @dynamic_max_types == other.@dynamic_max_types
      return false unless @field_names == other.@field_names
      return false unless @children.size == other.@children.size

      @children.each_with_index do |child, index|
        return false unless child == other.@children[index]
      end
      true
    end

    def_hash @tag, @fixed_size, @primitive_name, @temporal_type, @decimal_type, @enum_definition, @dynamic_max_types, @interval_type, @simple_aggregate_type, @aggregate_count_type, @qbit_type, @json_type, @children, @field_names

    private def self.reject_aggregate_count_child!(type : BinaryDataType) : Nil
      if type.contains_aggregate_count?
        raise ArgumentError.new("AggregateFunction(count) is admitted only as a top-level scalar type")
      end
    end

    private def self.reject_qbit_child!(type : BinaryDataType) : Nil
      if type.contains_qbit?
        raise ArgumentError.new("QBit is admitted only as a root scalar or direct Nullable child")
      end
    end

    private def self.reject_json_child!(type : BinaryDataType) : Nil
      if type.contains_json?
        raise ArgumentError.new("JSON is not admitted as a child of this DataType owner")
      end
    end

    private def format_field_name(value : String) : String
      bytes = value.to_slice
      bare = bytes.size > 0 && identifier_start?(bytes[0])
      if bare
        bytes.each_with_index do |byte, index|
          unless index == 0 ? identifier_start?(byte) : identifier_continue?(byte)
            bare = false
            break
          end
        end
      end
      if bare
        lowered = value.downcase
        bare = !{"inf", "infinity", "nan", "true", "false", "null", "distinct", "all", "some", "table", "select", "cube", "rollup", "recursive", "from", "top", "values"}.includes?(lowered)
      end
      return String.new(bytes) if bare

      String.build do |io|
        io << '`'
        bytes.each do |byte|
          case byte
          when 0x5c_u8
            io << "\\\\"
          when 0x60_u8
            io << "\\`"
          when 0x0a_u8
            io << "\\n"
          when 0x0d_u8
            io << "\\r"
          when 0x09_u8
            io << "\\t"
          when 0x08_u8
            io << "\\b"
          when 0x0c_u8
            io << "\\f"
          when 0x00_u8
            io << "\\0"
          else
            io.write(Bytes[byte])
          end
        end
        io << '`'
      end
    end

    private def identifier_start?(byte : UInt8) : Bool
      (byte >= 0x41_u8 && byte <= 0x5a_u8) || (byte >= 0x61_u8 && byte <= 0x7a_u8) || byte == 0x5f_u8
    end

    private def identifier_continue?(byte : UInt8) : Bool
      identifier_start?(byte) || (byte >= 0x30_u8 && byte <= 0x39_u8)
    end
  end
end
