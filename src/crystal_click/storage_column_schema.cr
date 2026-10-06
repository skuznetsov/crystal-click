module CrystalClick
  # Bounded logical tree for the first persisted recursive Tuple slice.
  # Tuple nodes may contain JSON leaves and JSON-free BinaryBulk subtrees;
  # JSON beneath every other structural wrapper remains outside this profile.
  class StorageColumnSchema
    TUPLE  = :tuple
    OBJECT = :object
    BULK   = :bulk

    @kind : Symbol
    @declaration : String
    @source_declaration : String
    @children : Array(StorageColumnSchema)
    @field_names : Array(String)
    @field_displays : Array(String)
    @named_tuple : Bool
    @object_schema : ObjectDocumentSchema?
    @bulk_type : BinaryDataType?

    private def initialize(
      @kind : Symbol,
      source_declaration : String,
      children : Array(StorageColumnSchema) = [] of StorageColumnSchema,
      field_names : Array(String) = [] of String,
      field_displays : Array(String) = [] of String,
      @named_tuple : Bool = false,
      @object_schema : ObjectDocumentSchema? = nil,
      @bulk_type : BinaryDataType? = nil,
    )
      @source_declaration = String.new(source_declaration.to_slice)
      @children = children.dup
      @field_names = field_names.map { |name| String.new(name.to_slice) }
      @field_displays = field_displays.map { |name| String.new(name.to_slice) }
      unless @kind == TUPLE || @kind == OBJECT || @kind == BULK
        raise ArgumentError.new("unknown recursive storage schema node")
      end
      if @kind == TUPLE
        unless @field_names.size == @field_displays.size && (!@named_tuple || @field_names.size == @children.size) && (@named_tuple || @field_names.empty?)
          raise ArgumentError.new("recursive storage Tuple field roster is inconsistent")
        end
        if @object_schema || @bulk_type
          raise ArgumentError.new("recursive storage Tuple cannot retain a leaf descriptor")
        end
        @declaration = render_tuple
      elsif @kind == OBJECT
        unless @children.empty? && @field_names.empty? && @field_displays.empty? && @object_schema && !@bulk_type
          raise ArgumentError.new("recursive storage JSON leaf is inconsistent")
        end
        @declaration = @object_schema.not_nil!.declaration
      else
        unless @children.empty? && @field_names.empty? && @field_displays.empty? && @bulk_type && !@object_schema
          raise ArgumentError.new("recursive storage BinaryBulk leaf is inconsistent")
        end
        type = @bulk_type.not_nil!
        if type.contains_json?
          raise ArgumentError.new("JSON is outside a recursive storage BinaryBulk leaf")
        end
        @declaration = type.name
      end
    end

    def self.object(schema : ObjectDocumentSchema, source : String) : StorageColumnSchema
      new(OBJECT, source, object_schema: schema)
    end

    def self.bulk(type : BinaryDataType, source : String) : StorageColumnSchema
      new(BULK, source, bulk_type: type)
    end

    def self.tuple(
      source : String,
      named : Bool,
      field_names : Array(String),
      field_displays : Array(String),
      children : Array(StorageColumnSchema),
    ) : StorageColumnSchema
      if named
        seen = Set(String).new
        field_names.each_with_index do |name, index|
          if name.empty? || seen.includes?(name)
            raise ArgumentError.new("recursive storage Tuple names must be nonempty and unique")
          end
          seen << name
          display = field_displays[index]?
          unless display
            raise ArgumentError.new("recursive storage Tuple display roster is incomplete")
          end
          bytes = display.to_slice
          shape = ObjectTupleFieldName.shape(bytes, 0, bytes.size)
          unless shape && ObjectTupleFieldName.decode(bytes, 0, bytes.size) == name &&
                 !ObjectTupleFieldName.null?(bytes, 0, bytes.size)
            raise ArgumentError.new("recursive storage Tuple display does not encode its field name")
          end
        end
      end
      new(TUPLE, source, children, field_names, field_displays, named)
    end

    def self.parse(source : String, limits : BinaryCodecLimits = ObjectDocumentSchema::DEFAULT_LIMITS) : StorageColumnSchema
      StorageColumnSchemaParser.parse(source, limits)
    end

    def kind : Symbol
      @kind
    end

    def tuple? : Bool
      @kind == TUPLE
    end

    def object? : Bool
      @kind == OBJECT
    end

    def bulk? : Bool
      @kind == BULK
    end

    def has_json? : Bool
      return true if @kind == OBJECT
      @kind == TUPLE && @children.any?(&.has_json?)
    end

    def named_tuple? : Bool
      @named_tuple
    end

    def declaration : String
      String.new(@declaration.to_slice)
    end

    def declaration_byte_size : Int32
      @declaration.bytesize
    end

    def canonical_declaration : String
      declaration
    end

    # Exact source text from the typed metadata. The separate canonical
    # declaration is what the writer publishes.
    def source_declaration : String
      String.new(@source_declaration.to_slice)
    end

    def child_count : Int32
      @children.size
    end

    def child_at(index : Int) : StorageColumnSchema
      @children[index]
    end

    def children : Array(StorageColumnSchema)
      @children.dup
    end

    def field_name_at(index : Int) : String
      raise ArgumentError.new("unnamed Tuple has no field-name roster") unless @named_tuple
      String.new(@field_names[index].to_slice)
    end

    def field_display_at(index : Int) : String
      raise ArgumentError.new("unnamed Tuple has no field-name roster") unless @named_tuple
      String.new(@field_displays[index].to_slice)
    end

    def object_schema : ObjectDocumentSchema
      @object_schema || raise(ArgumentError.new("recursive storage node is not a JSON leaf"))
    end

    def object_schema_or_nil : ObjectDocumentSchema?
      @object_schema
    end

    def bulk_type : BinaryDataType
      @bulk_type || raise(ArgumentError.new("recursive storage node is not a BinaryBulk leaf"))
    end

    def bulk_type_or_nil : BinaryDataType?
      @bulk_type
    end

    # Structural site IDs use Tuple indexes, never nominal descriptor identity
    # or field-name strings. That keeps equal JSON declarations independent.
    def json_site_keys(prefix : String = "root") : Array(String)
      output = Array(String).new
      append_json_site_keys(prefix, output)
      output
    end

    def each_json_site(prefix : String = "root", &block : String, ObjectDocumentSchema -> Nil) : Nil
      sites = Array(Tuple(String, ObjectDocumentSchema)).new
      append_json_sites(prefix, sites)
      sites.each { |site, schema| yield site, schema }
      nil
    end

    # Reparse the exact caller-facing declaration at a trust boundary and
    # compare its complete admitted tree with this descriptor. Public factories
    # cannot smuggle stale source text, leaf handles or filename identities
    # past plan construction.
    def validate_source_tree!(limits : BinaryCodecLimits) : Nil
      parsed = StorageColumnSchema.parse(@source_declaration, limits)
      unless same_tree?(parsed)
        raise ArgumentError.new("recursive storage descriptor differs from its source declaration")
      end
      nil
    end

    def same_tree?(other : StorageColumnSchema) : Bool
      return false unless @kind == other.@kind && @declaration == other.@declaration &&
                          @named_tuple == other.@named_tuple && @field_names == other.@field_names &&
                          @field_displays == other.@field_displays && @children.size == other.@children.size
      if left = @object_schema
        right = other.@object_schema
        return false unless right && left.declaration == right.declaration
      elsif other.@object_schema
        return false
      end
      if left = @bulk_type
        right = other.@bulk_type
        return false unless right && left == right
      elsif other.@bulk_type
        return false
      end
      @children.each_with_index.all? { |child, index| child.same_tree?(other.@children[index]) }
    end

    protected def append_json_site_keys(prefix : String, output : Array(String)) : Nil
      if @kind == OBJECT
        output << String.new(prefix.to_slice)
      elsif @kind == TUPLE
        @children.each_with_index do |child, index|
          child_prefix = String.build do |io|
            io << prefix << "/tuple[" << index << ']'
          end
          child.append_json_site_keys(child_prefix, output)
        end
      end
      nil
    end

    protected def append_json_sites(prefix : String, output : Array(Tuple(String, ObjectDocumentSchema))) : Nil
      if schema = @object_schema
        output << {String.new(prefix.to_slice), schema}
      elsif @kind == TUPLE
        @children.each_with_index do |child, index|
          child_prefix = String.build do |io|
            io << prefix << "/tuple[" << index << ']'
          end
          child.append_json_sites(child_prefix, output)
        end
      end
      nil
    end

    private def render_tuple : String
      String.build do |io|
        io << "Tuple("
        @children.each_with_index do |child, index|
          io << ", " if index > 0
          if @named_tuple
            io << @field_displays[index] << ' '
          end
          io << child.declaration
        end
        io << ')'
      end
    end
  end
end
