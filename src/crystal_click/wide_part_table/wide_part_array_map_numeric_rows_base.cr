module CrystalClick
  abstract class WidePartArrayMapNumericRowsBase
    abstract def row_count : UInt64
    abstract def map_count : UInt64
    abstract def entry_count : UInt64
    abstract def payload_bytes : UInt64
    abstract def slice_rows(offset : Int, size : Int) : WidePartArrayMapNumericSliceBase
  end
end
