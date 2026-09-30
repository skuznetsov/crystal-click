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
