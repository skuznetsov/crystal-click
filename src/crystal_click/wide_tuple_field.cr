module CrystalClick
  # One immutable, explicitly admitted leaf in a named scalar Tuple schema.
  struct WideTupleField
    @name : String
    @type_name : String
    @parameterized_type : WideTupleParameterizedType?

    def initialize(name : String, type_name : String)
      @name = String.new(name.to_slice)
      @type_name = String.new(type_name.to_slice)
      @parameterized_type = nil
    end

    def initialize(name : String, type_name : String, parameterized_type : WideTupleParameterizedType?)
      @name = String.new(name.to_slice)
      @type_name = String.new(type_name.to_slice)
      if parameterized_type
        raise ArgumentError.new("Tuple field type name differs from exact descriptor") unless parameterized_type.type_name == type_name
      end
      @parameterized_type = parameterized_type
    end

    def name : String
      String.new(@name.to_slice)
    end

    def type_name : String
      String.new(@type_name.to_slice)
    end

    def parameterized_type : WideTupleParameterizedType?
      @parameterized_type
    end
  end
end
