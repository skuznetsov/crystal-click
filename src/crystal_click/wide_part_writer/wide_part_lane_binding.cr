module CrystalClick
  module WidePartWriter
    # One planned lane binding in a schema-wide publication. The lane is
    # encoded by its nominal column owner; this value only joins its logical
    # stream to the hashed data and mark basenames.
    private struct WidePartLaneBinding
      getter column_name : String
      getter logical_name : String
      getter data_filename : String
      getter marks_filename : String

      def initialize(
        @column_name : String,
        @logical_name : String,
        @data_filename : String,
        @marks_filename : String,
      )
      end
    end
  end
end
