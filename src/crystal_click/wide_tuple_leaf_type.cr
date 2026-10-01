module CrystalClick
  # Exact immutable schema owner for one admitted scalar Tuple leaf, optionally
  # wrapped once in Nullable. The physical codec remains owned by the existing
  # scalar-family descriptors.
  class WideTupleLeafType
    STRING_SLOT_ACCOUNTING_BYTES = 16_u64

    @base_type_name : String
    @nullable : Bool
    @parameterized_type : WideTupleParameterizedType?
    @datetime_type : DateTimeColumnType?

    def self.parse(type_name : String) : WideTupleLeafType?
      WideTupleSchemaParser.parse_leaf_type(type_name)
    end

    def initialize(
      base_type_name : String,
      nullable : Bool = false,
      parameterized_type : WideTupleParameterizedType? = nil,
      datetime_type : DateTimeColumnType? = nil,
    )
      raise ArgumentError.new("Tuple leaf cannot have two exact descriptors") if parameterized_type && datetime_type
      if parameterized_type
        raise ArgumentError.new("Tuple leaf name differs from exact parameterized descriptor") unless parameterized_type.type_name == base_type_name
      elsif datetime_type
        unless datetime_type.shape == DateTimeColumnType::Shape::Scalar && datetime_type.leaf_type_name == base_type_name
          raise ArgumentError.new("Tuple leaf name differs from exact DateTime descriptor")
        end
      elsif !admitted_bare_type?(base_type_name)
        raise ArgumentError.new("Tuple leaf type is not an admitted scalar")
      end

      @base_type_name = String.new(base_type_name.to_slice)
      @nullable = nullable
      @parameterized_type = parameterized_type
      @datetime_type = datetime_type
    end

    def base_type_name : String
      String.new(@base_type_name.to_slice)
    end

    def type_name : String
      if @nullable
        String.build do |io|
          io << "Nullable("
          io << @base_type_name
          io << ')'
        end
      else
        String.new(@base_type_name.to_slice)
      end
    end

    def nullable? : Bool
      @nullable
    end

    def parameterized_type : WideTupleParameterizedType?
      @parameterized_type
    end

    def datetime_type : DateTimeColumnType?
      @datetime_type
    end

    # Fixed-size physical payload width. String has a separate UInt64 size
    # stream, so it intentionally reports nil.
    def raw_width : Int32?
      return nil if @base_type_name == "String"
      if parameterized_type = @parameterized_type
        case parameterized_type
        when WideTupleFixedStringType then parameterized_type.width
        when WideTupleEnumType        then parameterized_type.width
        when WideTupleDecimalType     then parameterized_type.storage_width
        end
      elsif datetime_type = @datetime_type
        datetime_type.raw_width
      elsif @base_type_name == "Bool"
        1
      else
        WideTupleIdentifierType.width(@base_type_name) ||
          WideTupleTemporalType.width(@base_type_name) ||
          WideTupleNumericType.width(@base_type_name)
      end
    end

    # Charges this retained owner and its private base-name String. Referenced
    # family descriptors are charged separately by WideTupleTypePlan.
    def logical_charge : UInt64
      instance_sizeof(WideTupleLeafType).to_u64 +
        instance_sizeof(String).to_u64 + @base_type_name.bytesize.to_u64 + 1_u64
    end

    # Physical value-slot size shared by Tuple and Map-key result accounting.
    # The Nullable bitmap byte is charged separately by the containing plan.
    def owned_slot_bytes : UInt64
      base_name = @base_type_name
      if parameterized_type = @parameterized_type
        if @nullable
          case parameterized_type
          when WideTupleEnumType
            return parameterized_type.width.to_u64
          when WideTupleDecimalType
            return parameterized_type.storage_width.to_u64
          end
        end
      end
      if @nullable && base_name == "Bool"
        return sizeof(UInt8).to_u64
      end
      if parameterized_type = @parameterized_type
        case parameterized_type
        when WideTupleFixedStringType
          sizeof(FixedStringValue).to_u64
        when WideTupleEnumType
          parameterized_type.definition.kind == :enum8 ? sizeof(Enum8Value).to_u64 : sizeof(Enum16Value).to_u64
        when WideTupleDecimalType
          case parameterized_type.storage_width
          when  4 then sizeof(Decimal32Value).to_u64
          when  8 then sizeof(Decimal64Value).to_u64
          when 16 then sizeof(Decimal128Value).to_u64
          else         sizeof(Decimal256TupleValue).to_u64
          end
        else
          raise UnsupportedFormatError.new("unsupported parameterized Tuple descriptor")
        end
      elsif base_name == "String"
        STRING_SLOT_ACCOUNTING_BYTES
      elsif base_name == "Bool"
        1_u64
      elsif datetime_type = @datetime_type
        if datetime_type.family == DateTimeColumnType::Family::DateTime
          sizeof(DateTimeValue).to_u64
        else
          sizeof(DateTime64Value).to_u64
        end
      elsif temporal_width = WideTupleTemporalType.owned_width(base_name)
        temporal_width.to_u64
      else
        (WideTupleIdentifierType.width(base_name) || WideTupleNumericType.width(base_name).not_nil!).to_u64
      end
    end

    def with_nullable(nullable : Bool = true) : WideTupleLeafType
      WideTupleLeafType.new(@base_type_name, nullable, @parameterized_type, @datetime_type)
    end

    def ==(other : self) : Bool
      @base_type_name == other.base_type_name &&
        @nullable == other.nullable? &&
        descriptor_identity == other.descriptor_identity
    end

    def hash(hasher)
      hasher = @base_type_name.hash(hasher)
      hasher = @nullable.hash(hasher)
      descriptor_identity.hash(hasher)
    end

    protected def descriptor_identity : String
      # Canonical leaf spelling captures the complete immutable descriptor,
      # including timezone aliases, Enum definitions, and Decimal scale.
      if parameterized_type = @parameterized_type
        parameterized_type.type_name
      elsif datetime_type = @datetime_type
        datetime_type.leaf_type_name
      else
        String.new(@base_type_name.to_slice)
      end
    end

    private def admitted_bare_type?(type_name : String) : Bool
      return true if type_name == "String" || type_name == "Bool"
      return true if WideTupleIdentifierType.width(type_name)
      return true if WideTupleTemporalType.width(type_name)
      !!WideTupleNumericType.width(type_name)
    end
  end
end
