module CrystalClick
  # Bounded neutral parser for one full canonical SQL DataType tree. This
  # grammar owns syntax and descriptor construction only; Count, Object, and
  # physical callers apply their own narrower admission policies afterward.
  class BinaryRecursiveDataTypeNameReader
    def self.parse_canonical(
      source : String,
      limits : BinaryCodecLimits = BinaryCodecLimits.default,
    ) : BinaryDataType?
      return nil if source.bytesize.to_i64 > limits.max_bytes

      reader = new(source, limits)
      type = reader.parse || return nil
      budget = BinaryCodecBudget.new(limits, true)
      bounds = BinaryTypeNameBudget.measure(type, budget)
      rendered = BinaryTypeNameBudget.materialize(type, budget, bounds)
      rendered == source ? type : nil
    rescue ex : ArgumentError | CorruptPartError | UnsupportedFormatError
      nil
    end

    # Shared-budget entry point for a roster of StringBinary type names. A
    # Dynamic structure may contain many alternatives and recursive sites;
    # each name therefore consumes the caller's existing node/edge/name-work
    # budget instead of silently receiving a fresh per-name allowance.
    def self.parse_canonical_with_budget(
      source : String,
      budget : BinaryCodecBudget,
      depth : Int32 = 1,
    ) : BinaryDataType?
      return nil if source.bytesize.to_i64 > budget.limits.max_bytes

      reader = new(source, budget.limits, budget, depth)
      type = reader.parse || return nil
      bounds = BinaryTypeNameBudget.measure(type, budget, depth)
      rendered = BinaryTypeNameBudget.materialize(type, budget, bounds)
      rendered == source ? type : nil
    rescue ex : ArgumentError | CorruptPartError | UnsupportedFormatError
      nil
    end

    MAX_ENUM8_ENTRIES  = BinaryEnumDefinition::MAX_ENUM8_ENTRIES
    MAX_ENUM16_ENTRIES = BinaryEnumDefinition::MAX_ENUM16_ENTRIES

    @bytes : Bytes
    @offset : Int32
    @budget : BinaryCodecBudget
    @limits : BinaryCodecLimits
    @root_depth : Int32

    def initialize(
      source : String,
      @limits : BinaryCodecLimits,
      budget : BinaryCodecBudget? = nil,
      @root_depth : Int32 = 1,
    )
      @bytes = source.to_slice
      @offset = 0
      @budget = budget || BinaryCodecBudget.new(@limits)
    end

    def parse : BinaryDataType?
      begin
        type = parse_type(@root_depth)
        skip_whitespace
        @offset == @bytes.size ? type : nil
      rescue ex : ArgumentError | CorruptPartError
        nil
      end
    end

    private def parse_type(depth : Int32) : BinaryDataType
      skip_whitespace
      @budget.visit_node(depth)
      type_start = @offset
      name = read_identifier || invalid!("type name is missing")
      skip_whitespace
      return parse_atom(name, depth) unless consume('(')

      case name
      when "QBit"
        parse_qbit_type(type_start)
      when "Array"
        child = parse_child(depth + 1)
        expect(')')
        BinaryDataType.array(child)
      when "Nullable"
        child = parse_child(depth + 1)
        expect(')')
        BinaryDataType.nullable(child)
      when "LowCardinality"
        child = parse_child(depth + 1)
        expect(')')
        BinaryDataType.low_cardinality(child)
      when "Map"
        @budget.preflight_children(2_u64)
        key = parse_type(depth + 1)
        expect(',')
        value = parse_type(depth + 1)
        expect(')')
        BinaryDataType.map(key, value)
      when "Tuple"
        children, names = parse_tuple_members(depth + 1, require_names: false)
        BinaryDataType.tuple(children, names)
      when "Nested"
        # Nested owns an implicit named Tuple child in the descriptor tree.
        @budget.preflight_children(1_u64)
        @budget.visit_node(depth + 1)
        children, names = parse_tuple_members(depth + 2, require_names: true)
        BinaryDataType.nested(children, names.not_nil!)
      when "Variant"
        arms = parse_unlabelled_members(depth + 1)
        BinaryDataType.variant(arms, @limits)
      when "FixedString"
        size = read_unsigned(BinaryDataType::MAX_FIXED_STRING.to_u64)
        expect(')')
        BinaryDataType.fixed_string(size.to_i32)
      when "Decimal"
        precision = read_unsigned(76_u64)
        expect(',')
        scale = read_unsigned(76_u64)
        expect(')')
        decimal = DecimalType.new(precision.to_i32, scale.to_i32)
        BinaryDataType.decimal(decimal.storage_width * 8, decimal.precision, decimal.scale)
      when "DateTime"
        zone = parse_quoted_parameter
        expect(')')
        BinaryDataType.datetime(zone)
      when "DateTime64"
        scale = read_unsigned(9_u64)
        skip_whitespace
        zone = if consume(',')
                 parse_quoted_parameter
               else
                 nil
               end
        expect(')')
        BinaryDataType.datetime64(scale.to_i32, zone)
      when "Time64"
        scale = read_unsigned(9_u64)
        expect(')')
        BinaryDataType.time64(scale.to_i32)
      when "Enum8"
        parse_enum(8, depth)
      when "Enum16"
        parse_enum(16, depth)
      when "Dynamic"
        expect_word("max_types")
        expect('=')
        maximum = read_unsigned(254_u64)
        expect(')')
        BinaryDataType.dynamic(maximum.to_i32)
      when "JSON"
        parse_json_type(depth)
      when "SimpleAggregateFunction"
        function_name = read_identifier(BinarySimpleAggregateType::MAX_FUNCTION_NAME_BYTES) ||
                        invalid!("SimpleAggregateFunction name is missing")
        function = BinarySimpleAggregateType.function_from_name(function_name) ||
                   invalid!("SimpleAggregateFunction function is outside the canonical profile")
        parameters = if consume('(')
                       # Function parameters are descriptor metadata at this
                       # type's depth. Reserve the edge and node before parsing
                       # or allocating their bounded Field owner.
                       @budget.preflight_children(1_u64)
                       @budget.visit_node(depth)
                       value = read_unsigned(UInt64::MAX)
                       expect(')')
                       BinarySimpleAggregateParameters.one(value)
                     else
                       BinarySimpleAggregateParameters.empty
                     end
        expect(',')
        child = parse_child(depth + 1)
        expect(')')
        BinaryDataType.simple_aggregate(function, child, parameters)
      when "AggregateFunction"
        function_name = read_identifier(BinaryAggregateFunctionAdmission::MAX_FUNCTION_NAME_BYTES) ||
                        invalid!("AggregateFunction name is missing")
        if function_name == "count"
          skip_whitespace
          if consume(')')
            BinaryDataType.aggregate_count
          else
            expect(',')
            argument = parse_child(depth + 1)
            expect(')')
            BinaryDataType.aggregate_count(argument)
          end
        else
          expect(',')
          argument = parse_child(depth + 1)
          expect(')')
          descriptor = BinaryDataType.aggregate_function(function_name, argument)
          unless descriptor.aggregate_function_type.try(&.function_name) == function_name
            invalid!("AggregateFunction function identity is not canonical for its argument")
          end
          descriptor
        end
      else
        invalid!("unsupported parameterized data type")
      end
    end

    private def parse_qbit_type(type_start : Int32) : BinaryDataType
      # Delegate syntax, element admission, dimension/stride laws, and exact
      # canonical spelling to QBitType.for_type. Scan only a bounded candidate
      # first, so hostile parameter text is never copied into a String before
      # its local metadata limit is known.
      loop do
        byte = @bytes[@offset]? || invalid!("QBit type name is unterminated")
        @offset += 1
        if byte == ')'.ord.to_u8
          invalid!("QBit type name exceeds its bounded profile") if @offset - type_start > 128
          break
        end
        invalid!("QBit type name exceeds its bounded profile") if @offset - type_start >= 128
      end

      type_name = String.new(@bytes[type_start, @offset - type_start])
      qbit_type = QBitType.for_type(type_name) || invalid!("QBit type name is not canonical or supported")
      BinaryDataType.qbit(qbit_type)
    end

    private def parse_json_type(depth : Int32) : BinaryDataType
      max_dynamic_paths = BinaryJsonType::DEFAULT_MAX_DYNAMIC_PATHS
      max_dynamic_types = BinaryJsonType::DEFAULT_MAX_DYNAMIC_TYPES
      saw_max_dynamic_paths = false
      saw_max_dynamic_types = false
      typed_paths = {} of String => BinaryDataType

      skip_whitespace
      return BinaryDataType.json if consume(')')

      loop do
        skip_whitespace
        token = read_identifier(BinaryJsonType::MAX_PATH_BYTES) ||
                invalid!("JSON path or capacity setting is missing")
        skip_whitespace

        if consume('=')
          case token
          when "max_dynamic_paths"
            invalid!("JSON max_dynamic_paths is repeated") if saw_max_dynamic_paths
            saw_max_dynamic_paths = true
            max_dynamic_paths = read_unsigned(BinaryJsonType::MAX_DYNAMIC_PATHS.to_u64).to_i32
          when "max_dynamic_types"
            invalid!("JSON max_dynamic_types is repeated") if saw_max_dynamic_types
            saw_max_dynamic_types = true
            max_dynamic_types = read_unsigned(BinaryJsonType::MAX_DYNAMIC_TYPES.to_u64).to_i32
          else
            invalid!("unsupported JSON capacity setting")
          end
        else
          invalid!("JSON typed path count exceeds its supported limit") if typed_paths.size >= BinaryJsonType::MAX_TYPED_PATHS
          invalid!("JSON typed path is outside the admitted profile") unless BinaryJsonType.valid_path?(token)
          invalid!("JSON typed path is repeated") if typed_paths.has_key?(token)

          # A typed path contributes a declaration edge/node at this JSON
          # depth and a separate descriptor edge whose type starts one level
          # deeper. Charge each edge before retaining/parsing its declaration.
          @budget.preflight_children(1_u64)
          @budget.visit_node(depth)
          @budget.preflight_children(1_u64)
          @budget.ensure_depth(depth + 1)
          declared_type = parse_type(depth + 1)
          typed_paths[token] = declared_type
        end

        skip_whitespace
        break if consume(')')
        expect(',')
      end

      BinaryDataType.json(max_dynamic_paths, max_dynamic_types, typed_paths)
    end

    private def parse_atom(name : String, depth : Int32) : BinaryDataType
      return BinaryDataType.datetime if name == "DateTime"
      return BinaryDataType.dynamic if name == "Dynamic"
      return BinaryDataType.json if name == "JSON"
      if interval = BinaryIntervalType.parse(name)
        return BinaryDataType.interval(interval.kind)
      end
      if BinaryCustomGeoType.admitted_name?(name)
        descriptor = BinaryCustomGeoType.new(name)
        descriptor.preflight_expansion(@budget, depth)
        return BinaryDataType.custom(descriptor.name)
      end
      BinaryDataType.primitive(name)
    end

    private def parse_child(depth : Int32) : BinaryDataType
      @budget.preflight_children(1_u64)
      parse_type(depth)
    end

    private def parse_unlabelled_members(depth : Int32) : Array(BinaryDataType)
      children = [] of BinaryDataType
      skip_whitespace
      return children if consume(')')

      loop do
        @budget.preflight_children(1_u64)
        children << parse_type(depth)
        skip_whitespace
        break if consume(')')
        expect(',')
      end
      children
    end

    private def parse_tuple_members(
      depth : Int32,
      require_names : Bool,
    ) : Tuple(Array(BinaryDataType), Array(String)?)
      children = [] of BinaryDataType
      names = [] of String
      named_members : Bool? = nil
      skip_whitespace
      if consume(')')
        invalid!("Nested requires at least one named field") if require_names
        return {children, nil}
      end

      loop do
        skip_whitespace
        name = parse_optional_field_name
        if require_names && name.nil?
          invalid!("Nested field name is missing")
        end
        named = !name.nil?
        unless named_members.nil?
          invalid!("Tuple cannot mix named and unnamed fields") unless named_members.not_nil! == named
        else
          named_members = named
        end

        @budget.preflight_children(1_u64)
        children << parse_type(depth)
        names << (name || "")

        skip_whitespace
        break if consume(')')
        expect(',')
      end

      {children, named_members == true ? names : nil}
    end

    private def parse_optional_field_name : String?
      saved = @offset
      field = if consume('`')
                read_quoted_contents('`', tuple_field_escapes: true)
              else
                read_identifier
              end
      return nil unless field

      end_of_name = @offset
      skip_whitespace
      if @offset > end_of_name && identifier_start?(@bytes[@offset]?)
        field
      else
        @offset = saved
        nil
      end
    end

    private def parse_enum(width_bits : Int32, depth : Int32) : BinaryDataType
      maximum = width_bits == 8 ? MAX_ENUM8_ENTRIES : MAX_ENUM16_ENTRIES
      entries = [] of BinaryEnumDefinition::Entry
      skip_whitespace
      return build_enum(width_bits, entries) if consume(')')

      loop do
        invalid!("Enum entry count exceeds its signed code domain") if entries.size >= maximum
        # Enum entries are metadata nodes at the Enum descriptor's depth.
        @budget.preflight_children(1_u64)
        @budget.visit_node(depth)
        label = parse_quoted_parameter || invalid!("Enum label is missing")
        expect('=')
        code = read_signed_enum(width_bits)
        entries << {label, code}

        skip_whitespace
        break if consume(')')
        expect(',')
      end
      build_enum(width_bits, entries)
    end

    private def build_enum(width_bits : Int32, entries : Array(BinaryEnumDefinition::Entry)) : BinaryDataType
      width_bits == 8 ? BinaryDataType.enum8(entries) : BinaryDataType.enum16(entries)
    end

    private def read_signed_enum(width_bits : Int32) : Int16
      skip_whitespace
      negative = consume('-')
      maximum = if width_bits == 8
                  negative ? 128_u64 : 127_u64
                else
                  negative ? 32_768_u64 : 32_767_u64
                end
      magnitude = read_unsigned(maximum).to_i32
      negative ? (-magnitude).to_i16 : magnitude.to_i16
    end

    private def parse_quoted_parameter : String?
      skip_whitespace
      return nil unless consume('\'')
      read_quoted_contents('\'', tuple_field_escapes: false)
    end

    private def read_quoted_contents(delimiter : Char, tuple_field_escapes : Bool) : String
      String.build do |io|
        loop do
          byte = @bytes[@offset]? || invalid!("quoted parameter is unterminated")
          @offset += 1
          if byte == delimiter.ord.to_u8
            break
          elsif byte == '\\'.ord.to_u8
            escaped = @bytes[@offset]? || invalid!("quoted escape is incomplete")
            @offset += 1
            decoded = decode_escape(escaped, tuple_field_escapes)
            io.write_byte(decoded)
          else
            io.write_byte(byte)
          end
        end
      end
    end

    private def decode_escape(byte : UInt8, tuple_field_escapes : Bool) : UInt8
      case byte
      when '0'.ord.to_u8 then 0x00_u8
      when 'b'.ord.to_u8 then 0x08_u8
      when 't'.ord.to_u8 then 0x09_u8
      when 'n'.ord.to_u8 then 0x0a_u8
      when 'f'.ord.to_u8 then 0x0c_u8
      when 'r'.ord.to_u8 then 0x0d_u8
      when '\''.ord.to_u8
        invalid!("single-quote escape is not valid in a Tuple field") if tuple_field_escapes
        0x27_u8
      when '`'.ord.to_u8
        invalid!("backtick escape is not valid in an Enum or timezone") unless tuple_field_escapes
        0x60_u8
      when '\\'.ord.to_u8
        0x5c_u8
      else
        invalid!("quoted parameter uses an unsupported escape")
      end
    end

    private def read_unsigned(maximum : UInt64) : UInt64
      skip_whitespace
      first = @offset
      value = 0_u64
      while byte = @bytes[@offset]?
        break unless digit?(byte)
        digit = (byte - '0'.ord.to_u8).to_u64
        invalid!("integer parameter exceeds its supported domain") if digit > maximum || value > (maximum - digit) // 10_u64
        value = value * 10_u64 + digit
        @offset += 1
      end
      invalid!("integer parameter is missing") if @offset == first
      value
    end

    private def expect_word(expected : String) : Nil
      skip_whitespace
      actual = read_identifier
      invalid!("expected #{expected}") unless actual == expected
    end

    private def read_identifier(maximum_bytes : Int32? = nil) : String?
      start = @offset
      return nil unless identifier_start?(@bytes[@offset]?)
      @offset += 1
      while identifier_continue?(@bytes[@offset]?)
        if maximum = maximum_bytes
          invalid!("identifier exceeds its bounded profile") if @offset - start >= maximum
        end
        @offset += 1
      end
      String.new(@bytes[start, @offset - start])
    end

    private def expect(character : Char) : Nil
      skip_whitespace
      invalid!("expected #{character}") unless consume(character)
    end

    private def consume(character : Char) : Bool
      return false unless @bytes[@offset]? == character.ord.to_u8
      @offset += 1
      true
    end

    private def skip_whitespace : Nil
      while byte = @bytes[@offset]?
        break unless byte == ' '.ord.to_u8 || byte == '\t'.ord.to_u8 || byte == '\r'.ord.to_u8 || byte == '\n'.ord.to_u8
        @offset += 1
      end
    end

    private def identifier_start?(byte : UInt8?) : Bool
      return false unless byte
      (byte >= 'a'.ord.to_u8 && byte <= 'z'.ord.to_u8) ||
        (byte >= 'A'.ord.to_u8 && byte <= 'Z'.ord.to_u8) || byte == '_'.ord.to_u8
    end

    private def identifier_continue?(byte : UInt8?) : Bool
      identifier_start?(byte) || digit?(byte)
    end

    private def digit?(byte : UInt8?) : Bool
      return false unless byte
      byte >= '0'.ord.to_u8 && byte <= '9'.ord.to_u8
    end

    private def invalid!(message : String) : NoReturn
      raise ArgumentError.new(message)
    end
  end
end
