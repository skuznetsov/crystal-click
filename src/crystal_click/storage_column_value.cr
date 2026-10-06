module CrystalClick
  # One logical row value in the bounded recursive storage profile. Tuple and
  # Array nodes own only child references; JSON documents and JSON-free
  # BinaryValue leaves remain owned by their existing immutable value types.
  class StorageColumnValue
    TUPLE  = :tuple
    ARRAY  = :array
    OBJECT = :object
    BULK   = :bulk

    @kind : Symbol
    @tuple_values : Array(StorageColumnValue)
    @object_document : ObjectDocument?
    @bulk_value : BinaryValue?

    private def initialize(
      @kind : Symbol,
      tuple_values : Array(StorageColumnValue) = [] of StorageColumnValue,
      @object_document : ObjectDocument? = nil,
      @bulk_value : BinaryValue? = nil,
    )
      @tuple_values = tuple_values.dup
      unless @kind == TUPLE || @kind == ARRAY || @kind == OBJECT || @kind == BULK
        raise ArgumentError.new("unknown recursive storage value node")
      end
      case @kind
      when TUPLE, ARRAY
        unless @object_document.nil? && @bulk_value.nil?
          raise ArgumentError.new("recursive structural value cannot retain a leaf value")
        end
      when OBJECT
        unless @tuple_values.empty? && @object_document && @bulk_value.nil?
          raise ArgumentError.new("recursive storage JSON value is inconsistent")
        end
      when BULK
        unless @tuple_values.empty? && @object_document.nil? && @bulk_value
          raise ArgumentError.new("recursive storage BinaryBulk value is inconsistent")
        end
      end
    end

    def self.tuple(values : Array(StorageColumnValue)) : StorageColumnValue
      new(TUPLE, values)
    end

    def self.array(values : Array(StorageColumnValue)) : StorageColumnValue
      new(ARRAY, values)
    end

    def self.object_document(document : ObjectDocument) : StorageColumnValue
      new(OBJECT, object_document: document)
    end

    def self.bulk(value : BinaryValue) : StorageColumnValue
      new(BULK, bulk_value: value)
    end

    def kind : Symbol
      @kind
    end

    def tuple? : Bool
      @kind == TUPLE
    end

    def array? : Bool
      @kind == ARRAY
    end

    def object? : Bool
      @kind == OBJECT
    end

    def bulk? : Bool
      @kind == BULK
    end

    def tuple_values : Array(StorageColumnValue)
      @tuple_values.dup
    end

    def array_values : Array(StorageColumnValue)
      raise ArgumentError.new("recursive storage value is not an Array") unless @kind == ARRAY
      @tuple_values.dup
    end

    def child_count : Int32
      @tuple_values.size
    end

    def child_at(index : Int) : StorageColumnValue
      @tuple_values[index]
    end

    def object_document : ObjectDocument
      @object_document || raise(ArgumentError.new("recursive storage value is not a JSON document"))
    end

    def bulk_value : BinaryValue
      @bulk_value || raise(ArgumentError.new("recursive storage value is not a BinaryBulk value"))
    end
  end
end
