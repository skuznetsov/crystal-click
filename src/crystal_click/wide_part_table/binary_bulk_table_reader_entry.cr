module CrystalClick
  class WidePartTable
    private struct BinaryBulkTableReaderEntry
      getter name : String
      getter reader : BinaryBulkColumnReader
      getter value_type : BinaryDataType
      getter column_type : String

      def initialize(
        @name : String,
        @reader : BinaryBulkColumnReader,
        @value_type : BinaryDataType,
        @column_type : String,
      )
      end
    end

  end
end
