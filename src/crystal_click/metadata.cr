module CrystalClick
  enum ChecksumVerification
    Unverified
    SizeChecked
  end

  struct Mark
    getter compressed_offset : UInt64
    getter decompressed_offset : UInt64
    getter rows : UInt64

    def initialize(@compressed_offset, @decompressed_offset, @rows)
    end
  end
end
