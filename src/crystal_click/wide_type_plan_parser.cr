module CrystalClick
  class WideTypePlan
    # Recursive syntax parser kept separate from exact physical-shape admission.
    class Parser
      MAX_DEPTH =  64
      MAX_NODES = 512

      @bytes : Bytes
      @offset : Int32
      @nodes : Int32

      def initialize(source : String)
        @bytes = source.to_slice
        @offset = 0
        @nodes = 0
      end

      def parse : Node?
        begin
          node = parse_type(0)
          skip_whitespace
          @offset == @bytes.size ? node : nil
        rescue ex : ArgumentError
          nil
        end
      end

      private def parse_type(depth : Int32) : Node
        raise ArgumentError.new("type nesting exceeds limit") if depth > MAX_DEPTH
        @nodes += 1
        raise ArgumentError.new("type node count exceeds limit") if @nodes > MAX_NODES

        name = parse_identifier || raise(ArgumentError.new("type name is missing"))
        skip_whitespace
        return Node.new(name, [] of Node, [] of String) unless consume('(')

        children = [] of Node
        field_names = [] of String
        skip_whitespace
        if consume(')')
          return Node.new(name, children, field_names)
        end

        loop do
          skip_whitespace
          field_name, child = if name == "Tuple"
                                parse_tuple_member(depth + 1)
                              else
                                {"", parse_type(depth + 1)}
                              end
          children << child
          field_names << field_name
          skip_whitespace
          break if consume(')')
          raise ArgumentError.new("type argument separator is missing") unless consume(',')
        end

        Node.new(name, children, field_names)
      end

      private def parse_tuple_member(depth : Int32) : {String, Node}
        saved_offset = @offset
        candidate = parse_identifier
        if candidate
          identifier_end = @offset
          skip_whitespace
          if @offset > identifier_end && identifier_start?(@bytes[@offset]?)
            return {candidate, parse_type(depth)}
          end
        end

        @offset = saved_offset
        {"", parse_type(depth)}
      end

      private def parse_identifier : String?
        start = @offset
        return nil unless identifier_start?(@bytes[@offset]?)
        @offset += 1
        while identifier_continue?(@bytes[@offset]?)
          @offset += 1
        end
        String.new(@bytes[start, @offset - start])
      end

      private def identifier_start?(byte : UInt8?) : Bool
        return false unless byte
        (byte >= 'a'.ord.to_u8 && byte <= 'z'.ord.to_u8) ||
          (byte >= 'A'.ord.to_u8 && byte <= 'Z'.ord.to_u8) ||
          byte == '_'.ord.to_u8 || (byte >= '0'.ord.to_u8 && byte <= '9'.ord.to_u8)
      end

      private def identifier_continue?(byte : UInt8?) : Bool
        identifier_start?(byte)
      end

      private def skip_whitespace : Nil
        while byte = @bytes[@offset]?
          break unless byte == ' '.ord.to_u8 || byte == '\t'.ord.to_u8 || byte == '\r'.ord.to_u8 || byte == '\n'.ord.to_u8
          @offset += 1
        end
      end

      private def consume(character : Char) : Bool
        return false unless @bytes[@offset]? == character.ord.to_u8
        @offset += 1
        true
      end
    end
  end
end
