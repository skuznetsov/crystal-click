module CrystalClick
  class WideTypePlan
    struct Node
      getter name : String
      @children : Array(Node)
      @field_names : Array(String)

      def initialize(@name : String, children : Array(Node), field_names : Array(String))
        @children = children.dup
        @field_names = field_names.dup
      end

      def children : Array(Node)
        @children.dup
      end

      def child(index : Int) : Node
        @children[index]
      end

      # Tuple members have a name when the corresponding entry is non-empty;
      # generic type arguments and positional Tuple members use an empty name.
      def field_names : Array(String)
        @field_names.dup
      end

      def field_name(index : Int) : String
        @field_names[index]
      end
    end
  end
end
