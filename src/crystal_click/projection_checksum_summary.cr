module CrystalClick
  # ClickHouse's parent-side summary of a projection child's checksums map.
  # This binds the child manifest declarations, not the checksums.txt bytes or
  # the payload contents themselves.
  struct ProjectionChecksumSummary
    getter total_size_on_disk : UInt64
    getter total_checksum : {UInt64, UInt64}

    def initialize(checksums : PartChecksums)
      total_size = 0_u64
      hasher = ClickHouseSipHash.new
      checksums.entries.keys.sort.each do |name|
        entry = checksums.entries[name]
        if entry.physical_size > UInt64::MAX - total_size
          raise CorruptPartError.new("projection child checksum sizes overflow")
        end
        total_size += entry.physical_size

        name_bytes = name.to_slice
        update_uint64_le(hasher, name_bytes.size.to_u64)
        hasher.update(name_bytes)
        update_uint64_le(hasher, entry.file_hash[0])
        update_uint64_le(hasher, entry.file_hash[1])
      end

      @total_size_on_disk = total_size
      @total_checksum = hasher.finish128
    end

    private def update_uint64_le(hasher : ClickHouseSipHash, value : UInt64) : Nil
      bytes = Bytes.new(8)
      8.times do |index|
        bytes[index] = ((value >> (index * 8)) & 0xff_u64).to_u8
      end
      hasher.update(bytes)
    end
  end
end
