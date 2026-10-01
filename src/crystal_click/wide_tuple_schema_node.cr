module CrystalClick
  # Immutable node in a bounded named Tuple schema tree. Nodes retain only
  # their local member name and children; flattened path descriptors belong to
  # WideTupleTypePlan and are derived from this tree once at admission.
  class WideTupleSchemaNode
    @name : String
    @leaf_type : WideTupleLeafType?
    @children : Array(WideTupleSchemaNode)
    @root : Bool

    def self.leaf(name : String, leaf_type : WideTupleLeafType) : WideTupleSchemaNode
      new(name, leaf_type)
    end

    def self.tuple(name : String, children : Array(WideTupleSchemaNode)) : WideTupleSchemaNode
      new(name, children)
    end

    # The synthetic root retains top-level children but has no logical name.
    def self.root(children : Array(WideTupleSchemaNode)) : WideTupleSchemaNode
      new(children)
    end

    def initialize(name : String, leaf_type : WideTupleLeafType)
      validate_member_name!(name)
      @name = String.new(name.to_slice)
      @leaf_type = leaf_type
      @children = [] of WideTupleSchemaNode
      @root = false
    end

    def initialize(name : String, children : Array(WideTupleSchemaNode))
      validate_member_name!(name)
      validate_children!(children)
      @name = String.new(name.to_slice)
      @leaf_type = nil
      @children = children.dup
      @root = false
    end

    def initialize(children : Array(WideTupleSchemaNode))
      validate_children!(children)
      @name = ""
      @leaf_type = nil
      @children = children.dup
      @root = true
    end

    def name : String
      String.new(@name.to_slice)
    end

    # Rebuild canonical type spelling from the retained descriptor/tree rather
    # than keeping a second full declaration String at every node.
    def type_name : String
      if leaf_type = @leaf_type
        leaf_type.type_name
      else
        tuple_type_name(@children)
      end
    end

    # Returns a local-name leaf descriptor for scalar nodes, or nil for Tuple
    # nodes. The descriptor is an export snapshot, not retained tree storage.
    def leaf_field? : WideTupleField?
      if leaf_type = @leaf_type
        WideTupleField.new(@name, leaf_type)
      end
    end

    def leaf? : Bool
      !@leaf_type.nil?
    end

    def children : Array(WideTupleSchemaNode)
      @children.dup
    end

    def root? : Bool
      @root
    end

    # Declared logical tree budget: retained node objects, child-array
    # headers/reference slots, and owned local member-name Strings. It excludes
    # exported snapshots, canonical type-name Strings, allocation headers, and
    # RSS; flattened path owners are charged separately by each plan field.
    def logical_charge : UInt64
      total = instance_sizeof(WideTupleSchemaNode).to_u64 +
              instance_sizeof(Array(WideTupleSchemaNode)).to_u64 +
              @children.size.to_u64 * sizeof(Pointer(WideTupleSchemaNode)).to_u64
      unless @root
        total += instance_sizeof(String).to_u64 + @name.bytesize.to_u64 + 1_u64
      end
      @children.each do |child|
        charge = child.logical_charge
        raise ArgumentError.new("Tuple schema tree charge overflows") if charge > UInt64::MAX - total
        total += charge
      end
      total
    end

    # Produce the compatibility flat leaf projection while preserving every
    # edge as a separate, unambiguous path segment.
    def flattened_fields : Array(WideTupleField)
      fields = [] of WideTupleField
      append_flattened_fields(fields, [] of String)
      fields
    end

    def ==(other : self) : Bool
      @name == other.name &&
        @root == other.root? &&
        @leaf_type == other.leaf_field?.try(&.leaf_type) &&
        @children == other.children
    end

    protected def append_flattened_fields(fields : Array(WideTupleField), prefix : Array(String)) : Nil
      if leaf_type = @leaf_type
        segments = prefix.dup
        segments << @name
        name = segments.join(".")
        fields << WideTupleField.new(name, leaf_type, segments)
      else
        next_prefix = prefix.dup
        next_prefix << @name unless @root
        @children.each do |child|
          child.append_flattened_fields(fields, next_prefix)
        end
      end
      nil
    end

    private def tuple_type_name(children : Array(WideTupleSchemaNode)) : String
      String.build do |io|
        io << "Tuple("
        children.each_with_index do |child, index|
          io << ", " unless index == 0
          io << child.name
          io << ' '
          io << child.type_name
        end
        io << ')'
      end
    end

    private def validate_member_name!(name : String) : Nil
      raise ArgumentError.new("Tuple field name is invalid") unless identifier?(name)
      raise ArgumentError.new("Tuple field name exceeds limit") if name.bytesize > WideTupleTypePlan::MAX_FIELD_NAME_BYTES
      raise ArgumentError.new("reserved Tuple field name") if name == "null"
    end

    private def validate_children!(children : Array(WideTupleSchemaNode)) : Nil
      raise ArgumentError.new("Tuple must have at least one field") if children.empty?
      names = Set(String).new
      children.each do |child|
        raise ArgumentError.new("Tuple schema child cannot be its root") if child.root?
        raise ArgumentError.new("Tuple field name is duplicated") unless names.add?(child.name)
      end
      nil
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
