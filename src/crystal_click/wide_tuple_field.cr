module CrystalClick
  # One immutable, explicitly admitted leaf in a named scalar Tuple schema.
  struct WideTupleField
    @name : String
    @type_name : String
    @leaf_type : WideTupleLeafType

    def initialize(name : String, type_name : String)
      leaf_type = WideTupleLeafType.parse(type_name) ||
                  raise(ArgumentError.new("Tuple field type is not an admitted scalar leaf"))
      raise ArgumentError.new("Tuple field type name is not canonical") unless leaf_type.type_name == type_name
      @name = String.new(name.to_slice)
      @type_name = String.new(type_name.to_slice)
      @leaf_type = leaf_type
    end

    def initialize(name : String, type_name : String, parameterized_type : WideTupleParameterizedType?)
      leaf_type = WideTupleLeafType.new(type_name, false, parameterized_type)
      @name = String.new(name.to_slice)
      @type_name = leaf_type.type_name
      @leaf_type = leaf_type
    end

    def initialize(
      name : String,
      type_name : String,
      parameterized_type : WideTupleParameterizedType?,
      datetime_type : DateTimeColumnType?,
    )
      raise ArgumentError.new("Tuple field cannot have two exact descriptors") if parameterized_type && datetime_type
      leaf_type = WideTupleLeafType.new(type_name, false, parameterized_type, datetime_type)
      @name = String.new(name.to_slice)
      @type_name = leaf_type.type_name
      @leaf_type = leaf_type
    end

    def initialize(name : String, leaf_type : WideTupleLeafType)
      @name = String.new(name.to_slice)
      @type_name = leaf_type.type_name
      @leaf_type = leaf_type
    end

    def name : String
      String.new(@name.to_slice)
    end

    def type_name : String
      String.new(@type_name.to_slice)
    end

    def parameterized_type : WideTupleParameterizedType?
      @leaf_type.parameterized_type
    end

    def datetime_type : DateTimeColumnType?
      @leaf_type.datetime_type
    end

    def leaf_type : WideTupleLeafType
      @leaf_type
    end
  end
end
