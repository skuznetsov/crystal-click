module CrystalClick
  # :nodoc:
  # One canonical function, expression name, and nominal state type for the
  # caller-materialized projection aggregate profile.
  struct WidePartProjectionAggregateDescriptor
    enum Function
      Count
      Sum
      Min
      Max
    end

    getter function : Function

    @argument_name : String?
    @column_name : String
    @type : BinaryDataType

    private def initialize(@function : Function, argument_name : String?)
      if argument_name
        unless argument_name.bytesize > 0 &&
               argument_name.bytesize <= WidePartTable::MAX_COLUMN_NAME_BYTES &&
               /\A[A-Za-z_][A-Za-z0-9_]*\z/.matches?(argument_name)
          raise ArgumentError.new("aggregate projection argument must be a reader-bounded ASCII identifier")
        end
        @argument_name = String.new(argument_name.to_slice)
        @column_name = "#{function_name}(#{@argument_name})"
        @type = BinaryDataType.aggregate_function(function_name, BinaryDataType.primitive("UInt64"))
      else
        unless @function.count?
          raise ArgumentError.new("aggregate projection function requires a plain UInt64 argument")
        end
        @argument_name = nil
        @column_name = "count()"
        @type = BinaryDataType.aggregate_count
      end
    end

    def self.count : WidePartProjectionAggregateDescriptor
      new(Function::Count, nil)
    end

    def self.sum(argument_name : String) : WidePartProjectionAggregateDescriptor
      validate_writer_argument_name!(argument_name)
      new(Function::Sum, argument_name)
    end

    def self.min(argument_name : String) : WidePartProjectionAggregateDescriptor
      validate_writer_argument_name!(argument_name)
      new(Function::Min, argument_name)
    end

    def self.max(argument_name : String) : WidePartProjectionAggregateDescriptor
      validate_writer_argument_name!(argument_name)
      new(Function::Max, argument_name)
    end

    def self.for_function(function_name : String, argument_name : String) : WidePartProjectionAggregateDescriptor
      case function_name
      when "sum"
        new(Function::Sum, argument_name)
      when "min"
        new(Function::Min, argument_name)
      when "max"
        new(Function::Max, argument_name)
      else
        raise ArgumentError.new("unsupported aggregate projection function")
      end
    end

    # Resolves only the canonical part column spelling and exact nominal type.
    def self.for_column(column_name : String, type_name : String) : WidePartProjectionAggregateDescriptor?
      if column_name == "count()" && type_name == WideAggregateCountStoragePlan::NO_ARGUMENT_TYPE_NAME
        return count
      end

      match = /\A(sum|min|max)\(([A-Za-z_][A-Za-z0-9_]*)\)\z/.match(column_name)
      return nil unless match

      descriptor = for_function(match[1], match[2])
      descriptor if descriptor.type_name == type_name
    rescue ex : ArgumentError | UnsupportedFormatError
      nil
    end

    private def self.validate_writer_argument_name!(name : String) : Nil
      unless name.bytesize > 0 && name.bytesize <= WidePartWriter::MAX_COLUMN_NAME_BYTES &&
             /\A[A-Za-z_][A-Za-z0-9_]*\z/.matches?(name)
        raise ArgumentError.new("aggregate projection argument must be a bounded ASCII identifier")
      end
      nil
    end

    def argument_name : String?
      @argument_name.try { |name| String.new(name.to_slice) }
    end

    def count? : Bool
      @function.count?
    end

    def sum? : Bool
      @function.sum?
    end

    def min? : Bool
      @function.min?
    end

    def max? : Bool
      @function.max?
    end

    def minmax? : Bool
      min? || max?
    end

    def function_name : String
      case @function
      when .count? then "count"
      when .sum?   then "sum"
      when .min?   then "min"
      when .max?   then "max"
      else
        raise ArgumentError.new("aggregate projection function is outside the admitted profile")
      end
    end

    def column_name : String
      String.new(@column_name.to_slice)
    end

    def type : BinaryDataType
      @type
    end

    def type_name : String
      String.new(@type.name.to_slice)
    end
  end
end
