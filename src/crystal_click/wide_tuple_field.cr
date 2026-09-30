module CrystalClick
  # One immutable, explicitly admitted leaf in a named scalar Tuple schema.
  struct WideTupleField
    @name : String
    @type_name : String

    def initialize(name : String, type_name : String)
      @name = String.new(name.to_slice)
      @type_name = String.new(type_name.to_slice)
    end

    def name : String
      String.new(@name.to_slice)
    end

    def type_name : String
      String.new(@type_name.to_slice)
    end
  end
end
