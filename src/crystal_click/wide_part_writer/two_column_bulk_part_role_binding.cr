module CrystalClick
  module WidePartWriter
    # One prepared physical lane in a two-column part. The logical name is
    # the key in the encoded-lane map; data and marks names are already bound
    # by the adapter's physical plan.
    private struct TwoColumnBulkPartRoleBinding
      getter logical_name : String
      getter data_filename : String
      getter marks_filename : String

      def initialize(
        @logical_name : String,
        @data_filename : String,
        @marks_filename : String,
      )
      end
    end
  end
end
