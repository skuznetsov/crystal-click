module CrystalClick
  # Closed semantic owner for the raw temporal wrappers used by named flat
  # Tuple leaves. Physical stream width and owned row-slot size are separate.
  module WideTupleTemporalType
    alias Value = DateValue | Date32Value | DateTimeValue | DateTime64Value | TimeValue | Time64Value

    alias Buffer = Array(DateValue) | Array(Date32Value) | Array(DateTimeValue) |
                   Array(DateTime64Value) | Array(TimeValue) | Array(Time64Value)

    def self.width(type_name : String) : Int32?
      if datetime_type = DateTimeColumnType.parse_leaf(type_name)
        return datetime_type.raw_width
      end
      case type_name
      when "Date"
        2
      when "Date32", "DateTime", "Time"
        4
      when /\ADateTime64\([0-9]\)\z/, /\ATime64\([0-9]\)\z/
        8
      else
        nil
      end
    end

    # Return a scale only for the exact canonical one-digit parameter form.
    # The lexical caller must still reject source spellings such as `T( 3 )`
    # before parsing, because the shared AST intentionally drops whitespace.
    def self.precision(type_name : String) : UInt8?
      if datetime_type = DateTimeColumnType.parse_leaf(type_name)
        return datetime_type.precision? if datetime_type.family == DateTimeColumnType::Family::DateTime64
        return nil
      end
      match = /\A(?:DateTime64|Time64)\(([0-9])\)\z/.match(type_name)
      match.try { |value| value[1].to_u8 }
    end

    # Canonicalize only the six admitted AST shapes. Parameter nodes are
    # decimal literal identifiers in the syntax-only parser; exact lexical
    # formatting remains the plan's pre-parse responsibility.
    def self.canonical_type(node : WideTypeExpression::Node) : String?
      if node.children.empty?
        case node.name
        when "Date", "Date32", "DateTime", "Time"
          node.name
        else
          nil
        end
      elsif node.name == "DateTime64" || node.name == "Time64"
        children = node.children
        return nil unless children.size == 1
        parameter = children[0]
        return nil unless parameter.children.empty? && /\A[0-9]\z/.matches?(parameter.name)
        "#{node.name}(#{parameter.name})"
      else
        nil
      end
    end

    # Report the actual in-memory value representation charged for each row.
    # DateTime64Value and Time64Value include precision alongside raw ticks.
    def self.owned_width(type_name : String) : Int32?
      if datetime_type = DateTimeColumnType.parse_leaf(type_name)
        return datetime_type.family == DateTimeColumnType::Family::DateTime ? sizeof(DateTimeValue).to_i32 : sizeof(DateTime64Value).to_i32
      end
      case type_name
      when "Date"
        sizeof(DateValue).to_i32
      when "Date32"
        sizeof(Date32Value).to_i32
      when "DateTime"
        sizeof(DateTimeValue).to_i32
      when "Time"
        sizeof(TimeValue).to_i32
      else
        if type_name.starts_with?("DateTime64(") && precision(type_name)
          sizeof(DateTime64Value).to_i32
        elsif type_name.starts_with?("Time64(") && precision(type_name)
          sizeof(Time64Value).to_i32
        else
          nil
        end
      end
    end

    # Exact semantic identity plus raw bits; scaled values additionally
    # include their precision. Same-width values of another kind never match.
    def self.same_bits?(left : Value, right : Value) : Bool
      if left.is_a?(DateValue) && right.is_a?(DateValue)
        left.raw == right.raw
      elsif left.is_a?(Date32Value) && right.is_a?(Date32Value)
        left.raw == right.raw
      elsif left.is_a?(DateTimeValue) && right.is_a?(DateTimeValue)
        left.raw == right.raw
      elsif left.is_a?(DateTime64Value) && right.is_a?(DateTime64Value)
        left.raw == right.raw && left.precision == right.precision
      elsif left.is_a?(TimeValue) && right.is_a?(TimeValue)
        left.raw == right.raw
      elsif left.is_a?(Time64Value) && right.is_a?(Time64Value)
        left.raw == right.raw && left.precision == right.precision
      else
        false
      end
    end

    # Qualified Tuple serializer statistics count the raw-zero column slot.
    # This intentionally does not import a type's SQL default (e.g. Date32).
    def self.is_default?(value : Value) : Bool
      if value.is_a?(DateValue)
        value.raw == 0_u16
      elsif value.is_a?(Date32Value) || value.is_a?(TimeValue)
        value.raw == 0_i32
      elsif value.is_a?(DateTimeValue)
        value.raw == 0_u32
      else
        value.raw == 0_i64
      end
    end

    # The metadata-bearing leaf boundary uses this for both nonempty and empty
    # arrays: the element class and every scaled row must agree with the exact
    # declared semantic type.
    def self.validate_buffer!(type_name : String, buffer : Buffer) : Nil
      if datetime_type = DateTimeColumnType.parse_leaf(type_name)
        case datetime_type.family
        when DateTimeColumnType::Family::DateTime
          raise ArgumentError.new("temporal Tuple buffer does not match exact type") unless buffer.is_a?(Array(DateTimeValue))
        when DateTimeColumnType::Family::DateTime64
          raise ArgumentError.new("temporal Tuple buffer does not match exact type") unless buffer.is_a?(Array(DateTime64Value))
          expected_precision = datetime_type.precision?.not_nil!
          buffer.each do |value|
            raise ArgumentError.new("DateTime64 value precision does not match exact type") unless value.precision == expected_precision
          end
        end
        return nil
      end
      case type_name
      when "Date"
        raise ArgumentError.new("temporal Tuple buffer does not match exact type") unless buffer.is_a?(Array(DateValue))
      when "Date32"
        raise ArgumentError.new("temporal Tuple buffer does not match exact type") unless buffer.is_a?(Array(Date32Value))
      when "DateTime"
        raise ArgumentError.new("temporal Tuple buffer does not match exact type") unless buffer.is_a?(Array(DateTimeValue))
      when "Time"
        raise ArgumentError.new("temporal Tuple buffer does not match exact type") unless buffer.is_a?(Array(TimeValue))
      else
        if type_name.starts_with?("DateTime64(")
          expected_precision = precision(type_name) || raise(ArgumentError.new("temporal Tuple type is not canonical"))
          raise ArgumentError.new("temporal Tuple buffer does not match exact type") unless buffer.is_a?(Array(DateTime64Value))
          buffer.each do |value|
            raise ArgumentError.new("temporal Tuple value precision does not match exact type") unless value.precision == expected_precision
          end
        elsif type_name.starts_with?("Time64(")
          expected_precision = precision(type_name) || raise(ArgumentError.new("temporal Tuple type is not canonical"))
          raise ArgumentError.new("temporal Tuple buffer does not match exact type") unless buffer.is_a?(Array(Time64Value))
          buffer.each do |value|
            raise ArgumentError.new("temporal Tuple value precision does not match exact type") unless value.precision == expected_precision
          end
        else
          raise ArgumentError.new("unsupported temporal Tuple type")
        end
      end
      nil
    end
  end
end
