require "set"

module CrystalClick
  # Immutable, nominal ClickHouse binary data-type descriptor for the bounded
  # W117-W119 descriptor/value kernel. A familiar display name is not enough
  # to admit an otherwise unsupported type or imply broader part support.
  class BinaryDataType
    TAG_NOTHING          =     0x00_u8
    TAG_UINT8            =     0x01_u8
    TAG_UINT16           =     0x02_u8
    TAG_UINT32           =     0x03_u8
    TAG_UINT64           =     0x04_u8
    TAG_UINT128          =     0x05_u8
    TAG_UINT256          =     0x06_u8
    TAG_INT8             =     0x07_u8
    TAG_INT16            =     0x08_u8
    TAG_INT32            =     0x09_u8
    TAG_INT64            =     0x0a_u8
    TAG_INT128           =     0x0b_u8
    TAG_INT256           =     0x0c_u8
    TAG_FLOAT32          =     0x0d_u8
    TAG_FLOAT64          =     0x0e_u8
    TAG_DATE             =     0x0f_u8
    TAG_DATE32           =     0x10_u8
    TAG_DATETIME         =     0x11_u8
    TAG_DATETIME_ZONE    =     0x12_u8
    TAG_DATETIME64       =     0x13_u8
    TAG_DATETIME64_ZONE  =     0x14_u8
    TAG_STRING           =     0x15_u8
    TAG_FIXED_STRING     =     0x16_u8
    TAG_ENUM8            =     0x17_u8
    TAG_ENUM16           =     0x18_u8
    TAG_DECIMAL32        =     0x19_u8
    TAG_DECIMAL64        =     0x1a_u8
    TAG_DECIMAL128       =     0x1b_u8
    TAG_DECIMAL256       =     0x1c_u8
    TAG_UUID             =     0x1d_u8
    TAG_ARRAY            =     0x1e_u8
    TAG_UNNAMED_TUPLE    =     0x1f_u8
    TAG_NAMED_TUPLE      =     0x20_u8
    TAG_INTERVAL         =     0x22_u8
    TAG_LOW_CARDINALITY  =     0x26_u8
    TAG_NULLABLE         =     0x23_u8
    TAG_MAP              =     0x27_u8
    TAG_IPV4             =     0x28_u8
    TAG_IPV6             =     0x29_u8
    TAG_VARIANT          =     0x2a_u8
    TAG_DYNAMIC          =     0x2b_u8
    TAG_BOOL             =     0x2d_u8
    TAG_SIMPLE_AGGREGATE =     0x2e_u8
    TAG_BFLOAT16         =     0x31_u8
    TAG_TIME             =     0x32_u8
    TAG_TIME64           =     0x34_u8
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
    getter dynamic_max_types : UInt8?

    @primitive_name : String?
    @children : Array(BinaryDataType)
    @field_names : Array(String)
    @temporal_type : BinaryTemporalType?
    @decimal_type : BinaryDecimalType?
    @enum_definition : BinaryEnumDefinition?
    @interval_type : BinaryIntervalType?
    @simple_aggregate_type : BinarySimpleAggregateType?

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
    )
      @children = children.dup
      @field_names = field_names.map { |name| String.new(name.to_slice) }
      @contains_low_cardinality = @tag == TAG_LOW_CARDINALITY || @children.any?(&.contains_low_cardinality?)
      @contains_variant = @tag == TAG_VARIANT || @children.any?(&.contains_variant?)
      @contains_dynamic = @tag == TAG_DYNAMIC || @children.any?(&.contains_dynamic?)
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

    def self.array(child : BinaryDataType) : BinaryDataType
      new(TAG_ARRAY, nil, [child] of BinaryDataType, [] of String, nil)
    end

    def self.simple_aggregate(
      function : BinarySimpleAggregateType::Function,
      storage_type : BinaryDataType = primitive("UInt64"),
    ) : BinaryDataType
      unless storage_type.tag == TAG_UINT64
        raise ArgumentError.new("SimpleAggregateFunction storage type is outside the admitted UInt64 profile")
      end
      descriptor = BinarySimpleAggregateType.new(function)
      new(TAG_SIMPLE_AGGREGATE, nil, [storage_type] of BinaryDataType, [] of String, nil, nil, nil, nil, nil, nil, descriptor)
    end

    def self.dynamic(max_types : Int = 32) : BinaryDataType
      unless 0 <= max_types <= 254
        raise ArgumentError.new("Dynamic max_types must be between 0 and 254")
      end
      new(TAG_DYNAMIC, nil, [] of BinaryDataType, [] of String, nil, nil, nil, nil, max_types.to_u8)
    end

    def self.nullable(child : BinaryDataType) : BinaryDataType
      if child.tag == TAG_ARRAY || child.tag == TAG_MAP || child.tag == TAG_NULLABLE || child.tag == TAG_LOW_CARDINALITY || child.tag == TAG_VARIANT || child.tag == TAG_DYNAMIC
        raise ArgumentError.new("Nullable cannot directly contain Array, Map, Nullable, LowCardinality, Variant, or Dynamic")
      end
      new(TAG_NULLABLE, nil, [child] of BinaryDataType, [] of String, nil)
    end

    # Normal Variant construction canonicalizes by bounded SQL display name;
    # binary decode uses the same helper with the enclosing operation's budget.
    def self.variant(arms : Array(BinaryDataType), limits : BinaryCodecLimits = BinaryCodecLimits.default) : BinaryDataType
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
      unless BinaryLowCardinalityTypePolicy.admitted_child?(child)
        raise ArgumentError.new("LowCardinality child type is not admitted by ClickHouse")
      end
      new(TAG_LOW_CARDINALITY, nil, [child] of BinaryDataType, [] of String, nil)
    end

    def self.tuple(children : Array(BinaryDataType), names : Array(String)? = nil) : BinaryDataType
      raise ArgumentError.new("Tuple arity exceeds ClickHouse's supported maximum") if children.size > MAX_TUPLE_ARITY

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
      when TAG_NULLABLE
        "Nullable(#{@children[0].name})"
      when TAG_LOW_CARDINALITY
        "LowCardinality(#{@children[0].name})"
      when TAG_SIMPLE_AGGREGATE
        "SimpleAggregateFunction(#{@simple_aggregate_type.not_nil!.function_name}, #{@children[0].name})"
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
      return false unless @dynamic_max_types == other.@dynamic_max_types
      return false unless @field_names == other.@field_names
      return false unless @children.size == other.@children.size

      @children.each_with_index do |child, index|
        return false unless child == other.@children[index]
      end
      true
    end

    def_hash @tag, @fixed_size, @primitive_name, @temporal_type, @decimal_type, @enum_definition, @dynamic_max_types, @interval_type, @simple_aggregate_type, @children, @field_names

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
