module CrystalClick
  # Immutable positional type/path counts plus an unordered shared-name map.
  # The two collections are intentionally not collapsed: nil on the enclosing
  # structure means absent statistics, while two empty arrays mean present zero.
  class StructureStatistics
    @counts : Array(UInt64)
    @shared : Array(StructureStatistic)
    @shared_name_indexes : Hash(UInt64, Array(Int32))

    def initialize(counts : Array(UInt64), shared : Array(StructureStatistic))
      @counts = counts.dup
      @shared = shared.dup

      # Retain the duplicate-check index for allocation-free map equality.
      # Hash collisions are resolved by comparing raw name bytes.
      @shared_name_indexes = Hash(UInt64, Array(Int32)).new
      @shared.each_with_index do |entry, index|
        bucket = @shared_name_indexes[entry.name_hash]?
        if bucket
          bucket.each do |prior_index|
            prior = @shared[prior_index]
            if prior.same_name?(entry)
              raise ArgumentError.new("shared structure statistic names must be unique")
            end
          end
          bucket << index
        else
          @shared_name_indexes[entry.name_hash] = [index] of Int32
        end
      end
    end

    def counts : Array(UInt64)
      @counts.dup
    end

    def shared : Array(StructureStatistic)
      @shared.dup
    end

    def count_count : Int32
      @counts.size
    end

    def count_at(index : Int) : UInt64
      @counts[index]
    end

    def shared_count : Int32
      @shared.size
    end

    def shared_at(index : Int) : StructureStatistic
      @shared[index]
    end

    def ==(other : StructureStatistics) : Bool
      return false unless @counts == other.@counts && @shared.size == other.@shared.size
      @shared.each do |entry|
        bucket = other.@shared_name_indexes[entry.name_hash]?
        return false unless bucket

        matched = false
        bucket.each do |other_index|
          candidate = other.@shared[other_index]
          next unless entry.same_name?(candidate)
          return false unless entry.count == candidate.count
          matched = true
          break
        end
        return false unless matched
      end
      true
    end

    def hash(hasher)
      hasher = @counts.hash(hasher)
      hasher = @shared.size.hash(hasher)

      unordered_shared_hash = 0_u64
      @shared.each do |entry|
        unordered_shared_hash &+= entry.hash
      end
      unordered_shared_hash.hash(hasher)
    end
  end
end
