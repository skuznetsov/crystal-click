module CrystalClick
  # Narrow adapter for the exact QBit storage shape used by table scans. It
  # keeps QBit-specific preflight and materialization routing out of the
  # shared primitive/nested-column dispatch.
  class QBitColumnAdapter
    def self.type?(column_type : String) : Bool
      !QBitColumnType.for_type(column_type).nil?
    end

    def self.preflight_charge(reader : WidePart, column : String, mark_index : Int32) : UInt64
      reader.qbit_mark_range_materialization_charge(column, mark_index, 1)
    end

    def self.read_non_nullable(reader : WidePart, column : String, mark_index : Int32) : Array(QBitValue)
      reader.read_qbit_mark_range(column, mark_index, 1)
    end

    def self.read_nullable(reader : WidePart, column : String, mark_index : Int32) : Array(QBitValue?)
      reader.read_nullable_qbit_mark_range(column, mark_index, 1)
    end
  end
end
