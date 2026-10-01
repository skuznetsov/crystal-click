module CrystalClick
  # One immutable, explicitly admitted leaf in a named scalar Tuple schema.
  struct WideTupleField
    @type_name : String
    @leaf_type : WideTupleLeafType
    @path_segments : Array(String)

    def initialize(name : String, type_name : String)
      leaf_type = WideTupleLeafType.parse(type_name) ||
                  raise(ArgumentError.new("Tuple field type is not an admitted scalar leaf"))
      raise ArgumentError.new("Tuple field type name is not canonical") unless leaf_type.type_name == type_name
      @type_name = String.new(type_name.to_slice)
      @leaf_type = leaf_type
      @path_segments = [String.new(name.to_slice)]
    end

    def initialize(name : String, type_name : String, parameterized_type : WideTupleParameterizedType?)
      leaf_type = WideTupleLeafType.new(type_name, false, parameterized_type)
      @type_name = leaf_type.type_name
      @leaf_type = leaf_type
      @path_segments = [String.new(name.to_slice)]
    end

    def initialize(
      name : String,
      type_name : String,
      parameterized_type : WideTupleParameterizedType?,
      datetime_type : DateTimeColumnType?,
    )
      raise ArgumentError.new("Tuple field cannot have two exact descriptors") if parameterized_type && datetime_type
      leaf_type = WideTupleLeafType.new(type_name, false, parameterized_type, datetime_type)
      @type_name = leaf_type.type_name
      @leaf_type = leaf_type
      @path_segments = [String.new(name.to_slice)]
    end

    def initialize(name : String, leaf_type : WideTupleLeafType)
      @type_name = leaf_type.type_name
      @leaf_type = leaf_type
      @path_segments = [String.new(name.to_slice)]
    end

    def initialize(name : String, leaf_type : WideTupleLeafType, path_segments : Array(String))
      raise ArgumentError.new("Tuple field path cannot be empty") if path_segments.empty?
      joined_path = path_segments.join(".")
      raise ArgumentError.new("Tuple field name does not match its path") unless name == joined_path
      path_segments.each do |segment|
        raise ArgumentError.new("Tuple field name exceeds limit") if segment.bytesize > WideTupleTypePlan::MAX_FIELD_NAME_BYTES
        raise ArgumentError.new("Tuple field path segment is invalid") unless identifier?(segment)
        raise ArgumentError.new("reserved Tuple field name") if segment == "null"
      end
      @type_name = leaf_type.type_name
      @leaf_type = leaf_type
      @path_segments = path_segments.map { |segment| String.new(segment.to_slice) }
    end

    def name : String
      @path_segments.join(".")
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

    def path_segments : Array(String)
      @path_segments.map { |segment| String.new(segment.to_slice) }
    end

    def path_equals?(segments : Array(String)) : Bool
      @path_segments == segments
    end

    def path_depth : Int32
      @path_segments.size
    end

    def path_starts_with?(prefix : Array(String)) : Bool
      return false if prefix.size > @path_segments.size
      prefix.each_with_index.all? { |segment, index| @path_segments[index] == segment }
    end

    def stream_path_suffix : String
      String.build do |io|
        @path_segments.each do |segment|
          io << "%2E"
          io << segment
        end
      end
    end

    def owned_copy : WideTupleField
      if @path_segments.size == 1
        # Preserve the legacy direct-constructor contract: field names may be
        # dotted even though parser-admitted schema paths are segment-based.
        WideTupleField.new(name, @leaf_type)
      else
        WideTupleField.new(name, @leaf_type, @path_segments)
      end
    end

    # Accounts only the newly retained path-segment array and its owned
    # strings. The scalar descriptor and field slot are charged separately.
    def path_metadata_charge : UInt64
      total = instance_sizeof(Array(String)).to_u64 +
              @path_segments.size.to_u64 * sizeof(Pointer(String)).to_u64
      @path_segments.each do |segment|
        total += instance_sizeof(String).to_u64 + segment.bytesize.to_u64 + 1_u64
      end
      total
    end

    private def identifier?(name : String) : Bool
      bytes = name.to_slice
      return false if bytes.empty?
      first = bytes[0]
      return false unless first == '_'.ord.to_u8 ||
                          (first >= 'A'.ord.to_u8 && first <= 'Z'.ord.to_u8) ||
                          (first >= 'a'.ord.to_u8 && first <= 'z'.ord.to_u8)
      bytes[1..].each do |byte|
        unless byte == '_'.ord.to_u8 ||
               (byte >= 'A'.ord.to_u8 && byte <= 'Z'.ord.to_u8) ||
               (byte >= 'a'.ord.to_u8 && byte <= 'z'.ord.to_u8) ||
               (byte >= '0'.ord.to_u8 && byte <= '9'.ord.to_u8)
          return false
        end
      end
      true
    end
  end
end
