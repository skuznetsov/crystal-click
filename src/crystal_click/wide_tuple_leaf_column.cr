module CrystalClick
  # One owned named leaf buffer. Nullable leaves retain physical bytes plus a
  # separate immutable mask; logical row access applies the mask at the API
  # boundary without discarding hidden payload.
  class WideTupleLeafColumn
    alias Value = WideTupleNumericType::Value | WideTupleIdentifierType::Value |
                  WideTupleTemporalType::Value | FixedStringValue | Enum8Value | Enum16Value |
                  Decimal32Value | Decimal64Value | Decimal128Value | Decimal256TupleValue |
                  Bool | String | Nil
    alias Buffer = WideTupleNumericType::Buffer | WideTupleIdentifierType::Buffer |
                   WideTupleTemporalType::Buffer | WideTupleFixedStringType::Buffer |
                   WideTupleEnumType::Buffer | WideTupleDecimalType::Buffer |
                   Array(Bool) | Array(String)

    @name : String
    @values : Buffer
    @temporal_type_name : String?
    @parameterized_type : WideTupleParameterizedType?
    @datetime_type : DateTimeColumnType?
    @leaf_type : WideTupleLeafType
    @null_map : ScalarNullMap?

    # Preserve the original constructor overloads and their union dispatch.
    def initialize(name : String, values : Array(UInt64))
      @name = String.new(name.to_slice)
      @values = values.dup
      @temporal_type_name = nil
      @parameterized_type = nil
      @datetime_type = nil
      @leaf_type = WideTupleLeafType.new("UInt64")
      @null_map = nil
    end

    def initialize(name : String, values : Array(String))
      @name = String.new(name.to_slice)
      @values = values.map { |value| String.new(value.to_slice) }
      @temporal_type_name = nil
      @parameterized_type = nil
      @datetime_type = nil
      @leaf_type = WideTupleLeafType.new("String")
      @null_map = nil
    end

    # A closed legacy-buffer constructor remains useful for internal immutable
    # copies, but descriptor-bearing buffers must use the exact-owner overload.
    def initialize(name : String, values : Buffer)
      @name = String.new(name.to_slice)
      reject_descriptor_buffer!(values)
      reject_temporal_buffer!(values)
      @values = copy_values(values)
      @temporal_type_name = nil
      @parameterized_type = nil
      @datetime_type = nil
      @leaf_type = inferred_leaf_type(values)
      @null_map = nil
    end

    # Temporal buffers require explicit semantic metadata, including when
    # empty, because several wrappers share raw carrier widths.
    def initialize(name : String, exact_type : String, values : WideTupleTemporalType::Buffer)
      @name = String.new(name.to_slice)
      @parameterized_type = nil
      if datetime_type = DateTimeColumnType.parse_leaf(exact_type)
        validate_datetime_buffer!(datetime_type, values)
        @temporal_type_name = nil
        @datetime_type = datetime_type
      else
        WideTupleTemporalType.validate_buffer!(exact_type, values)
        @temporal_type_name = String.new(exact_type.to_slice)
        @datetime_type = nil
      end
      @values = copy_values(values)
      @leaf_type = WideTupleLeafType.parse(exact_type) ||
                   raise(ArgumentError.new("temporal Tuple type is not an admitted scalar leaf"))
      @null_map = nil
    end

    # DateTime column metadata is shared by identity across schema snapshots
    # and Tuple leaves; it is not reconstructed for each row or copy.
    def initialize(name : String, exact_type : DateTimeColumnType, values : WideTupleTemporalType::Buffer)
      raise ArgumentError.new("DateTime Tuple leaves require a scalar descriptor") unless exact_type.shape == DateTimeColumnType::Shape::Scalar
      validate_datetime_buffer!(exact_type, values)
      @name = String.new(name.to_slice)
      @values = copy_values(values)
      @temporal_type_name = nil
      @parameterized_type = nil
      @datetime_type = exact_type
      @leaf_type = WideTupleLeafType.new(exact_type.leaf_type_name, false, nil, exact_type)
      @null_map = nil
    end

    # W101 buffers retain exact declaration metadata even when they contain no
    # rows. Enum values are rebound to this one shared immutable definition.
    def initialize(name : String, exact_type : WideTupleParameterizedType, values : Buffer)
      @name = String.new(name.to_slice)
      @temporal_type_name = nil
      @parameterized_type = exact_type
      @datetime_type = nil
      @values = copy_parameterized_values(exact_type, values)
      @leaf_type = WideTupleLeafType.new(exact_type.type_name, false, exact_type)
      @null_map = nil
    end

    # Generic construction is closed to String, Bool, and the exact admitted
    # native/wrapper numeric identities. Descriptor-bearing values require an
    # exact owner; unsupported element types fail closed.
    def initialize(name : String, values : Array(T)) forall T
      @name = String.new(name.to_slice)
      @values = copy_allowed_array(values)
      @temporal_type_name = nil
      @parameterized_type = nil
      @datetime_type = nil
      @leaf_type = inferred_leaf_type(@values)
      @null_map = nil
    end

    # Descriptor-backed construction is required for Nullable leaves and also
    # provides a lossless path for masked Enum/Decimal physical carriers.
    def initialize(
      name : String,
      leaf_type : WideTupleLeafType,
      physical_values : Buffer,
      null_map : ScalarNullMap?,
    )
      validate_nullable_storage!(leaf_type, physical_values, null_map)
      @name = String.new(name.to_slice)
      @leaf_type = leaf_type
      @values = copy_nullable_physical_values(leaf_type, physical_values)
      @null_map = null_map
      @temporal_type_name = nil
      @parameterized_type = leaf_type.parameterized_type
      @datetime_type = leaf_type.datetime_type
    end

    def name : String
      String.new(@name.to_slice)
    end

    def type_name : String
      @leaf_type.type_name
    end

    def leaf_type : WideTupleLeafType
      @leaf_type
    end

    def null_map : ScalarNullMap?
      # ScalarNullMap is immutable and owns its bytes, so sharing this owner is
      # constant-time and does not copy O(rows) during budget preflight.
      @null_map
    end

    def parameterized_type : WideTupleParameterizedType?
      @parameterized_type
    end

    def datetime_type : DateTimeColumnType?
      @datetime_type
    end

    def size : Int32
      @values.size
    end

    # An owned snapshot of the complete leaf buffer. String and outer Array
    # storage are copied; nominal immutable wrappers can be safely shared.
    def values : Buffer | Array(Value)
      if @leaf_type.nullable?
        Array(Value).new(@values.size) { |index| value_at(index) }
      else
        copy_values(@values)
      end
    end

    # Detached physical storage for codecs and writers. This deliberately
    # includes bytes beneath NULL and never returns the mask-backed logical view.
    def physical_values : Buffer
      copy_values(@values)
    end

    # Convert a non-null semantic column into a Nullable one. Slots hidden by
    # the supplied mask receive the canonical physical representation of the
    # source scalar; this is a semantic conversion, not a lossless rewrite of
    # arbitrary pre-existing hidden bytes.
    def as_nullable(mask : ScalarNullMap) : WideTupleLeafColumn
      raise ArgumentError.new("Tuple leaf is already Nullable") if @leaf_type.nullable?
      raise ArgumentError.new("Nullable Tuple mask row count differs from physical values") unless mask.size == @values.size
      exact_type = @leaf_type.with_nullable
      WideTupleLeafColumn.new(@name, exact_type, nullable_physical_values, mask)
    end

    # Read one scalar without copying the backing column. String values are
    # copied at this leaf boundary so callers never receive an alias into the
    # owned payload buffer.
    def value_at(index : Int32) : Value
      values = @values
      raise BoundsError.new("Tuple leaf row index is out of bounds") if index < 0 || index >= values.size
      return nil if @null_map.try(&.null_at?(index))
      if @leaf_type.nullable?
        return nullable_logical_value(index)
      end
      if values.is_a?(Array(String))
        String.new(values[index].to_slice)
      else
        values[index]
      end
    end

    # Exact nominal scalar access; a same-width but different type is not
    # converted or relabeled.
    def value_at(index : Int32, type : T.class) : T forall T
      raise BoundsError.new("Tuple leaf row index is out of bounds") if index < 0 || index >= @values.size
      if @null_map.try(&.null_at?(index))
        raise UnsupportedFormatError.new("Nullable Tuple leaf row is NULL")
      end
      {% if T == String %}
        values = @values
        raise UnsupportedFormatError.new("Tuple leaf is not String") unless values.is_a?(Array(String))
        String.new(values[index].to_slice)
      {% elsif T == Bool %}
        values = @values
        if @leaf_type.nullable? && @leaf_type.base_type_name == "Bool" && values.is_a?(Array(UInt8))
          return (values[index] != 0_u8).as(T)
        end
        raise UnsupportedFormatError.new("Tuple leaf is not Bool") unless values.is_a?(Array(Bool))
        values[index]
      {% elsif T == FixedStringValue || T == Enum8Value || T == Enum16Value ||
                 T == Decimal32Value || T == Decimal64Value || T == Decimal128Value || T == Decimal256TupleValue ||
                 T == UUIDValue || T == IPv4Value || T == IPv6Value %}
        {% if T == Enum8Value %}
          if exact_type = @leaf_type.parameterized_type.as?(WideTupleEnumType)
            if values = @values.as?(Array(Int8))
              return Enum8Value.new(exact_type.definition, values[index]).as(T)
            end
          end
        {% elsif T == Enum16Value %}
          if exact_type = @leaf_type.parameterized_type.as?(WideTupleEnumType)
            if values = @values.as?(Array(Int16))
              return Enum16Value.new(exact_type.definition, values[index]).as(T)
            end
          end
        {% elsif T == Decimal32Value || T == Decimal64Value || T == Decimal128Value || T == Decimal256TupleValue %}
          if exact_type = @leaf_type.parameterized_type.as?(WideTupleDecimalType)
            if @leaf_type.nullable?
              return decimal_value_at(index, exact_type).as?(T) ||
                     raise(UnsupportedFormatError.new("Tuple Decimal leaf does not match requested exact type"))
            end
          end
        {% end %}
        values = @values
        unless values.is_a?(Array(T))
          raise UnsupportedFormatError.new("Tuple leaf does not match requested exact type")
        end
        values[index]
      {% elsif T == DateValue || T == Date32Value || T == DateTimeValue || T == DateTime64Value || T == TimeValue || T == Time64Value %}
        values = @values
        unless values.is_a?(Array(T))
          raise UnsupportedFormatError.new("Tuple leaf does not match requested exact type")
        end
        values[index]
      {% elsif T == Int8 || T == UInt8 || T == Int16 || T == UInt16 ||
                 T == Int32 || T == UInt32 || T == Int64 || T == UInt64 ||
                 T == Int128 || T == UInt128 || T == Int256Value || T == UInt256Value ||
                 T == Float32 || T == Float64 || T == BFloat16Value %}
        if @leaf_type.nullable? &&
           (@leaf_type.base_type_name == "Bool" || !@leaf_type.parameterized_type.nil?)
          raise UnsupportedFormatError.new("Nullable Tuple leaf requires its exact logical value type")
        end
        values = @values
        unless values.is_a?(Array(T))
          raise UnsupportedFormatError.new("Tuple leaf does not match requested exact type")
        end
        values[index]
      {% else %}
        raise UnsupportedFormatError.new("unsupported numeric Tuple leaf type")
      {% end %}
    end

    # String and FixedString payload accounting share the existing row
    # contract. FixedString owns exactly N padded bytes, including zero fill.
    def string_bytesize_at(index : Int32) : UInt64
      values = @values
      raise BoundsError.new("Tuple leaf row index is out of bounds") if index < 0 || index >= values.size
      if values.is_a?(Array(String))
        values[index].bytesize.to_u64
      elsif values.is_a?(Array(FixedStringValue))
        values[index].width.to_u64
      else
        raise UnsupportedFormatError.new("Tuple leaf is not String or FixedString")
      end
    end

    def uint64_values : Array(UInt64)
      reject_nullable_typed_values!
      values = @values
      return values.dup if values.is_a?(Array(UInt64))
      raise UnsupportedFormatError.new("Tuple leaf is not UInt64")
    end

    def string_values : Array(String)
      reject_nullable_typed_values!
      values = @values
      return values.map { |value| String.new(value.to_slice) } if values.is_a?(Array(String))
      raise UnsupportedFormatError.new("Tuple leaf is not String")
    end

    def values_as(type : T.class) : Array(T) forall T
      reject_nullable_typed_values!
      {% if T == String %}
        values = @values
        raise UnsupportedFormatError.new("Tuple leaf is not String") unless values.is_a?(Array(String))
        values.map { |value| String.new(value.to_slice) }
      {% elsif T == Bool %}
        values = @values
        raise UnsupportedFormatError.new("Tuple leaf is not Bool") unless values.is_a?(Array(Bool))
        values.dup
      {% elsif T == FixedStringValue || T == Enum8Value || T == Enum16Value ||
                 T == Decimal32Value || T == Decimal64Value || T == Decimal128Value || T == Decimal256TupleValue ||
                 T == UUIDValue || T == IPv4Value || T == IPv6Value %}
        values = @values
        unless values.is_a?(Array(T))
          raise UnsupportedFormatError.new("Tuple leaf does not match requested exact type")
        end
        values.dup
      {% elsif T == DateValue || T == Date32Value || T == DateTimeValue || T == DateTime64Value || T == TimeValue || T == Time64Value %}
        values = @values
        unless values.is_a?(Array(T))
          raise UnsupportedFormatError.new("Tuple leaf does not match requested exact type")
        end
        values.dup
      {% elsif T == Int8 || T == UInt8 || T == Int16 || T == UInt16 ||
                 T == Int32 || T == UInt32 || T == Int64 || T == UInt64 ||
                 T == Int128 || T == UInt128 || T == Int256Value || T == UInt256Value ||
                 T == Float32 || T == Float64 || T == BFloat16Value %}
        values = @values
        unless values.is_a?(Array(T))
          raise UnsupportedFormatError.new("Tuple leaf does not match requested exact type")
        end
        values.dup
      {% else %}
        raise UnsupportedFormatError.new("unsupported numeric Tuple leaf type")
      {% end %}
    end

    # Expose only byte lengths for budget preflight; no mutable payload escapes.
    def each_string_bytesize(& : Int32 -> Nil) : Nil
      values = @values
      if values.is_a?(Array(String))
        values.each do |value|
          yield value.bytesize.to_i32
          nil
        end
      elsif values.is_a?(Array(FixedStringValue))
        values.each do |value|
          yield value.width
          nil
        end
      else
        raise UnsupportedFormatError.new("Tuple leaf is not String or FixedString")
      end
      nil
    end

    def owned_copy : WideTupleLeafColumn
      WideTupleLeafColumn.new(@name, @leaf_type, @values, @null_map)
    end

    def owned_copy_for(exact_type : WideTupleLeafType) : WideTupleLeafColumn
      raise ArgumentError.new("Tuple leaf descriptor differs from requested owner") unless @leaf_type == exact_type
      WideTupleLeafColumn.new(@name, exact_type, @values, @null_map)
    end

    # Rebind an equivalent caller-supplied Enum map to the retained plan's
    # single canonical descriptor. Other family metadata is retained exactly.
    def owned_copy_for(exact_type : WideTupleParameterizedType) : WideTupleLeafColumn
      current = @parameterized_type || raise(ArgumentError.new("Tuple leaf has no parameterized owner"))
      unless same_parameterized_type?(current, exact_type)
        raise ArgumentError.new("Tuple leaf exact type differs from requested owner")
      end
      if @leaf_type.nullable?
        WideTupleLeafColumn.new(@name, @leaf_type, @values, @null_map)
      else
        WideTupleLeafColumn.new(@name, exact_type, @values)
      end
    end

    def owned_copy_for(exact_type : DateTimeColumnType) : WideTupleLeafColumn
      current = @datetime_type || raise(ArgumentError.new("Tuple leaf has no DateTime descriptor"))
      raise ArgumentError.new("Tuple leaf DateTime descriptor differs from requested owner") unless current == exact_type
      if @leaf_type.nullable?
        WideTupleLeafColumn.new(@name, @leaf_type, @values, @null_map)
      else
        case exact_type.family
        when DateTimeColumnType::Family::DateTime
          values = @values.as?(Array(DateTimeValue)) ||
                   raise(ArgumentError.new("DateTime buffer has the wrong carrier"))
          WideTupleLeafColumn.new(@name, exact_type, values)
        when DateTimeColumnType::Family::DateTime64
          values = @values.as?(Array(DateTime64Value)) ||
                   raise(ArgumentError.new("DateTime64 buffer has the wrong carrier"))
          WideTupleLeafColumn.new(@name, exact_type, values)
        else
          raise ArgumentError.new("DateTime descriptor family is unsupported")
        end
      end
    end

    private def reject_nullable_typed_values! : Nil
      if @leaf_type.nullable?
        raise UnsupportedFormatError.new("typed Tuple leaf access does not expose Nullable physical placeholders")
      end
      nil
    end

    private def nullable_logical_value(index : Int32) : Value
      if @leaf_type.base_type_name == "Bool"
        return @values.as(Array(UInt8))[index] != 0_u8
      end
      if parameterized_type = @leaf_type.parameterized_type
        case parameterized_type
        when WideTupleEnumType
          if parameterized_type.definition.kind == :enum8
            return Enum8Value.new(parameterized_type.definition, @values.as(Array(Int8))[index])
          else
            return Enum16Value.new(parameterized_type.definition, @values.as(Array(Int16))[index])
          end
        when WideTupleDecimalType
          return decimal_value_at(index, parameterized_type)
        when WideTupleFixedStringType
          return @values.as(Array(FixedStringValue))[index]
        end
      end
      values = @values
      if values.is_a?(Array(String))
        String.new(values[index].to_slice)
      else
        values[index]
      end
    end

    private def decimal_value_at(index : Int32, exact_type : WideTupleDecimalType) : Decimal32Value | Decimal64Value | Decimal128Value | Decimal256TupleValue
      precision = exact_type.precision
      scale = exact_type.scale
      values = @values
      if values.is_a?(Array(Int32))
        Decimal32Value.new(values[index], precision, scale)
      elsif values.is_a?(Array(Int64))
        Decimal64Value.new(values[index], precision, scale)
      elsif values.is_a?(Array(Int128))
        Decimal128Value.new(values[index], precision, scale)
      elsif values.is_a?(Array(Int256Value))
        raw = Decimal256Value.new(values[index].low, values[index].high)
        Decimal256TupleValue.new(raw, precision, scale)
      else
        raise UnsupportedFormatError.new("Nullable Decimal physical carrier does not match exact type")
      end
    end

    private def nullable_physical_values : Buffer
      if parameterized_type = @leaf_type.parameterized_type
        case parameterized_type
        when WideTupleFixedStringType
          @values
        when WideTupleEnumType
          if parameterized_type.definition.kind == :enum8
            @values.as(Array(Enum8Value)).map(&.code)
          else
            @values.as(Array(Enum16Value)).map(&.code)
          end
        when WideTupleDecimalType
          case parameterized_type.storage_width
          when 4
            @values.as(Array(Decimal32Value)).map(&.raw)
          when 8
            @values.as(Array(Decimal64Value)).map(&.raw)
          when 16
            @values.as(Array(Decimal128Value)).map(&.raw)
          else
            @values.as(Array(Decimal256TupleValue)).map do |value|
              Int256Value.new(value.raw.low, value.raw.high)
            end
          end
        else
          raise UnsupportedFormatError.new("unsupported parameterized Nullable Tuple leaf")
        end
      elsif @leaf_type.base_type_name == "Bool"
        @values.as(Array(Bool)).map { |value| value ? 1_u8 : 0_u8 }
      else
        @values
      end
    end

    private def validate_nullable_storage!(leaf_type : WideTupleLeafType, values : Buffer, null_map : ScalarNullMap?) : Nil
      if leaf_type.nullable?
        map = null_map || raise(ArgumentError.new("Nullable Tuple leaf requires a null map"))
        raise ArgumentError.new("Nullable Tuple leaf mask row count differs from physical values") unless map.size == values.size
      elsif null_map
        raise ArgumentError.new("non-nullable Tuple leaf cannot carry a null map")
      end

      base_type_name = leaf_type.base_type_name
      if parameterized_type = leaf_type.parameterized_type
        case parameterized_type
        when WideTupleFixedStringType
          raise ArgumentError.new("FixedString buffer has the wrong carrier") unless values.is_a?(Array(FixedStringValue))
          parameterized_type.validate_buffer!(values)
        when WideTupleEnumType
          if leaf_type.nullable?
            if parameterized_type.definition.kind == :enum8
              raise ArgumentError.new("Nullable Enum8 requires raw Int8 storage") unless values.is_a?(Array(Int8))
              values.as(Array(Int8)).each_with_index do |code, index|
                next if null_map.not_nil!.null_at?(index)
                raise ArgumentError.new("Enum8 code is not declared") unless parameterized_type.definition.declared?(code)
              end
            else
              raise ArgumentError.new("Nullable Enum16 requires raw Int16 storage") unless values.is_a?(Array(Int16))
              values.as(Array(Int16)).each_with_index do |code, index|
                next if null_map.not_nil!.null_at?(index)
                raise ArgumentError.new("Enum16 code is not declared") unless parameterized_type.definition.declared?(code)
              end
            end
          else
            if parameterized_type.definition.kind == :enum8
              if enum_values = values.as?(Array(Enum8Value))
                parameterized_type.validate_buffer!(enum_values)
              else
                raise ArgumentError.new("Enum8 buffer has the wrong carrier")
              end
            else
              if enum_values = values.as?(Array(Enum16Value))
                parameterized_type.validate_buffer!(enum_values)
              else
                raise ArgumentError.new("Enum16 buffer has the wrong carrier")
              end
            end
          end
        when WideTupleDecimalType
          if leaf_type.nullable?
            expected = case parameterized_type.storage_width
                       when  4 then values.is_a?(Array(Int32))
                       when  8 then values.is_a?(Array(Int64))
                       when 16 then values.is_a?(Array(Int128))
                       else         values.is_a?(Array(Int256Value))
                       end
            raise ArgumentError.new("Decimal physical buffer has the wrong carrier") unless expected
          else
            case parameterized_type.storage_width
            when 4
              if decimal_values = values.as?(Array(Decimal32Value))
                parameterized_type.validate_buffer!(decimal_values)
              else
                raise ArgumentError.new("Decimal buffer has the wrong carrier")
              end
            when 8
              if decimal_values = values.as?(Array(Decimal64Value))
                parameterized_type.validate_buffer!(decimal_values)
              else
                raise ArgumentError.new("Decimal buffer has the wrong carrier")
              end
            when 16
              if decimal_values = values.as?(Array(Decimal128Value))
                parameterized_type.validate_buffer!(decimal_values)
              else
                raise ArgumentError.new("Decimal buffer has the wrong carrier")
              end
            else
              if decimal_values = values.as?(Array(Decimal256TupleValue))
                parameterized_type.validate_buffer!(decimal_values)
              else
                raise ArgumentError.new("Decimal buffer has the wrong carrier")
              end
            end
          end
        end
      elsif datetime_type = leaf_type.datetime_type
        case datetime_type.family
        when DateTimeColumnType::Family::DateTime
          if datetime_values = values.as?(Array(DateTimeValue))
            validate_datetime_buffer!(datetime_type, datetime_values)
          else
            raise ArgumentError.new("DateTime buffer has the wrong carrier")
          end
        when DateTimeColumnType::Family::DateTime64
          if datetime_values = values.as?(Array(DateTime64Value))
            validate_datetime_buffer!(datetime_type, datetime_values)
          else
            raise ArgumentError.new("DateTime64 buffer has the wrong carrier")
          end
        else
          raise ArgumentError.new("DateTime descriptor family is unsupported")
        end
      elsif base_type_name == "String"
        raise ArgumentError.new("String physical buffer has the wrong carrier") unless values.is_a?(Array(String))
      elsif base_type_name == "Bool" && leaf_type.nullable?
        raise ArgumentError.new("Nullable Bool physical buffer has the wrong carrier") unless values.is_a?(Array(UInt8))
      elsif identifier_width = WideTupleIdentifierType.width(base_type_name)
        case base_type_name
        when "UUID" then raise ArgumentError.new("UUID buffer has the wrong carrier") unless values.is_a?(Array(UUIDValue))
        when "IPv4" then raise ArgumentError.new("IPv4 buffer has the wrong carrier") unless values.is_a?(Array(IPv4Value))
        when "IPv6" then raise ArgumentError.new("IPv6 buffer has the wrong carrier") unless values.is_a?(Array(IPv6Value))
        end
      elsif temporal_width = WideTupleTemporalType.width(base_type_name)
        if temporal_values = values.as?(Array(DateValue))
          WideTupleTemporalType.validate_buffer!(base_type_name, temporal_values)
        elsif temporal_values = values.as?(Array(Date32Value))
          WideTupleTemporalType.validate_buffer!(base_type_name, temporal_values)
        elsif temporal_values = values.as?(Array(DateTimeValue))
          WideTupleTemporalType.validate_buffer!(base_type_name, temporal_values)
        elsif temporal_values = values.as?(Array(DateTime64Value))
          WideTupleTemporalType.validate_buffer!(base_type_name, temporal_values)
        elsif temporal_values = values.as?(Array(TimeValue))
          WideTupleTemporalType.validate_buffer!(base_type_name, temporal_values)
        elsif temporal_values = values.as?(Array(Time64Value))
          WideTupleTemporalType.validate_buffer!(base_type_name, temporal_values)
        else
          raise ArgumentError.new("temporal buffer has the wrong carrier")
        end
      elsif base_type_name == "Bool"
        raise ArgumentError.new("Bool buffer has the wrong carrier") unless values.is_a?(Array(Bool))
      else
        expected_width = WideTupleNumericType.width(base_type_name) ||
                         raise(ArgumentError.new("Tuple leaf is not an admitted scalar type"))
        raise ArgumentError.new("numeric physical buffer width does not match exact type") unless physical_width(values) == expected_width
        expected_name = physical_numeric_type_name(values)
        raise ArgumentError.new("numeric physical buffer identity does not match exact type") unless expected_name == base_type_name
      end
      nil
    end

    private def copy_nullable_physical_values(leaf_type : WideTupleLeafType, values : Buffer) : Buffer
      # Once nullable, Enum and Decimal intentionally retain raw physical
      # carriers rather than constructing semantic wrappers beneath NULL.
      if leaf_type.nullable?
        copy_values(values)
      elsif parameterized_type = leaf_type.parameterized_type
        copy_parameterized_values(parameterized_type, values)
      elsif datetime_type = leaf_type.datetime_type
        case datetime_type.family
        when DateTimeColumnType::Family::DateTime
          datetime_values = values.as?(Array(DateTimeValue)) ||
                            raise(ArgumentError.new("DateTime buffer has the wrong carrier"))
          validate_datetime_buffer!(datetime_type, datetime_values)
        when DateTimeColumnType::Family::DateTime64
          datetime_values = values.as?(Array(DateTime64Value)) ||
                            raise(ArgumentError.new("DateTime64 buffer has the wrong carrier"))
          validate_datetime_buffer!(datetime_type, datetime_values)
        else
          raise ArgumentError.new("DateTime descriptor family is unsupported")
        end
        copy_values(values)
      else
        copy_values(values)
      end
    end

    private def physical_width(values : Buffer) : Int32
      if values.is_a?(Array(Int8)) || values.is_a?(Array(UInt8))
        1
      elsif values.is_a?(Array(Int16)) || values.is_a?(Array(UInt16)) || values.is_a?(Array(BFloat16Value))
        2
      elsif values.is_a?(Array(Int32)) || values.is_a?(Array(UInt32)) || values.is_a?(Array(Float32))
        4
      elsif values.is_a?(Array(Int64)) || values.is_a?(Array(UInt64)) || values.is_a?(Array(Float64))
        8
      elsif values.is_a?(Array(Int128)) || values.is_a?(Array(UInt128))
        16
      elsif values.is_a?(Array(Int256Value)) || values.is_a?(Array(UInt256Value))
        32
      else
        0
      end
    end

    private def physical_numeric_type_name(values : Buffer) : String
      if values.is_a?(WideTupleNumericType::Buffer)
        WideTupleNumericType.type_name_for_buffer(values)
      elsif values.is_a?(Array(Bool))
        "Bool"
      else
        ""
      end
    end

    private def inferred_leaf_type(values : Buffer) : WideTupleLeafType
      type_name = if values.is_a?(Array(String))
                    "String"
                  elsif values.is_a?(Array(Bool))
                    "Bool"
                  elsif values.is_a?(Array(UUIDValue))
                    WideTupleIdentifierType.type_name(UUIDValue)
                  elsif values.is_a?(Array(IPv4Value))
                    WideTupleIdentifierType.type_name(IPv4Value)
                  elsif values.is_a?(Array(IPv6Value))
                    WideTupleIdentifierType.type_name(IPv6Value)
                  elsif values.is_a?(Array(DateValue))
                    "Date"
                  elsif values.is_a?(Array(Date32Value))
                    "Date32"
                  elsif values.is_a?(Array(DateTimeValue))
                    "DateTime"
                  elsif values.is_a?(Array(TimeValue))
                    "Time"
                  elsif values.is_a?(Array(UInt8))
                    "UInt8"
                  else
                    WideTupleNumericType.type_name_for_buffer(values.as(WideTupleNumericType::Buffer))
                  end
      WideTupleLeafType.parse(type_name) || raise(ArgumentError.new("Tuple leaf buffer type is not admitted"))
    end

    private def validate_datetime_buffer!(exact_type : DateTimeColumnType, values : WideTupleTemporalType::Buffer) : Nil
      raise ArgumentError.new("DateTime Tuple leaves require a scalar descriptor") unless exact_type.shape == DateTimeColumnType::Shape::Scalar
      case exact_type.family
      when DateTimeColumnType::Family::DateTime
        raise ArgumentError.new("DateTime buffer has the wrong carrier") unless values.is_a?(Array(DateTimeValue))
      when DateTimeColumnType::Family::DateTime64
        raise ArgumentError.new("DateTime64 buffer has the wrong carrier") unless values.is_a?(Array(DateTime64Value))
        expected_precision = exact_type.precision?.not_nil!
        values.each do |value|
          raise ArgumentError.new("DateTime64 value precision does not match exact type") unless value.precision == expected_precision
        end
      end
      nil
    end

    private def copy_parameterized_values(exact_type : WideTupleParameterizedType, values : Buffer) : Buffer
      case exact_type
      when WideTupleFixedStringType
        if values.is_a?(Array(FixedStringValue))
          exact_type.validate_buffer!(values)
          values.dup
        else
          raise ArgumentError.new("FixedString buffer has the wrong carrier")
        end
      when WideTupleEnumType
        if values.is_a?(Array(Enum8Value))
          exact_type.validate_buffer!(values)
          Array(Enum8Value).new(values.size) do |index|
            values[index].with_definition(exact_type.definition)
          end
        elsif values.is_a?(Array(Enum16Value))
          exact_type.validate_buffer!(values)
          Array(Enum16Value).new(values.size) do |index|
            values[index].with_definition(exact_type.definition)
          end
        else
          raise ArgumentError.new("Enum buffer has the wrong carrier")
        end
      when WideTupleDecimalType
        if values.is_a?(Array(Decimal32Value))
          exact_type.validate_buffer!(values)
          values.dup
        elsif values.is_a?(Array(Decimal64Value))
          exact_type.validate_buffer!(values)
          values.dup
        elsif values.is_a?(Array(Decimal128Value))
          exact_type.validate_buffer!(values)
          values.dup
        elsif values.is_a?(Array(Decimal256TupleValue))
          exact_type.validate_buffer!(values)
          values.dup
        else
          raise ArgumentError.new("Decimal buffer has the wrong carrier")
        end
      else
        raise ArgumentError.new("Tuple leaf has an unsupported parameterized descriptor")
      end
    end

    private def same_parameterized_type?(left : WideTupleParameterizedType, right : WideTupleParameterizedType) : Bool
      if left.is_a?(WideTupleFixedStringType) && right.is_a?(WideTupleFixedStringType)
        left == right
      elsif left.is_a?(WideTupleEnumType) && right.is_a?(WideTupleEnumType)
        left == right
      elsif left.is_a?(WideTupleDecimalType) && right.is_a?(WideTupleDecimalType)
        left == right
      else
        false
      end
    end

    private def copy_values(values : Buffer) : Buffer
      if values.is_a?(Array(String))
        values.map { |value| String.new(value.to_slice) }
      elsif values.is_a?(Array(Bool))
        values.dup
      elsif values.is_a?(Array(FixedStringValue)) || values.is_a?(Array(Enum8Value)) ||
            values.is_a?(Array(Enum16Value)) || values.is_a?(Array(Decimal32Value)) ||
            values.is_a?(Array(Decimal64Value)) || values.is_a?(Array(Decimal128Value)) ||
            values.is_a?(Array(Decimal256TupleValue))
        values.dup
      elsif values.is_a?(Array(UUIDValue)) || values.is_a?(Array(IPv4Value)) || values.is_a?(Array(IPv6Value))
        values.dup
      elsif values.is_a?(Array(DateValue)) || values.is_a?(Array(Date32Value)) ||
            values.is_a?(Array(DateTimeValue)) || values.is_a?(Array(DateTime64Value)) ||
            values.is_a?(Array(TimeValue)) || values.is_a?(Array(Time64Value))
        values.dup
      else
        copy_numeric_values(values.as(WideTupleNumericType::Buffer))
      end
    end

    private def copy_allowed_array(values : Array(T)) : Buffer forall T
      {% if T == String %}
        values.map { |value| String.new(value.to_slice) }
      {% elsif T == Bool %}
        values.dup
      {% elsif T == FixedStringValue || T == Enum8Value || T == Enum16Value ||
                 T == Decimal32Value || T == Decimal64Value || T == Decimal128Value || T == Decimal256TupleValue %}
        raise ArgumentError.new("parameterized Tuple leaf requires exact type metadata")
      {% elsif T == UUIDValue || T == IPv4Value || T == IPv6Value %}
        values.dup
      {% elsif T == DateValue || T == Date32Value || T == DateTimeValue || T == DateTime64Value || T == TimeValue || T == Time64Value %}
        raise ArgumentError.new("temporal Tuple leaf requires exact type metadata")
      {% elsif T == Int8 || T == UInt8 || T == Int16 || T == UInt16 ||
                 T == Int32 || T == UInt32 || T == Int64 || T == UInt64 ||
                 T == Int128 || T == UInt128 || T == Int256Value || T == UInt256Value ||
                 T == Float32 || T == Float64 || T == BFloat16Value %}
        values.dup
      {% else %}
        raise UnsupportedFormatError.new("unsupported numeric Tuple leaf buffer")
      {% end %}
    end

    private def reject_descriptor_buffer!(values : Buffer) : Nil
      if values.is_a?(Array(FixedStringValue)) || values.is_a?(Array(Enum8Value)) ||
         values.is_a?(Array(Enum16Value)) || values.is_a?(Array(Decimal32Value)) ||
         values.is_a?(Array(Decimal64Value)) || values.is_a?(Array(Decimal128Value)) ||
         values.is_a?(Array(Decimal256TupleValue))
        raise ArgumentError.new("parameterized Tuple leaf requires exact type metadata")
      end
      nil
    end

    private def reject_temporal_buffer!(values : Buffer) : Nil
      if values.is_a?(Array(DateValue)) || values.is_a?(Array(Date32Value)) ||
         values.is_a?(Array(DateTimeValue)) || values.is_a?(Array(DateTime64Value)) ||
         values.is_a?(Array(TimeValue)) || values.is_a?(Array(Time64Value))
        raise ArgumentError.new("temporal Tuple leaf requires exact type metadata")
      end
      nil
    end

    private def copy_numeric_values(values : WideTupleNumericType::Buffer) : WideTupleNumericType::Buffer
      if values.is_a?(Array(Int8))
        values.dup
      elsif values.is_a?(Array(UInt8))
        values.dup
      elsif values.is_a?(Array(Int16))
        values.dup
      elsif values.is_a?(Array(UInt16))
        values.dup
      elsif values.is_a?(Array(Int32))
        values.dup
      elsif values.is_a?(Array(UInt32))
        values.dup
      elsif values.is_a?(Array(Int64))
        values.dup
      elsif values.is_a?(Array(UInt64))
        values.dup
      elsif values.is_a?(Array(Int128))
        values.dup
      elsif values.is_a?(Array(UInt128))
        values.dup
      elsif values.is_a?(Array(Int256Value))
        values.dup
      elsif values.is_a?(Array(UInt256Value))
        values.dup
      elsif values.is_a?(Array(Float32))
        values.dup
      elsif values.is_a?(Array(Float64))
        values.dup
      else
        values.as(Array(BFloat16Value)).dup
      end
    end
  end
end
