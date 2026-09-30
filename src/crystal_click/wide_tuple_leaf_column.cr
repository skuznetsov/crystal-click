module CrystalClick
  # One owned named leaf buffer. Sibling row alignment is intentionally a
  # writer preflight concern, so independently prepared columns can differ.
  class WideTupleLeafColumn
    @name : String
    @values : Array(UInt64) | Array(String)

    def initialize(name : String, values : Array(UInt64))
      @name = String.new(name.to_slice)
      @values = values.dup
    end

    def initialize(name : String, values : Array(String))
      @name = String.new(name.to_slice)
      @values = values.map { |value| String.new(value.to_slice) }
    end

    def name : String
      String.new(@name.to_slice)
    end

    def type_name : String
      String.new((@values.is_a?(Array(UInt64)) ? "UInt64" : "String").to_slice)
    end

    def size : Int32
      @values.size
    end

    # Read one scalar without copying the backing column. String values are
    # copied at this leaf boundary so callers never receive an alias into the
    # owned payload buffer.
    def value_at(index : Int32) : UInt64 | String
      values = @values
      raise BoundsError.new("Tuple leaf row index is out of bounds") if index < 0 || index >= values.size
      if values.is_a?(Array(UInt64))
        values[index]
      else
        String.new(values.as(Array(String))[index].to_slice)
      end
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
      values = @values
      if values.is_a?(Array(UInt64))
        WideTupleLeafColumn.new(@name, values)
      else
        WideTupleLeafColumn.new(@name, values.as(Array(String)))
      end
    end
  end
end
