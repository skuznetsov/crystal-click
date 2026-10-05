module CrystalClick
  # Exact physical stream plan for the admitted text children of
  # SimpleAggregateFunction. This deliberately stays separate from ordinary
  # String/FixedString accessors and from numeric raw-width routing.
  class SimpleAggregateTextStoragePlan
    getter aggregate_type : SimpleAggregateColumnType

    def self.for_type_name(type_name : String) : SimpleAggregateTextStoragePlan?
      aggregate_type = SimpleAggregateColumnType.parse(type_name) || return nil
      return nil unless aggregate_type.string? || !aggregate_type.fixed_string_width.nil?
      new(aggregate_type)
    end

    private def initialize(@aggregate_type : SimpleAggregateColumnType)
    end

    def type_name : String
      @aggregate_type.type_name
    end

    def storage_type_name : String
      @aggregate_type.storage_type_name
    end

    def nullable? : Bool
      @aggregate_type.nullable?
    end

    def variable_string? : Bool
      @aggregate_type.string?
    end

    def fixed_string_width : Int32?
      @aggregate_type.fixed_string_width
    end

    def physical_streams(column : String) : Array(String)
      if variable_string?
        nullable? ? ["#{column}.null", "#{column}.size", column] : ["#{column}.size", column]
      elsif fixed_width = fixed_string_width
        nullable? ? ["#{column}.null", column] : [column]
      else
        raise UnsupportedFormatError.new("SimpleAggregateFunction text storage plan has no admitted child")
      end
    end

    def stream_width(column : String, stream_name : String) : Int32
      if variable_string?
        if nullable? && stream_name == "#{column}.null"
          1
        elsif stream_name == "#{column}.size"
          8
        elsif stream_name == column
          1
        else
          raise UnsupportedFormatError.new("unsupported SimpleAggregateFunction String stream")
        end
      elsif fixed_width = fixed_string_width
        if nullable? && stream_name == "#{column}.null"
          1
        elsif stream_name == column
          fixed_width
        else
          raise UnsupportedFormatError.new("unsupported SimpleAggregateFunction FixedString stream")
        end
      else
        raise UnsupportedFormatError.new("SimpleAggregateFunction text storage plan has no admitted child")
      end
    end

    def empty_payload_stream?(column : String, stream_name : String) : Bool
      variable_string? && stream_name == column
    end
  end
end
