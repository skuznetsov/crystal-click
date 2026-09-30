module CrystalClick
  # One owned named leaf buffer. Sibling row alignment is intentionally a
  # writer preflight concern, so independently prepared columns can differ.
  class WideTupleLeafColumn
    alias Value = WideTupleNumericType::Value | WideTupleIdentifierType::Value | WideTupleTemporalType::Value | Bool | String
    alias Buffer = WideTupleNumericType::Buffer | WideTupleIdentifierType::Buffer | WideTupleTemporalType::Buffer | Array(Bool) | Array(String)

    @name : String
    @values : Buffer
    @temporal_type_name : String?

    # Preserve the original constructor overloads and their union dispatch.
    def initialize(name : String, values : Array(UInt64))
      @name = String.new(name.to_slice)
      @values = values.dup
      @temporal_type_name = nil
    end

    def initialize(name : String, values : Array(String))
      @name = String.new(name.to_slice)
      @values = values.map { |value| String.new(value.to_slice) }
      @temporal_type_name = nil
    end

    # A closed union constructor is used by internal immutable-copy paths.
    # Copy it on entry so even a statically widened Buffer cannot introduce an
    # alias to a caller-owned Array or String.
    def initialize(name : String, values : Buffer)
      @name = String.new(name.to_slice)
      reject_temporal_buffer!(values)
      @values = copy_values(values)
      @temporal_type_name = nil
    end

    # Temporal buffers require explicit semantic metadata, including when
    # empty, because several wrappers share raw carrier widths.
    def initialize(name : String, exact_type : String, values : WideTupleTemporalType::Buffer)
      WideTupleTemporalType.validate_buffer!(exact_type, values)
      @name = String.new(name.to_slice)
      @temporal_type_name = String.new(exact_type.to_slice)
      @values = copy_values(values)
    end

    # Generic construction is closed to String, Bool, and the exact admitted
    # native/wrapper numeric identities. Unsupported element types fail closed.
    def initialize(name : String, values : Array(T)) forall T
      @name = String.new(name.to_slice)
      @values = copy_allowed_array(values)
      @temporal_type_name = nil
    end

    def name : String
      String.new(@name.to_slice)
    end

    def type_name : String
      if temporal_type_name = @temporal_type_name
        return String.new(temporal_type_name.to_slice)
      end
      values = @values
      if values.is_a?(Array(String))
        String.new("String".to_slice)
      elsif values.is_a?(Array(Bool))
        String.new("Bool".to_slice)
      elsif identifier_buffer?(values)
        WideTupleIdentifierType.type_name_for_buffer(values.as(WideTupleIdentifierType::Buffer))
      else
        WideTupleNumericType.type_name_for_buffer(values.as(WideTupleNumericType::Buffer))
      end
    end

    def size : Int32
      @values.size
    end

    # An owned snapshot of the complete leaf buffer. String buffers are
    # explicitly byte-copied because String#dup aliases its backing bytes.
    def values : Buffer
      copy_values(@values)
    end

    # Read one scalar without copying the backing column. String values are
    # copied at this leaf boundary so callers never receive an alias into the
    # owned payload buffer.
    def value_at(index : Int32) : Value
      values = @values
      raise BoundsError.new("Tuple leaf row index is out of bounds") if index < 0 || index >= values.size
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
      {% if T == String %}
        values = @values
        raise UnsupportedFormatError.new("Tuple leaf is not String") unless values.is_a?(Array(String))
        String.new(values[index].to_slice)
      {% elsif T == Bool %}
        values = @values
        raise UnsupportedFormatError.new("Tuple leaf is not Bool") unless values.is_a?(Array(Bool))
        values[index]
      {% elsif T == UUIDValue || T == IPv4Value || T == IPv6Value %}
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
        values = @values
        unless values.is_a?(Array(T))
          raise UnsupportedFormatError.new("Tuple leaf does not match requested exact type")
        end
        values[index]
      {% else %}
        raise UnsupportedFormatError.new("unsupported numeric Tuple leaf type")
      {% end %}
    end

    # Return String payload accounting for one row without exposing or copying
    # its bytes.
    def string_bytesize_at(index : Int32) : UInt64
      values = @values
      raise BoundsError.new("Tuple leaf row index is out of bounds") if index < 0 || index >= values.size
      if values.is_a?(Array(String))
        values[index].bytesize.to_u64
      else
        raise UnsupportedFormatError.new("Tuple leaf is not String")
      end
    end

    def uint64_values : Array(UInt64)
      values = @values
      return values.dup if values.is_a?(Array(UInt64))
      raise UnsupportedFormatError.new("Tuple leaf is not UInt64")
    end

    def string_values : Array(String)
      values = @values
      return values.map { |value| String.new(value.to_slice) } if values.is_a?(Array(String))
      raise UnsupportedFormatError.new("Tuple leaf is not String")
    end

    def values_as(type : T.class) : Array(T) forall T
      {% if T == String %}
        values = @values
        raise UnsupportedFormatError.new("Tuple leaf is not String") unless values.is_a?(Array(String))
        values.map { |value| String.new(value.to_slice) }
      {% elsif T == Bool %}
        values = @values
        raise UnsupportedFormatError.new("Tuple leaf is not Bool") unless values.is_a?(Array(Bool))
        values.dup
      {% elsif T == UUIDValue || T == IPv4Value || T == IPv6Value %}
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

    # Expose only byte lengths for budget preflight; no mutable String buffer
    # escapes and no payload copy is needed to compute aggregate charges.
    def each_string_bytesize(& : Int32 -> Nil) : Nil
      values = @values
      unless values.is_a?(Array(String))
        raise UnsupportedFormatError.new("Tuple leaf is not String")
      end
      values.each do |value|
        yield value.bytesize.to_i32
        nil
      end
      nil
    end

    # Public immutable leaf objects may be retained by a result container;
    # copy remains explicit for callers that require a separate owned value.
    def owned_copy : WideTupleLeafColumn
      if temporal_type_name = @temporal_type_name
        WideTupleLeafColumn.new(@name, temporal_type_name, @values.as(WideTupleTemporalType::Buffer))
      else
        WideTupleLeafColumn.new(@name, @values)
      end
    end

    private def copy_values(values : Buffer) : Buffer
      if values.is_a?(Array(String))
        values.map { |value| String.new(value.to_slice) }
      elsif values.is_a?(Array(Bool))
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

    private def identifier_buffer?(values : Buffer) : Bool
      values.is_a?(Array(UUIDValue)) || values.is_a?(Array(IPv4Value)) || values.is_a?(Array(IPv6Value))
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
