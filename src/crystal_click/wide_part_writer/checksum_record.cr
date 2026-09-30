module CrystalClick
  module WidePartWriter
    private struct ChecksumRecord
      getter name : String
      getter physical_size : UInt64
      getter file_hash : {UInt64, UInt64}
      getter compressed : Bool
      getter uncompressed_size : UInt64?
      getter uncompressed_hash : {UInt64, UInt64}?

      def initialize(
        @name : String,
        @physical_size : UInt64,
        @file_hash : {UInt64, UInt64},
        @compressed : Bool,
        @uncompressed_size : UInt64? = nil,
        @uncompressed_hash : {UInt64, UInt64}? = nil,
      )
      end
    end
  end
end
