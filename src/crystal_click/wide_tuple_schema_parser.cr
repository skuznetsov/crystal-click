module CrystalClick
  # Bounded, Tuple-local source parser. Unlike the shared type AST this keeps
  # each leaf's exact spelling long enough to enforce its physical profile,
  # while quoted Enum labels remain opaque to leaf spelling checks.
  class WideTupleSchemaParser
    MAX_SOURCE_BYTES = 4_096
    MAX_DEPTH        =    64
    MAX_NODES        =   512

    @bytes : Bytes
    @offset : Int32
    @node_count : Int32

    private def initialize(source : String)
      @bytes = source.to_slice
      @offset = 0
      @node_count = 0
    end

    def self.parse(source : String) : Array(WideTupleField)?
      return nil if source.bytesize > MAX_SOURCE_BYTES
      new(source).parse
    rescue ex : ArgumentError
      nil
    end

    # Parse one exact admitted scalar leaf without wrapping it in a synthetic
    # Tuple. The normal Tuple path calls #parse_leaf directly and therefore
    # does not recurse through this public owner factory.
    def self.parse_leaf_type(source : String) : WideTupleLeafType?
      return nil if source.bytesize > MAX_SOURCE_BYTES
      new(source).parse_standalone_leaf(source)
    rescue ex : ArgumentError
      nil
    end

    protected def parse_standalone_leaf(source : String) : WideTupleLeafType
      parse_leaf(source)
    end

    protected def parse : Array(WideTupleField)?
      # Match the legacy gate: leading whitespace is not accepted, while
      # whitespace after Tuple and after the closing parenthesis is.
      expect_text!("Tuple")
      @node_count = 1
      skip_whitespace
      expect_byte!('('.ord.to_u8)

      fields = [] of WideTupleField
      names = Set(String).new
      skip_whitespace
      raise ArgumentError.new("Tuple must have at least one field") if current_byte? == ')'.ord.to_u8

      loop do
        name = parse_field_name
        raise ArgumentError.new("Tuple field name is duplicated") unless names.add?(name)
        raise ArgumentError.new("Tuple field name exceeds limit") if name.bytesize > WideTupleTypePlan::MAX_FIELD_NAME_BYTES
        raise ArgumentError.new("reserved Tuple field name") if name == "null"

        unless whitespace?(current_byte?)
          raise ArgumentError.new("Tuple field name and type require whitespace")
        end
        skip_whitespace
        leaf_start = @offset
        leaf_end = scan_leaf_end
        leaf_source = String.new(@bytes[leaf_start, leaf_end - leaf_start])
        leaf_type = parse_leaf(leaf_source)
        fields << WideTupleField.new(name, leaf_type)
        skip_whitespace

        case current_byte?
        when ','.ord.to_u8
          @offset += 1
          skip_whitespace
          if current_byte? == ')'.ord.to_u8 || current_byte?.nil?
            raise ArgumentError.new("Tuple field is missing after comma")
          end
        when ')'.ord.to_u8
          @offset += 1
          break
        else
          raise ArgumentError.new("Tuple field delimiter is missing")
        end
      end

      skip_whitespace
      raise ArgumentError.new("trailing bytes after Tuple") unless @offset == @bytes.size
      fields
    end

    private def parse_field_name : String
      start = @offset
      byte = current_byte? || raise(ArgumentError.new("Tuple field name is missing"))
      raise ArgumentError.new("Tuple field name is invalid") unless identifier_start?(byte)
      @offset += 1
      while byte = current_byte?
        break unless identifier_continue?(byte)
        @offset += 1
      end
      String.new(@bytes[start, @offset - start])
    end

    # Scan through one leaf without treating separators inside quoted Enum
    # labels or nested parentheses as Tuple delimiters.
    private def scan_leaf_end : Int32
      start = @offset
      depth = 0_i32
      in_quote = false
      escaped = false

      while byte = current_byte?
        if in_quote
          if escaped
            escaped = false
          elsif byte == '\\'.ord.to_u8
            escaped = true
          elsif byte == '\''.ord.to_u8
            in_quote = false
          end
        else
          case byte
          when '\''.ord.to_u8
            in_quote = true
          when '('.ord.to_u8
            depth += 1
            raise ArgumentError.new("Tuple leaf nesting exceeds limit") if depth + 1 > MAX_DEPTH
          when ')'.ord.to_u8
            break if depth == 0
            depth -= 1
          when ','.ord.to_u8
            break if depth == 0
          end
        end
        @offset += 1
      end

      raise ArgumentError.new("Tuple leaf source is empty") if @offset == start
      raise ArgumentError.new("Tuple leaf quote or parenthesis is unclosed") if in_quote || escaped || depth != 0

      ending = @offset
      while ending > start && whitespace?(@bytes[ending - 1]?)
        ending -= 1
      end
      raise ArgumentError.new("Tuple leaf source is empty") if ending == start
      ending
    end

    private def parse_leaf(source : String) : WideTupleLeafType
      if source.starts_with?("Nullable(")
        add_node! # Nullable wrapper syntax is a node distinct from its base leaf.
        raise ArgumentError.new("Nullable Tuple leaf wrapper is not canonical") unless source.ends_with?(')')
        inner = String.new(source.to_slice[9, source.bytesize - 10])
        raise ArgumentError.new("Nullable Tuple leaf cannot be nested") if inner.starts_with?("Nullable(")
        base_name, parameterized_type, datetime_type = parse_bare_leaf(inner)
        return WideTupleLeafType.new(base_name, true, parameterized_type, datetime_type)
      end

      base_name, parameterized_type, datetime_type = parse_bare_leaf(source)
      WideTupleLeafType.new(base_name, false, parameterized_type, datetime_type)
    end

    private def parse_bare_leaf(source : String) : {String, WideTupleParameterizedType?, DateTimeColumnType?}
      add_node!
      if datetime_type = DateTimeColumnType.parse_leaf(source)
        add_node! if datetime_type.precision?
        add_node! if datetime_type.time_zone?
        return {datetime_type.leaf_type_name, nil, datetime_type}
      end
      case source
      when /\AFixedString\(([1-9][0-9]*)\)\z/
        digits = $1
        add_node! # The width argument is a syntax node as well.
        width = bounded_positive_integer(digits, 65_536) || raise(ArgumentError.new("FixedString width is out of range"))
        owner = WideTupleFixedStringType.new(width)
        {owner.type_name, owner, nil}
      when /\A(?:Enum8|Enum16)\(/
        definition = parse_enum(source)
        owner = WideTupleEnumType.new(definition)
        {owner.type_name, owner, nil}
      when /\A(?:Decimal|Decimal32|Decimal64|Decimal128|Decimal256)(?:\(|\z)/
        owner = parse_decimal(source)
        {owner.type_name, owner, nil}
      else
        raise ArgumentError.new("Tuple leaf is not admitted") unless bare_leaf?(source)
        add_node! if source.starts_with?("DateTime64(") || source.starts_with?("Time64(")
        {source, nil, nil}
      end
    end

    private def parse_decimal(source : String) : WideTupleDecimalType
      precision = 0
      scale = 0
      case source
      when "Decimal"
        precision = 10
        scale = 0
      when /\ADecimal\(([1-9][0-9]*)\)\z/
        add_node!
        precision = bounded_positive_integer($1, 76) || raise(ArgumentError.new("Decimal precision is out of range"))
      when /\ADecimal\(([1-9][0-9]*), (0|[1-9][0-9]*)\)\z/
        add_node!
        add_node!
        precision = bounded_positive_integer($1, 76) || raise(ArgumentError.new("Decimal precision is out of range"))
        scale = bounded_nonnegative_integer($2, 76) || raise(ArgumentError.new("Decimal scale is out of range"))
      when /\ADecimal(32|64|128|256)\((0|[1-9][0-9]*)\)\z/
        add_node!
        precision = case $1
                    when "32"  then 9
                    when "64"  then 18
                    when "128" then 38
                    else            76
                    end
        scale = bounded_nonnegative_integer($2, precision) || raise(ArgumentError.new("Decimal scale is out of range"))
      else
        raise ArgumentError.new("Decimal leaf spelling is not canonical")
      end
      WideTupleDecimalType.new(precision, scale)
    end

    private def parse_enum(source : String) : WideTupleEnumDefinition
      kind, prefix = if source.starts_with?("Enum8(")
                       {:enum8, "Enum8("}
                     elsif source.starts_with?("Enum16(")
                       {:enum16, "Enum16("}
                     else
                       raise ArgumentError.new("unsupported Enum kind")
                     end
      add_node!
      bytes = source.to_slice
      offset = prefix.bytesize
      entries = [] of Tuple(String, Int16)
      loop do
        label, offset = parse_enum_label(bytes, offset)
        expect_slice!(bytes, offset, " = ")
        offset += 3
        code, offset = parse_enum_code(bytes, offset, kind)
        add_node!
        entries << {label, code}
        if bytes[offset]? == ','.ord.to_u8
          expect_slice!(bytes, offset, ", ")
          offset += 2
        elsif bytes[offset]? == ')'.ord.to_u8 && offset == bytes.size - 1
          offset += 1
          break
        else
          raise ArgumentError.new("Enum entry delimiter is not canonical")
        end
      end
      raise ArgumentError.new("Enum declaration cannot be empty") if entries.empty?
      WideTupleEnumDefinition.new(kind, entries)
    end

    private def parse_enum_label(bytes : Bytes, offset : Int32) : {String, Int32}
      raise ArgumentError.new("Enum label quote is missing") unless bytes[offset]? == '\''.ord.to_u8
      offset += 1
      label = String.build do |io|
        closed = false
        while byte = bytes[offset]?
          offset += 1
          if byte == '\''.ord.to_u8
            closed = true
            break
          elsif byte == '\\'.ord.to_u8
            escape = bytes[offset]? || raise(ArgumentError.new("Enum escape is incomplete"))
            offset += 1
            decoded = case escape
                      when '\''.ord.to_u8 then '\''.ord.to_u8
                      when '\\'.ord.to_u8 then '\\'.ord.to_u8
                      when 'b'.ord.to_u8  then 0x08_u8
                      when 'f'.ord.to_u8  then 0x0c_u8
                      when 'n'.ord.to_u8  then 0x0a_u8
                      when 'r'.ord.to_u8  then 0x0d_u8
                      when 't'.ord.to_u8  then 0x09_u8
                      when '0'.ord.to_u8  then 0x00_u8
                      else
                        raise ArgumentError.new("Enum label escape is unsupported")
                      end
            io.write_byte(decoded)
          else
            raise ArgumentError.new("Enum label contains a raw control byte") if byte < 0x20_u8 || byte == 0x7f_u8
            io.write_byte(byte)
          end
        end
        raise ArgumentError.new("Enum label is unterminated") unless closed
      end
      {label, offset}
    end

    private def parse_enum_code(bytes : Bytes, offset : Int32, kind : Symbol) : {Int16, Int32}
      negative = bytes[offset]? == '-'.ord.to_u8
      offset += 1 if negative
      first = bytes[offset]? || raise(ArgumentError.new("Enum code is missing"))
      raise ArgumentError.new("Enum code is not decimal") unless digit?(first)
      raise ArgumentError.new("Enum code has a leading zero") if first == '0'.ord.to_u8 && digit?(bytes[offset + 1]?)

      limit = if kind == :enum8
                negative ? 128 : 127
              else
                negative ? 32_768 : 32_767
              end
      value = 0_i32
      while byte = bytes[offset]?
        break unless digit?(byte)
        digit = (byte - '0'.ord.to_u8).to_i32
        raise ArgumentError.new("Enum code exceeds its signed width") if value > (limit - digit) // 10
        value = value * 10 + digit
        offset += 1
      end
      raise ArgumentError.new("negative zero is not canonical") if negative && value == 0
      code = (negative ? -value : value).to_i16
      {code, offset}
    end

    private def bare_leaf?(source : String) : Bool
      case source
      when "String", "Bool", "UUID", "IPv4", "IPv6", "Date", "Date32", "DateTime", "Time",
           "Int8", "UInt8", "Int16", "UInt16", "Int32", "UInt32", "Int64", "UInt64",
           "Int128", "UInt128", "Int256", "UInt256", "Float32", "Float64", "BFloat16"
        true
      when /\A(?:DateTime64|Time64)\([0-9]\)\z/
        true
      else
        false
      end
    end

    private def bounded_positive_integer(digits : String, maximum : Int32) : Int32?
      bounded_nonnegative_integer(digits, maximum).try { |value| value > 0 ? value : nil }
    end

    private def bounded_nonnegative_integer(digits : String, maximum : Int32) : Int32?
      value = 0_i32
      digits.to_slice.each do |byte|
        return nil unless digit?(byte)
        digit = (byte - '0'.ord.to_u8).to_i32
        return nil if value > (maximum - digit) // 10
        value = value * 10 + digit
      end
      value
    end

    private def expect_slice!(bytes : Bytes, offset : Int32, text : String) : Nil
      expected = text.to_slice
      raise ArgumentError.new("Enum syntax is not canonical") if offset + expected.size > bytes.size
      expected.each_with_index do |byte, index|
        raise ArgumentError.new("Enum syntax is not canonical") unless bytes[offset + index] == byte
      end
      nil
    end

    private def expect_text!(text : String) : Nil
      expect_slice!(@bytes, @offset, text)
      @offset += text.bytesize
    end

    private def expect_byte!(byte : UInt8) : Nil
      raise ArgumentError.new("Tuple opening parenthesis is missing") unless current_byte? == byte
      @offset += 1
    end

    private def skip_whitespace : Nil
      while byte = current_byte?
        break unless whitespace?(byte)
        @offset += 1
      end
      nil
    end

    private def current_byte? : UInt8?
      @bytes[@offset]?
    end

    private def whitespace?(byte : UInt8?) : Bool
      byte == ' '.ord.to_u8 || byte == '\t'.ord.to_u8 || byte == '\r'.ord.to_u8 || byte == '\n'.ord.to_u8
    end

    private def identifier_start?(byte : UInt8) : Bool
      byte == '_'.ord.to_u8 || (byte >= 'A'.ord.to_u8 && byte <= 'Z'.ord.to_u8) ||
        (byte >= 'a'.ord.to_u8 && byte <= 'z'.ord.to_u8)
    end

    private def identifier_continue?(byte : UInt8) : Bool
      identifier_start?(byte) || digit?(byte)
    end

    private def digit?(byte : UInt8?) : Bool
      !!byte && byte >= '0'.ord.to_u8 && byte <= '9'.ord.to_u8
    end

    private def add_node! : Nil
      @node_count += 1
      raise ArgumentError.new("Tuple type node count exceeds limit") if @node_count > MAX_NODES
      nil
    end
  end
end
