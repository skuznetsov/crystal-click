module CrystalClick
  module WidePartWriter
    alias JSONTypedPathValue = Int8 | Int16 | Int32 | Int64 | UInt8 | UInt16 | UInt32 | UInt64 | Float32 | Float64 | String

    # One declared scalar JSON typed path. The explicit type name is checked
    # against every value before any staging directory is created.
    struct JSONTypedPathColumn
      getter name : String
      getter type_name : String
      getter values : Array(JSONTypedPathValue)

      def initialize(@name : String, @type_name : String, values : Array(T)) forall T
        @values = values.map { |value| value.as(JSONTypedPathValue) }
      end
    end
  end
end
