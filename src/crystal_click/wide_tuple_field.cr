module CrystalClick
  # One immutable, explicitly admitted leaf in a named scalar Tuple schema.
  struct WideTupleField
    @name : String
    @type_name : String
    @parameterized_type : WideTupleParameterizedType?
    @datetime_type : DateTimeColumnType?

    def initialize(name : String, type_name : String)
      @name = String.new(name.to_slice)
      @type_name = String.new(type_name.to_slice)
      @parameterized_type = nil
      @datetime_type = nil
    end

    def initialize(name : String, type_name : String, parameterized_type : WideTupleParameterizedType?)
      @name = String.new(name.to_slice)
      @type_name = String.new(type_name.to_slice)
      if parameterized_type
        raise ArgumentError.new("Tuple field type name differs from exact descriptor") unless parameterized_type.type_name == type_name
      end
      @parameterized_type = parameterized_type
      @datetime_type = nil
    end

    def initialize(
      name : String,
      type_name : String,
      parameterized_type : WideTupleParameterizedType?,
      datetime_type : DateTimeColumnType?,
    )
      raise ArgumentError.new("Tuple field cannot have two exact descriptors") if parameterized_type && datetime_type
      if parameterized_type
        raise ArgumentError.new("Tuple field type name differs from exact descriptor") unless parameterized_type.type_name == type_name
      end
      if datetime_type
        raise ArgumentError.new("DateTime Tuple fields require a scalar descriptor") unless datetime_type.shape == DateTimeColumnType::Shape::Scalar
        raise ArgumentError.new("Tuple field type name differs from exact descriptor") unless datetime_type.leaf_type_name == type_name
      end
      @name = String.new(name.to_slice)
      @type_name = String.new(type_name.to_slice)
      @parameterized_type = parameterized_type
      @datetime_type = datetime_type
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

    def datetime_type : DateTimeColumnType?
      @datetime_type
    end
  end
end
